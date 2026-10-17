#!/usr/bin/env bash
# On the BUILD machine (has Docker): save the linux/amd64 images as tarballs that can
# be copied to servers without a registry.
#
#   PLATFORM=linux/amd64 containers/build_images.sh
#   containers/export_images.sh /path/to/outdir      # cog-ball-<name>_<ver>.docker.tar + SHA256SUMS
#
# Archives are always tagged with the documented names, cog-ball/<name>:<VERSION>,
# whatever prefix the images were built under (REGISTRY=...), so after `docker load`
# the pipelines, bin/ scripts and web/docker-compose.yml work with their defaults.
# Singularity users convert them with containers/make_sif.sh (tags don't matter there).
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=$(cat VERSION); REGISTRY=${REGISTRY:-cog-ball}; out=${1:?output directory}
mkdir -p "$out"

restore=""   # "canonical-tag previous-image-id-or-empty" while a tag is borrowed
put_back() {
  [[ -n $restore ]] || return 0
  set -- $restore
  if [[ -n ${2:-} ]]; then docker tag "$2" "$1"; else docker rmi "$1" > /dev/null; fi
  restore=""
}
trap put_back EXIT

for name in ${ONLY:-counts mdall web}; do
  src="$REGISTRY/$name:$VERSION"; canon="cog-ball/$name:$VERSION"
  arch=$(docker image inspect -f '{{.Architecture}}' "$src")
  [[ $arch == amd64 ]] || echo "WARNING: $src is $arch, not amd64 — rebuild with PLATFORM=linux/amd64 for x86 servers" >&2
  if [[ $src != "$canon" ]]; then
    prev=$(docker image inspect -f '{{.Id}}' "$canon" 2>/dev/null || true)
    restore="$canon $prev"
    docker tag "$src" "$canon"
  fi
  echo ">> $src ($arch) saved as $canon"
  docker save "$canon" -o "$out/cog-ball-${name}_${VERSION}.docker.tar"
  put_back
done
(cd "$out" && shasum -a 256 cog-ball-*_"$VERSION".docker.tar > SHA256SUMS && cat SHA256SUMS)
