FROM alpine:latest

RUN apk add --no-cache \
    bash \
    curl \
    bind-tools \
    mtr \
    tzdata \
    ca-certificates \
    zabbix-utils

RUN addgroup -S probe && adduser -S -G probe -u 1000 probe

WORKDIR /app
COPY app/ /app/
RUN chown -R probe:probe /app

USER probe

ENTRYPOINT ["/app/entrypoint.sh"]
