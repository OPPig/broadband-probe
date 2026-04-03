FROM alpine:3.20

ARG PROBE_UID=1000
ARG PROBE_GID=1000

RUN apk add --no-cache \
    bash \
    curl \
    bind-tools \
    mtr \
    tzdata \
    ca-certificates \
    zabbix-utils

RUN addgroup -S -g "${PROBE_GID}" probe \
    && adduser -S -D -H -u "${PROBE_UID}" -G probe probe

WORKDIR /app
COPY app/ /app/
RUN chown -R probe:probe /app

USER probe

ENTRYPOINT ["/app/entrypoint.sh"]
