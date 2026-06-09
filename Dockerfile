# =============================================================================
# AI Frontends Hub — HF paste-safe Dockerfile (no local COPY required)
#
# Paste this file + README.md into a Space, OR import full GitHub repo.
# Fetches hub scripts via git clone at build (tiny). All heavy app installs
# run on first open (ensure-*.sh), not during HF Docker build.
# =============================================================================

FROM node:24-bookworm-slim

ARG HUB_REPO=https://github.com/Sexlovr/ai-hub-frontend.git
ARG HUB_REF=main

RUN apt-get update && apt-get install -y --no-install-recommends \
      python3 curl ca-certificates rsync git \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /opt/hub /tmp /apps \
    && chmod 777 /tmp \
    && git clone --depth 1 --branch "${HUB_REF}" "${HUB_REPO}" /tmp/hub \
    && cp -a /tmp/hub/docker /tmp/hub/scripts /tmp/hub/config /tmp/hub/public /tmp/hub/overlays /opt/hub/ \
    && rm -rf /tmp/hub \
    && chmod +x /opt/hub/docker/*.sh /opt/hub/scripts/*.sh 2>/dev/null || true

USER node
WORKDIR /home/node

ENV DATA_ROOT=/data
ENV HUB_PORT=7860
ENV ACTIVE_APP=sillytavern
ENV ST_PORT=8000
ENV LUMIVERSE_PORT=7861
ENV MARINARA_PORT=7862
ENV ST_REF=1.18.0
ENV ST_INSTALL_ROOT=/data/st-app
ENV ST_PREBUILT=0
ENV ST_REPO_MODE=1
ENV HUB_LAUNCH_MODE=lazy
ENV HUB_STOP_IDLE=1
ENV HUB_BOOT_APP=sillytavern
ENV HUB_SETUP_MARKER=/data/.hub-image-setup-done
ENV LUMIVERSE_ROOT=/data/lumiverse-app
ENV NODE_ENV=production
ENV TRUST_ANY_ORIGIN=true
ENV FORWARDED_PROTO=https

EXPOSE 7860

CMD ["bash", "/opt/hub/docker/start-hf.sh"]