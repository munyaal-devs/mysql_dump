#!/bin/sh
# Respaldo de base de datos MySQL -> S3
# Requiere: busybox sh, mysqldump, aws cli v2
# POSIX sh compatible - sin bashismos

set -eu

# ----------------------------------------------------------------------
# Timestamp del respaldo
# ----------------------------------------------------------------------
DATE=$(date +%Y%m%d%H%M)

# ----------------------------------------------------------------------
# Validacion estricta de variables de entorno (9 en total)
# ----------------------------------------------------------------------
REQUIRED_VARS="MYSQL_HOST MYSQL_PORT MYSQL_USER MYSQL_PASSWORD MYSQL_DATABASE \
AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION AWS_S3_BUCKET"

for VAR in $REQUIRED_VARS; do
    eval "VAL=\${$VAR:-}"
    if [ -z "$VAL" ]; then
        echo "Falta la variable de entorno requerida: $VAR" >&2
        exit 1
    fi
done

# ----------------------------------------------------------------------
# Rutas de trabajo
# ----------------------------------------------------------------------
DUMP_FILE="${MYSQL_DATABASE}-${DATE}.sql.gz"
TMP_SQL="/tmp/${MYSQL_DATABASE}-${DATE}.sql"
DUMP_PATH="/tmp/${DUMP_FILE}"
S3_PATH="s3://${AWS_S3_BUCKET}/${MYSQL_DATABASE}/${DUMP_FILE}"

# ----------------------------------------------------------------------
# Seguridad de la contraseña: mysqldump reconoce MYSQL_PWD nativamente,
# evita exponerla en /proc via la linea de comandos (-p).
# ----------------------------------------------------------------------
export MYSQL_PWD="$MYSQL_PASSWORD"

# ----------------------------------------------------------------------
# Manejo de errores / cleanup
# Usamos trap en EXIT viendo $? porque ERR no es confiable en POSIX sh.
# ----------------------------------------------------------------------
cleanup() {
    rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "❌ Error durante el respaldo${MYSQL_DATABASE:+ de $MYSQL_DATABASE}"
        rm -f "${DUMP_PATH:-}" "${TMP_SQL:-}"
    fi
    exit "$rc"
}
trap cleanup EXIT

# ----------------------------------------------------------------------
# Inicio del respaldo
# ----------------------------------------------------------------------
echo "🚀 Iniciando respaldo de ${MYSQL_DATABASE}..."

# ----------------------------------------------------------------------
# Ejecutar mysqldump: primero a archivo .sql temporal, luego gzip.
# Se evita el pipeline `mysqldump | gzip` porque en POSIX sh el exit
# status del pipeline es el de la ultima orden (gzip), lo que enmascara
# un fallo de mysqldump. Escribir a archivo primero hace que `set -e`
# detecte el fallo de mysqldump inmediatamente.
# ----------------------------------------------------------------------
mysqldump --single-transaction --routines --triggers --events \
    --verbose --set-gtid-purged=OFF \
    -h "$MYSQL_HOST" -P "$MYSQL_PORT" -u "$MYSQL_USER" \
    "$MYSQL_DATABASE" > "$TMP_SQL"

gzip -f "$TMP_SQL"

echo "✅ Dump completado: ${DUMP_FILE}"

# ----------------------------------------------------------------------
# Subir el archivo a S3
# ----------------------------------------------------------------------
echo "⬆️  Subiendo ${DUMP_FILE} a S3..."
aws s3 cp "$DUMP_PATH" "$S3_PATH"

# ----------------------------------------------------------------------
# Limpieza del archivo local
# ----------------------------------------------------------------------
rm -f "$DUMP_PATH" "$TMP_SQL"

echo "🎉 Respaldo completado exitosamente: ${S3_PATH}"