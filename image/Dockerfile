FROM alpine:latest

RUN apk add --no-cache \
    bash \
    curl \
    bind-tools \
    mtr \
    tzdata \
    ca-certificates \
    zabbix-utils

WORKDIR /app
COPY app/ /app/

ENTRYPOINT ["/app/entrypoint.sh"]