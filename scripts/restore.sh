#!/bin/sh
# Restauracion de base de datos MySQL desde un backup .sql.gz
# Requiere: busybox sh, mysql client, gunzip (applet busybox)
# POSIX sh compatible - sin bashismos

set -eu

# ----------------------------------------------------------------------
# Validacion estricta de variables de entorno (6 en total)
# ----------------------------------------------------------------------
REQUIRED_VARS="MYSQL_HOST MYSQL_PORT MYSQL_USER MYSQL_PASSWORD MYSQL_DATABASE \
BACKUP_FILE"

for VAR in $REQUIRED_VARS; do
    eval "VAL=\${$VAR:-}"
    if [ -z "$VAL" ]; then
        echo "Falta la variable de entorno requerida: $VAR" >&2
        exit 1
    fi
done

# ----------------------------------------------------------------------
# Ruta del archivo de respaldo (montado como volumen en el contenedor)
# ----------------------------------------------------------------------
RESTORE_PATH="/usr/restore/${BACKUP_FILE}"

if [ ! -f "$RESTORE_PATH" ]; then
    echo "❌ Archivo no encontrado: $RESTORE_PATH" >&2
    exit 1
fi

# ----------------------------------------------------------------------
# Seguridad de la contraseña: mysql reconoce MYSQL_PWD nativamente,
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
        echo "❌ Error durante la restauración${MYSQL_DATABASE:+ de $MYSQL_DATABASE}"
    fi
    exit "$rc"
}
trap cleanup EXIT

# ----------------------------------------------------------------------
# Inicio de la restauracion
# ----------------------------------------------------------------------
echo "🔄 Iniciando restauración de ${MYSQL_DATABASE} desde ${BACKUP_FILE}..."

# ----------------------------------------------------------------------
# Ejecutar restauracion: gunzip descomprime a stdout, mysql lee de stdin.
# A diferencia de backup.sh, aqui usamos pipeline porque el exit status
# es el de mysql (ultima orden) y set -e lo detecta. El riesgo de que
# gunzip falle y mysql procese datos parciales es menos critico en restore
# que perder un backup completo.
# ----------------------------------------------------------------------
gunzip -c "$RESTORE_PATH" | mysql -h "$MYSQL_HOST" -P "$MYSQL_PORT" \
    -u "$MYSQL_USER" "$MYSQL_DATABASE"

echo "🎉 Restauración completada exitosamente en ${MYSQL_DATABASE}"