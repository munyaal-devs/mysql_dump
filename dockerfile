# Dockerfile multi-stage para respaldo MySQL 5.7.44 -> S3
# Stage 1: builder - extrae mysqldump + dependencias e instala AWS CLI v2
FROM mysql:5.7.42-debian AS builder

# Herramientas necesarias para descargar/descomprimir AWS CLI.
# Debian Buster es EOL: los repos se movieron a archive.debian.org.
# Eliminamos el repo de MySQL (no lo necesitamos en el builder) y su llave GPG rota.
RUN echo "deb http://archive.debian.org/debian buster main" > /etc/apt/sources.list \
    && rm -f /etc/apt/sources.list.d/mysql.list \
    && echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/99no-check-valid-until \
    && apt-get update \
    && apt-get install -y --no-install-recommends unzip curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# -------------------------------------------------------------------
# 1. Extraer mysqldump + mysql y recolectar sus librerias compartidas
# -------------------------------------------------------------------
RUN mkdir -p /staging/bin /staging/lib

# Copiar los binarios mysqldump (backup) y mysql (restore) al staging
RUN cp /usr/bin/mysqldump /staging/bin/mysqldump \
    && cp /usr/bin/mysql /staging/bin/mysql

# Recolectar las librerias compartidas requeridas por mysqldump y mysql usando ldd.
# IMPORTANTE: filtramos las librerias de glibc (libc, libm, ld-linux, etc.) porque
# el builder usa Debian Buster (glibc 2.28) y el runtime usa Debian Bookworm (glibc 2.36).
# Copiar glibc del builder al runtime causa "Inconsistency detected by ld.so".
# El runtime ya tiene su propia glibc que es backward-compatible con binarios de Buster.
RUN for bin in /usr/bin/mysqldump /usr/bin/mysql; do \
        ldd "$bin"; \
    done | awk '/=> \// { print $3 } /^[[:space:]]*\// { print $1 }' | sort -u | while read -r lib; do \
        [ -n "$lib" ] || continue; \
        case "$lib" in \
            */libc.so*|*/libm.so*|*/libpthread.so*|*/libdl.so*|*/librt.so*|*/ld-linux*|*/libresolv.so*|*/libnss_*|*/libnsl.so*) \
                echo "Skipping glibc: $lib" ;; \
            *) \
                dest="/staging/lib${lib}"; \
                mkdir -p "$(dirname "$dest")"; \
                cp "$lib" "$dest"; \
                echo "Copied: $lib" ;; \
        esac; \
    done

# -------------------------------------------------------------------
# 2. Instalar AWS CLI v2 en /usr/local/aws-cli
# -------------------------------------------------------------------
WORKDIR /tmp/aws
RUN curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscli.zip \
    && unzip -q awscli.zip \
    && ./aws/install --install-dir /usr/local/aws-cli \
    && rm -rf /tmp/aws

# Copiar solo dist/ al staging: ahi estan los binarios reales de AWS CLI
# (bin/ solo contiene symlinks a dist/ que causan loops entre stages de Docker).
RUN REAL_DIR=$(readlink -f /usr/local/aws-cli/v2/current) \
    && cp -a "$REAL_DIR/dist" /staging/aws-dist

# Recolectar las librerias compartidas de AWS CLI (libz, etc.) que no estan
# en distroless. Mismo filtro de glibc que mysqldump.
RUN ldd /staging/aws-dist/aws | awk '/=> \// { print $3 } /^[[:space:]]*\// { print $1 }' | sort -u | while read -r lib; do \
        [ -n "$lib" ] || continue; \
        case "$lib" in \
            */libc.so*|*/libm.so*|*/libpthread.so*|*/libdl.so*|*/librt.so*|*/ld-linux*|*/libresolv.so*|*/libnss_*|*/libnsl.so*) \
                echo "Skipping glibc: $lib" ;; \
            *) \
                dest="/staging/lib${lib}"; \
                mkdir -p "$(dirname "$dest")"; \
                cp "$lib" "$dest"; \
                echo "Copied: $lib" ;; \
        esac; \
    done

# Hacer los scripts ejecutables antes de copiarlos al staging
COPY scripts/backup.sh /staging/bin/backup.sh
COPY scripts/restore.sh /staging/bin/restore.sh
RUN chmod +x /staging/bin/backup.sh /staging/bin/restore.sh

# -------------------------------------------------------------------
# Stage 2: runtime - imagen distroless con busybox (debug)
# -------------------------------------------------------------------
FROM gcr.io/distroless/base-debian12:debug AS runtime

# Copiar mysqldump (backup) y mysql (restore) al runtime
COPY --from=builder /staging/bin/mysqldump /usr/local/bin/mysqldump
COPY --from=builder /staging/bin/mysql /usr/local/bin/mysql

# Copiar las librerias compartidas de mysqldump manteniendo su estructura
# de rutas (/staging/lib es la raiz -> / )
COPY --from=builder /staging/lib /

# Copiar AWS CLI (solo dist/ con binarios reales, sin symlinks).
COPY --from=builder /staging/aws-dist /usr/local/aws-cli/dist

# Agregar los binarios de aws-cli al PATH
ENV PATH="/usr/local/aws-cli/dist:/usr/local/bin:$PATH"
# En distroless no hay paginador, sin esto aws-cli falla al intentar abrirlo
ENV AWS_PAGER=""

# Scripts de backup y restore
COPY --from=builder /staging/bin/backup.sh /usr/local/bin/backup.sh
COPY --from=builder /staging/bin/restore.sh /usr/local/bin/restore.sh

ENTRYPOINT ["/busybox/sh", "/usr/local/bin/backup.sh"]