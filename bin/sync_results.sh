#!/usr/bin/env bash
# Mirror one center's results to the shared results space the website reads.
#
#   bin/sync_results.sh                                   # paths from site.conf (OUTDIR, CENTER, HUB)
#   bin/sync_results.sh --dry-run                         # preview, paths from site.conf
#   bin/sync_results.sh --allow-empty [--dry-run]         # withdraw a center's last sample
#   bin/sync_results.sh <outdir>/<CENTER> <hub-root>/<CENTER> [--dry-run]
#   bin/sync_results.sh /data/cog-ball-results/CHOP  hub:/srv/cog-ball/results/CHOP
#
# The hub copy of a center mirrors that center's results folder: new and changed
# result files are copied, and result files that no longer exist at the center are
# deleted from the hub, so withdrawing a sample (delete <outdir>/<CENTER>/<sample>,
# then sync) removes it from the website. Only result, QC, provenance and run-report
# files are ever copied or deleted; BAMs and intermediates never leave the center.
#
# Safety: an empty source needs --allow-empty, so a wrong or empty source path
# cannot wipe a center's hub folder by default. Preview with --dry-run.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_site_conf.sh"
allow_empty=0 args=()
for arg in "$@"; do
  case $arg in
    --allow-empty) allow_empty=1 ;;
    -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
    *) args+=("$arg") ;;
  esac
done
set -- "${args[@]}"
if [[ $# -ge 2 && $1 != -* && $2 != -* ]]; then
  src=$1; dest=$2; shift 2
else
  load_site_conf
  [[ -n ${SITE_OUTDIR:-} && -n ${SITE_CENTER:-} && -n ${SITE_HUB:-} ]] || {
    echo "Give <outdir>/<CENTER> <hub-root>/<CENTER>, or set OUTDIR, CENTER and HUB in site.conf." >&2; exit 1; }
  src=$SITE_OUTDIR/$SITE_CENTER; dest=${SITE_HUB%/}/$SITE_CENTER
fi
center=$(basename "${src%/}")
[[ $center =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { echo "Bad center directory name: $center" >&2; exit 1; }
[[ $(basename "${dest%/}") == "$center" ]] || { echo "Destination must end in /$center" >&2; exit 1; }
check_center "$center"
[[ -d $src ]] || { echo "Source not found: $src" >&2; exit 1; }
n=$(find "$src" -mindepth 3 -maxdepth 3 \( -name '*.mdall.json' -o -name '*.htseq.dux4patched.tsv' \) | wc -l | tr -d ' ')
[[ $n -gt 0 || $allow_empty == 1 ]] || {
  echo "No results under $src; refusing to mirror an empty folder. To withdraw the last sample, preview with --allow-empty --dry-run, then use --allow-empty." >&2; exit 1; }
echo "Mirroring $n result file(s) from $src to $dest"

# --delete removes hub files that are gone at the center; it only touches paths that
# match the include rules below (excluded files are never deleted).
rsync -rtv --prune-empty-dirs --delete "$@" \
  --exclude='.classify.*/' \
  --include='*/' \
  --include='*.mdall.json' --include='*.mdall.tsv' --include='*.predictions.tsv' \
  --include='*.vst.tsv.gz' --include='*.mdall.log' \
  --include='*.htseq.dux4patched.tsv' --include='*.htseq.tsv' --include='*.counts_qc.json' \
  --include='*.versions.json' --include='*.star.Log.final.out' \
  --include='*.rnaseqc.metrics.tsv' --include='*.genebody.tsv' \
  --include='pipeline_info/***' \
  --exclude='*' \
  "${src%/}/" "${dest%/}/"
