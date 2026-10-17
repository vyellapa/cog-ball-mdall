#!/usr/bin/env bash
# Smoke-test the results website image against a results folder.
#
#   test/test_web.sh <results_root>                       # Docker image cog-ball/web:<VERSION>
#   test/test_web.sh <results_root> --image NAME:TAG      # another Docker image
#   test/test_web.sh <results_root> --sif cog-ball-web_<VERSION>.sif   # Singularity/Apptainer
#
# <results_root> is a synced results folder (<root>/<center>/<sample>/...), e.g.
# results-test after `nextflow run pipelines/02-classify -profile test,...`
# (use its parent so TEST is the center), or the real hub folder.
# Starts the site with a login password on a free port, runs test/web_checks.py
# against it (pages, API, auth, gene search, downloads, path traversal), then stops it.
# The results folder is mounted read-only.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
VERSION=$(cat "$here/../VERSION")
root=${1:?usage: test/test_web.sh <results_root> [--image NAME | --sif FILE]}; shift
root=$(cd "$root" && pwd)
image="cog-ball/web:$VERSION" sif=""
while [[ $# -gt 0 ]]; do
  case $1 in --image) image=$2; shift ;; --sif) sif=$2; shift ;; *) echo "unknown option $1" >&2; exit 2 ;; esac
  shift
done

port=$(( 20000 + RANDOM % 20000 ))
pass="test-$RANDOM-$RANDOM"
name="cogweb-test-$$"
cleanup() {
  if [[ -n $sif ]]; then kill "$pid" 2>/dev/null || true; else docker rm -f "$name" >/dev/null 2>&1 || true; fi
}
trap cleanup EXIT

if [[ -n $sif ]]; then
  eng=$(command -v apptainer || command -v singularity) || { echo "need apptainer or singularity" >&2; exit 1; }
  APPTAINERENV_APP_PASSWORD=$pass SINGULARITYENV_APP_PASSWORD=$pass \
  APPTAINERENV_PORT=$port SINGULARITYENV_PORT=$port \
    "$eng" run --cleanenv --bind "$root:/data/results:ro" "$sif" > "/tmp/$name.log" 2>&1 &
  pid=$!
else
  docker run -d --name "$name" -p "127.0.0.1:$port:3000" -e APP_PASSWORD="$pass" \
    -v "$root:/data/results:ro" "$image" > /dev/null
fi

for _ in $(seq 1 60); do
  curl -fs "http://127.0.0.1:$port/healthz" > /dev/null 2>&1 && break
  sleep 1
done
curl -fs "http://127.0.0.1:$port/healthz" > /dev/null || {
  echo "Site did not start." >&2
  if [[ -n $sif ]]; then cat "/tmp/$name.log" >&2; else docker logs "$name" >&2; fi
  exit 1
}

python3 "$here/web_checks.py" "http://127.0.0.1:$port" admin "$pass"
