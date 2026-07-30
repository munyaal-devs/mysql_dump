# MySQL 5.7 Backup Agent

Agente de respaldo automático para bases de datos MySQL 5.7 con subida a Amazon S3.

## Arquitectura

Imagen Docker mínima basada en `gcr.io/distroless/base-debian12:debug` que contiene:
- `mysqldump` 5.7.42 (backup) y `mysql` 5.7.42 (restore), extraídos de `mysql:5.7.42-debian`
- AWS CLI v2
- Scripts POSIX sh: `backup.sh` (entrypoint por defecto) y `restore.sh`


## Build

```shell
docker build -t mysql-backup:latest .
```

## Uso local

```shell
docker run --env-file <(cat <<EOF
MYSQL_HOST=tu_host
MYSQL_PORT=3306
MYSQL_USER=tu_usuario
MYSQL_PASSWORD=tu_password
MYSQL_DATABASE=tu_basedatos
AWS_ACCESS_KEY_ID=tu_key
AWS_SECRET_ACCESS_KEY=tu_secret
AWS_DEFAULT_REGION=tu_region
AWS_S3_BUCKET=tu_bucket
EOF
) mysql-backup:latest
```

El resultado se sube a: `s3://<bucket>/<database>/<database>-<yyyymmddhhmm>.sql.gz`

## Variables de entorno

| Variable | Descripción | Ejemplo |
|---|---|---|
| `MYSQL_HOST` | Host del servidor MySQL | `db.example.com` |
| `MYSQL_PORT` | Puerto del servidor MySQL | `3306` |
| `MYSQL_USER` | Usuario con permisos de lectura | `backup_user` |
| `MYSQL_PASSWORD` | Contraseña de MySQL | `****` |
| `MYSQL_DATABASE` | Base de datos a respaldar | `mi_basedatos` |
| `AWS_ACCESS_KEY_ID` | Access key ID de AWS | `AKIA...` |
| `AWS_SECRET_ACCESS_KEY` | Secret access key de AWS | `****` |
| `AWS_DEFAULT_REGION` | Región de AWS del bucket | `us-east-1` |
| `AWS_S3_BUCKET` | Bucket S3 destino | `mi-bucket-backups` |


## Restauración local

1. Descargar el backup de S3:
   ```shell
   mkdir -p restore
   aws s3 cp s3://<bucket>/<database>/<archivo>.sql.gz ./restore/
   ```

2. Restaurar en un MySQL local:
   ```shell
   docker run --rm -i \
     --entrypoint /busybox/sh \
     --add-host=host.docker.internal:host-gateway \
     -v ./restore:/usr/restore \
     -e MYSQL_HOST=host.docker.internal \
     -e MYSQL_PORT=3306 \
     -e MYSQL_USER=root \
     -e MYSQL_PASSWORD=123 \
     -e MYSQL_DATABASE=tu_basedatos \
     -e BACKUP_FILE=nombre_del_archivo.sql.gz \
     mysql-backup:latest \
     /usr/local/bin/restore.sh
   ```

   La base de datos destino debe existir previamente.

## Verificación

- Comprobar que el objeto existe en S3 con extensión `.sql.gz`
- Descargar y validar: `zcat backup.sql.gz | head -n 20` (debe mostrar `-- MySQL dump 10.13  Distrib 5.7.42 ...`)
- Restaurar en un MySQL 5.7 de prueba para validar consistencia