#!/usr/bin/env bash
# Build the three images at the version in ../VERSION.
#
#   containers/build_images.sh                 # native arch, local tags (testing)
#   PLATFORM=linux/amd64 containers/build_images.sh
#   REGISTRY=ghcr.io/<org> PUSH=1 PLATFORM=linux/amd64 containers/build_images.sh
#   EXTRA_CA_CERT=/path/to/proxy-root.pem containers/build_images.sh
#
# EXTRA_CA_CERT is only for networks that intercept TLS (Cisco Umbrella, Zscaler...):
# the CA is mounted as a BuildKit secret during package downloads and is not stored
# in the image.
#
# Centers should run images by digest (see README "Pinning images"), so a re-tag
# can never change what a center runs.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=$(cat VERSION)
REGISTRY=${REGISTRY:-cog-ball}
PLATFORM=${PLATFORM:-}
PUSH=${PUSH:-0}
ONLY=${ONLY:-counts mdall web}

build() {
  local name=$1 ctx=$2; shift 2
  local tag="$REGISTRY/$name:$VERSION"
  # --network host: micromamba crashes ("netlink descriptor") on the default build network.
  local args=(--network host --build-arg "COG_BALL_VERSION=$VERSION" -t "$tag" "$@")
  [[ -n $PLATFORM ]] && args+=(--platform "$PLATFORM")
  [[ -n ${EXTRA_CA_CERT:-} ]] && args+=(--secret "id=extra_ca,src=$EXTRA_CA_CERT")
  echo ">> $tag"
  # Plain `docker build` (BuildKit) sees locally built images, which the web image
  # needs: it copies the reference assets FROM the mdall image.
  DOCKER_BUILDKIT=1 docker build "${args[@]}" "$ctx"
  if [[ $PUSH == 1 ]]; then docker push "$tag"; fi
}

for img in $ONLY; do
  case $img in
    # RNA-SeQC exists only for linux/amd64, so the counts image is always amd64.
    counts) build counts containers/counts --platform linux/amd64 ;;
    mdall)  build mdall  containers/mdall ;;
    # The web image copies the reference assets out of the mdall image of the same version.
    web)    build web    web --build-arg "MDALL_IMAGE=$REGISTRY/mdall:$VERSION" ;;
  esac
done
