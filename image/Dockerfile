FROM alpine:3.20

ARG PROBE_UID=1000
ARG PROBE_GID=1000
ARG APK_MIRROR=""

RUN if [ -n "${APK_MIRROR}" ]; then \
      mirror="${APK_MIRROR%/}"; \
      sed -i "s#https\?://[^/]\+/alpine#${mirror}#g" /etc/apk/repositories; \
    fi \
    && apk add --no-cache \
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
