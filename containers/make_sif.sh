#!/usr/bin/env bash
# On the HPC SERVER (has singularity or apptainer): build the .sif files the pipelines
# use with --sif_dir.
#
# From tarballs made by export_images.sh (no registry needed):
#   containers/make_sif.sh /path/to/tarballs /shared/cog-ball/sif
# From Docker Hub (docker.io/vyellapa/cog-ball-{counts,mdall,web}:<VERSION>):
#   containers/make_sif.sh --pull /shared/cog-ball/sif
# (another registry: IMAGE_PREFIX=ghcr.io/<org>/cog-ball- containers/make_sif.sh --pull ...)
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=$(cat VERSION)
SING=$(command -v apptainer || command -v singularity) || { echo "Need apptainer or singularity" >&2; exit 1; }
if [[ ${1:-} == --pull ]]; then
  out=${2:?sif output directory}; mkdir -p "$out"
  for name in ${ONLY:-counts mdall web}; do
    "$SING" pull "$out/cog-ball-${name}_${VERSION}.sif" "docker://${IMAGE_PREFIX:-docker.io/vyellapa/cog-ball-}$name:$VERSION"
  done
else
  src=${1:?directory with cog-ball-*.docker.tar}; out=${2:?sif output directory}; mkdir -p "$out"
  (cd "$src" && if command -v sha256sum >/dev/null; then sha256sum -c SHA256SUMS; else shasum -a 256 -c SHA256SUMS; fi)
  for name in ${ONLY:-counts mdall web}; do
    "$SING" build "$out/cog-ball-${name}_${VERSION}.sif" "docker-archive://$src/cog-ball-${name}_${VERSION}.docker.tar"
  done
fi
ls -la "$out"
