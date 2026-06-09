# =============================================================================
# AI Frontends Hub — HF Space (UID 1000)
# SillyTavern: git clone @ ST_REF + hub overlays (repo controls ST, no fork)
# =============================================================================

FROM alpine:3.20 AS hub-src
RUN apk add --no-cache git \
    && git clone --depth 1 https://github.com/Sexlovr/ai-hub-frontend.git /hub

FROM ghcr.io/pasta-devs/marinara-engine:lite AS marinara
FROM ghcr.io/prolix-oc/lumiverse:latest AS lumiverse

FROM node:24-bookworm-slim AS sillytavern-build
ARG ST_REF=1.18.0
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates git python3 rsync \
    && rm -rf /var/lib/apt/lists/*
COPY --from=hub-src /hub/overlays /opt/hub/overlays
COPY --from=hub-src /hub/docker/build-sillytavern.sh /opt/hub/docker/build-sillytavern.sh
RUN chmod +x /opt/hub/docker/build-sillytavern.sh /opt/hub/overlays/sillytavern/patches/apply-patches.sh \
    && ST_REF="${ST_REF}" /opt/hub/docker/build-sillytavern.sh

FROM node:24-bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
      nginx python3 curl ca-certificates rsync git \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /tmp && chmod 777 /tmp

COPY --from=lumiverse /usr/local/bin/bun /usr/local/bin/bun
COPY --from=hub-src --chown=node:node /hub/docker /opt/hub/docker/
COPY --from=hub-src --chown=node:node /hub/scripts /opt/hub/scripts/
COPY --from=hub-src --chown=node:node /hub/config /opt/hub/config/
COPY --from=hub-src --chown=node:node /hub/public /opt/hub/public/
COPY --from=hub-src --chown=node:node /hub/overlays /opt/hub/overlays/
RUN cp /opt/hub/public/index.html /opt/hub/public/hub.html
COPY --from=sillytavern-build --chown=node:node /apps/sillytavern /apps/sillytavern
COPY --from=marinara --chown=node:node /app /apps/marinara
COPY --from=lumiverse --chown=node:node /app /apps/lumiverse

RUN chmod +x /opt/hub/docker/*.sh /opt/hub/scripts/*.sh \
    && chmod +x /opt/hub/docker/start-all-apps.sh \
    && chmod +x /opt/hub/docker/start-one-app.sh \
    && chmod +x /opt/hub/docker/stop-one-app.sh \
    && chmod +x /opt/hub/overlays/sillytavern/patches/apply-patches.sh \
    && echo 'upstream active_backend { server 127.0.0.1:8000; }' > /opt/hub/docker/upstream.conf \
    && /opt/hub/docker/patch-lumiverse-auth.sh \
    && /opt/hub/docker/patch-app-subpaths.sh \
    && /opt/hub/docker/patch-lumiverse-sw.sh \
    && /opt/hub/docker/patch-marinara-sw.sh

USER node
ENV HOME=/home/node
WORKDIR /home/node

ENV DATA_ROOT=/data
ENV HUB_PORT=7860
ENV ACTIVE_APP=sillytavern
ENV ST_PORT=8000
ENV LUMIVERSE_PORT=7861
ENV MARINARA_PORT=7862
ENV ST_REF=1.18.0
ENV ST_REPO_MODE=1
ENV HUB_LAUNCH_MODE=lazy
ENV HUB_STOP_IDLE=1
ENV HUB_BOOT_APP=sillytavern
ENV NODE_ENV=production
ENV TRUST_ANY_ORIGIN=true
ENV FORWARDED_PROTO=https

EXPOSE 7860

CMD ["bash", "/opt/hub/docker/start-hf.sh"]