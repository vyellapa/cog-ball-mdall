# syntax=docker/dockerfile:1
#
# cog-ball/web — read-only results browser.
# The MD-ALL reference assets (UMAP, reference expression, palette) are copied out of
# the mdall image of the SAME version, so the website and the classifier can never
# disagree about the reference.
#
# Build:  containers/build_images.sh   (builds mdall first, passes MDALL_IMAGE)

ARG MDALL_IMAGE=cog-ball/mdall:dev
FROM ${MDALL_IMAGE} AS mdall

FROM node:20.18-bookworm-slim
WORKDIR /app
COPY package.json package-lock.json ./
# Optional proxy CA for TLS-inspecting networks (see containers/build_images.sh); not kept.
RUN --mount=type=secret,id=extra_ca,required=false \
    if [ -s /run/secrets/extra_ca ]; then export NODE_EXTRA_CA_CERTS=/run/secrets/extra_ca; fi \
 && npm ci --omit=dev && npm cache clean --force \
 && node -e "require('express'); require.resolve('plotly.js-dist-min/plotly.min.js')"
COPY server.js ./
COPY public ./public
COPY --from=mdall /opt/cog-ball/ref /opt/cog-ball/ref

ARG COG_BALL_VERSION=dev
ENV NODE_ENV=production PORT=3000 RESULTS_ROOT=/data/results REF_DIR=/opt/cog-ball/ref \
    COG_BALL_VERSION=${COG_BALL_VERSION}
LABEL org.opencontainers.image.title="cog-ball-web" org.opencontainers.image.version="${COG_BALL_VERSION}"

USER node
EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD node -e "fetch('http://localhost:3000/healthz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"
# Absolute path: Singularity/Apptainer ignore WORKDIR and start in the caller's directory.
CMD ["node", "/app/server.js"]
