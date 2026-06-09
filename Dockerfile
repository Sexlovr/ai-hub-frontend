# =============================================================================
# AI Frontends Hub — THIN Dockerfile for HF Spaces
# Only: base image + COPY hub repo + ENV. Setup/patches run at boot.
# SillyTavern: official prebuilt image (no npm/webpack at build time).
# Lumiverse/Marinara: install on first open (ensure-*.sh).
# =============================================================================

FROM ghcr.io/sillytavern/sillytavern:1.18.0

USER root
RUN apk add --no-cache \
      python3 py3-pip bash curl rsync git ca-certificates \
    && mkdir -p /tmp /apps /opt/hub \
    && chmod 777 /tmp

COPY docker/ /opt/hub/docker/
COPY scripts/ /opt/hub/scripts/
COPY config/ /opt/hub/config/
COPY public/ /opt/hub/public/
COPY overlays/ /opt/hub/overlays/

RUN ln -sfn /home/node/app /apps/sillytavern \
    && chown -R node:node /opt/hub

USER node
WORKDIR /home/node

ENV DATA_ROOT=/data
ENV HUB_PORT=7860
ENV ACTIVE_APP=sillytavern
ENV ST_PORT=8000
ENV LUMIVERSE_PORT=7861
ENV MARINARA_PORT=7862
ENV ST_REF=1.18.0
ENV ST_PREBUILT=1
ENV ST_REPO_MODE=0
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