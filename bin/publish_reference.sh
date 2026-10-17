#!/usr/bin/env bash
# Publish a reference bundle to a Hugging Face dataset so every center can download it
# with `bin/cog-ball-reference.sh --download` instead of building it.
#
# Usage:
#   hf auth login                                    # once; token with Write access
#   bin/publish_reference.sh --repo ORG_OR_USER/cog-ball-mdall-reference [--refs DIR]
#
# Options:
#   --repo ID        Hugging Face dataset id to create/update (or HF_REPO in site.conf)
#   --refs DIR       bundle to publish [REFS from site.conf]
#   --keep-private   leave the dataset private (default: public with manual access approval)
#   --dry-run        stage and checksum only; nothing is sent to Hugging Face
#
# What it does: checks the bundle, stages it (hard links, no copy) with SHA256SUMS,
# a dataset card and a licence note, creates the dataset (private while uploading),
# uploads with `hf upload-large-folder` (resumable: just run again if interrupted),
# tags the upload v<VERSION>, then makes it public + gated (you approve each request).
# Run it on a machine whose network allows uploads to huggingface.co.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
VERSION=$(cat "$here/../VERSION")
source "$here/_site_conf.sh"; load_site_conf
refs=${SITE_REFS:-} repo=${SITE_HF_REPO:-} keep_private=0 dry_run=0
die() { echo "ERROR: $*" >&2; exit 1; }
while [[ $# -gt 0 ]]; do
  case $1 in
    --repo) repo=$2; shift ;; --refs) refs=$2; shift ;; --keep-private) keep_private=1 ;; --dry-run) dry_run=1 ;;
    -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
    *) die "unknown option $1" ;;
  esac
  shift
done
[[ -n $repo && $repo == */* ]] || die "give --repo ORG_OR_USER/NAME (or HF_REPO in site.conf)"
[[ -n $refs && -d $refs ]] || die "give --refs DIR (or REFS in site.conf)"
refs=$(cd "$refs" && pwd)
if [[ $dry_run == 0 ]]; then
  command -v hf >/dev/null || die "install the Hugging Face CLI: pip install -U 'huggingface_hub[cli]'"
  hf auth whoami >/dev/null 2>&1 || die "not logged in to Hugging Face: run 'hf auth login' (token with Write access)"
fi
for f in star_index/genomeParameters.txt star_index/SA genes.gtf genes.collapsed.gtf reference_manifest.json; do
  [[ -s $refs/$f ]] || die "bundle incomplete: $refs/$f missing (rebuild, or --upgrade for genes.collapsed.gtf)"
done
sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }

# Stage next to the bundle (same file system, so hard links work); run logs are left out
# because they contain local paths.
stage=$(dirname "$refs")/.cog-ball-hf-stage
rm -rf "$stage"; mkdir -p "$stage/star_index"
link() { ln "$1" "$2" 2>/dev/null || ln -s "$1" "$2"; }
for f in genes.gtf genes.collapsed.gtf reference_manifest.json; do link "$refs/$f" "$stage/$f"; done
for f in "$refs"/star_index/*; do link "$f" "$stage/star_index/$(basename "$f")"; done
sed "s|__HF_REPO__|$repo|g; s|__VERSION__|$VERSION|g" "$here/../docs/huggingface/README.md" > "$stage/README.md"
cp "$here/../docs/huggingface/LICENSE" "$stage/LICENSE"
echo "== checksumming the bundle"
(cd "$stage" && find . -type f ! -path './.cache/*' ! -name SHA256SUMS ! -name README.md ! -name LICENSE \
   | sed 's|^\./||' | sort | while read -r f; do printf '%s  %s\n' "$(sha256 "$f")" "$f"; done > SHA256SUMS)
cat "$stage/SHA256SUMS"
if [[ $dry_run == 1 ]]; then
  echo "== dry run: staged in $stage ($(find "$stage" -type f | wc -l | tr -d ' ') files); nothing uploaded"
  ls -la "$stage" "$stage/star_index" | head -40
  rm -rf "$stage"; exit 0
fi

echo "== creating $repo (private during upload)"
hf repos create "$repo" --type dataset --private --exist-ok
echo "== uploading ~30 GB (resumable: rerun this script if it stops)"
hf upload-large-folder "$repo" "$stage" --type dataset
hf repos tag create "$repo" "v$VERSION" --type dataset 2>/dev/null || echo "   (tag v$VERSION already exists)"
if [[ $keep_private == 0 ]]; then
  hf repos settings "$repo" --type dataset --public --gated manual
  echo "== $repo is public with manual access approval (Settings > Access requests on its page)"
fi
rm -rf "$stage"
cat <<MSG

Published: https://huggingface.co/datasets/$repo  (version tag v$VERSION)
Sites download it with:
    bin/cog-ball-reference.sh --download --hf-repo $repo
or set HF_REPO=$repo in site.conf (and site.conf.example for everyone) and run:
    bin/cog-ball-reference.sh --download
MSG
