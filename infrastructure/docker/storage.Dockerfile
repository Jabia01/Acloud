# Local development only: build the upstream security-fixed source release.
FROM golang:1.24.9-alpine AS builder
RUN apk add --no-cache git ca-certificates
ENV CGO_ENABLED=0 GOMAXPROCS=2
RUN go install -p 2 github.com/minio/minio@RELEASE.2025-10-15T17-29-55Z
RUN go install -p 2 github.com/minio/mc@RELEASE.2025-08-13T08-35-41Z
FROM alpine:3.22
RUN apk add --no-cache ca-certificates curl
COPY --from=builder /go/bin/minio /usr/local/bin/minio
COPY --from=builder /go/bin/mc /usr/local/bin/mc
COPY infrastructure/docker/storage-init.sh /usr/local/bin/storage-init
RUN chmod +x /usr/local/bin/storage-init
ENTRYPOINT ["minio"]
