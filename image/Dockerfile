ARG ALPINE_VERSION=3.20
FROM alpine:${ALPINE_VERSION}

ARG PROBE_UID=1000
ARG PROBE_GID=1000
ARG ALPINE_VERSION=3.20
ARG APK_MIRROR=https://mirrors.aliyun.com/alpine

RUN apk add --no-cache \
    --repository "${APK_MIRROR%/}/v${ALPINE_VERSION}/main" \
    --repository "${APK_MIRROR%/}/v${ALPINE_VERSION}/community" \
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
