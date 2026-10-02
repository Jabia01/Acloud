#!/bin/sh
set -eu
# Never echo credential-bearing mc commands or provider error bodies.
case "$S3_BUCKET" in *[!a-z0-9-]*|'') echo 'Invalid development bucket'; exit 1;; esac
mc alias set local http://storage:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null 2>&1
mc mb --ignore-existing "local/$S3_BUCKET" >/dev/null 2>&1
mc anonymous set none "local/$S3_BUCKET" >/dev/null 2>&1
mc version enable "local/$S3_BUCKET" >/dev/null 2>&1
mc admin user add local "$S3_ACCESS_KEY_ID" "$S3_SECRET_ACCESS_KEY" >/dev/null 2>&1
printf '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["s3:GetBucketVersioning"],"Resource":["arn:aws:s3:::%s"]},{"Effect":"Allow","Action":["s3:PutObject","s3:GetObject","s3:GetObjectVersion","s3:DeleteObject","s3:DeleteObjectVersion"],"Resource":["arn:aws:s3:::%s/objects/*"]}]}' "$S3_BUCKET" "$S3_BUCKET" >/tmp/application-policy.json
mc admin policy create local backup-application /tmp/application-policy.json >/dev/null 2>&1
mc admin policy attach local backup-application --user "$S3_ACCESS_KEY_ID" >/dev/null 2>&1
echo 'Private development bucket, versioning and application-only policy configured.'
