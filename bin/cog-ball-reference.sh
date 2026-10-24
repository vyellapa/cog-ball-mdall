#!/usr/bin/env bash
# Build the reference bundle (star_index/, genes.gtf, reference_manifest.json)
# without Nextflow. Same inputs, checksums and commands as pipelines/00-reference.
# Run once per site.
#
# Usage:
#   bin/cog-ball-reference.sh --download   # fetch the ready-made COG bundle from Zenodo (recommended)
#   bin/cog-ball-reference.sh              # build it here instead (with site.conf: REFS, SIF_DIR, THREADS)
#   bin/cog-ball-reference.sh --outdir /shared/cog-ball/refs [--sif-dir DIR | --docker] [options]
#
# Options:
#   --genome FILE     local copy of the GRCh38 analysis-set FASTA (.fna.gz); downloaded if omitted
#   --gtf FILE        local copy of Homo_sapiens.GRCh38.102.gtf.gz; downloaded if omitted
#   --threads N       [8]
#   --sa-sparse N     STAR suffix-array sparsity: 1 (~32 GB RAM, default) or 2 (~20 GB)
#   --registry NAME   Docker registry/prefix [cog-ball]
#   --upgrade         add files introduced by newer versions (genes.collapsed.gtf for
#                     RNA-SeQC) to an existing bundle, without rebuilding the STAR index
#   --download        download the COG bundle instead of building it (needs curl only;
#                     ~30 GB; resumes if interrupted; every file checked against SHA256SUMS)
#   --zenodo RECORD   Zenodo record to download from [ZENODO_RECORD in site.conf]
#   --zenodo-link-token TOKEN  token of the access link COG shared [ZENODO_LINK_TOKEN];
#                     users granted access personally can export ZENODO_TOKEN instead
#   --hf-repo ORG/NAME  or a Hugging Face dataset [HF_REPO in site.conf]
#   --hf-revision REV   Hugging Face version tag [v<VERSION>]; gated datasets need
#                     `hf auth login` or HF_TOKEN
#
# Needs about 40 GB RAM and 70 GB free disk during the build (35 GB afterwards).
set -euo pipefail

# Keep in sync with pipelines/00-reference/main.nf.
GENOME_URL=https://ftp.ncbi.nlm.nih.gov/genomes/all/GCA/000/001/405/GCA_000001405.15_GRCh38/seqs_for_alignment_pipelines.ucsc_ids/GCA_000001405.15_GRCh38_no_alt_plus_hs38d1_analysis_set.fna.gz
GENOME_SHA256=08959902840a28f410ad1220e36b2a3fbe2cb90beecceb6ea5b050a0e68ed96d
GTF_URL=https://ftp.ensembl.org/pub/release-102/gtf/homo_sapiens/Homo_sapiens.GRCh38.102.gtf.gz
GTF_SHA256=307038294611aaf86c3e61e70273a26c7b3a343cd416feed137e6e86d471ea32

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
VERSION=$(cat "$here/../VERSION")
source "$here/_site_conf.sh"; load_site_conf
outdir=${SITE_REFS:-} sif_dir=${SITE_SIF_DIR:-} threads=${SITE_THREADS:-8}
sparse=1 registry=cog-ball engine="" genome="" gtf="" upgrade=0 download=0
hf_repo=${SITE_HF_REPO:-} hf_rev=v$VERSION zenodo=${SITE_ZENODO_RECORD:-} zlink=${SITE_ZENODO_LINK_TOKEN:-}
die() { echo "ERROR: $*" >&2; exit 1; }
while [[ $# -gt 0 ]]; do
  case $1 in
    --outdir) outdir=$2; shift ;;   --sif-dir) sif_dir=$2; shift ;;   --docker) engine=docker ;;
    --genome) genome=$2; shift ;;   --gtf) gtf=$2; shift ;;           --threads) threads=$2; shift ;;
    --sa-sparse) sparse=$2; shift ;; --registry) registry=$2; shift ;; --upgrade) upgrade=1 ;;
    --download) download=1 ;;       --hf-repo) hf_repo=$2; zenodo=""; shift ;;   --hf-revision) hf_rev=$2; shift ;;
    --zenodo) zenodo=$2; shift ;;    --zenodo-link-token) zlink=$2; shift ;;
    -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
    *) die "unknown option $1" ;;
  esac
  shift
done
[[ $engine == docker ]] && sif_dir=""   # --docker overrides SIF_DIR from site.conf
[[ -n $outdir ]] || die "no output folder: pass --outdir or set REFS in site.conf (cp site.conf.example site.conf)"
sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }

# ── Download the ready-made bundle (no containers needed) ─────────────────────
if [[ $download == 1 ]]; then
  command -v curl >/dev/null || die "curl is needed for --download"
  mkdir -p "$outdir"; outdir=$(cd "$outdir" && pwd)
  auth=()
  if [[ -n $zenodo ]]; then
    # Zenodo: flat file names (star_index/X -> star_index__X); restricted records need the
    # access-link token (?token=) or a personal token of a user who was granted access.
    zhost=${ZENODO_HOST:-https://zenodo.org}
    [[ -n ${ZENODO_TOKEN:-} ]] && auth=(-H "Authorization: Bearer $ZENODO_TOKEN")
    url_of() { local q="download=1"; [[ -n $zlink ]] && q="$q&token=$zlink"; echo "$zhost/records/$zenodo/files/${1//\//__}?$q"; }
    where="Zenodo record $zenodo"
    noaccess="request access at $zhost/records/$zenodo or ask COG for the access-link token (--zenodo-link-token / ZENODO_LINK_TOKEN)"
  elif [[ -n $hf_repo ]]; then
    token=${HF_TOKEN:-}
    [[ -z $token && -s ${HF_HOME:-$HOME/.cache/huggingface}/token ]] && token=$(cat "${HF_HOME:-$HOME/.cache/huggingface}/token")
    [[ -n $token ]] && auth=(-H "Authorization: Bearer $token")
    url_of() { echo "${HF_ENDPOINT:-https://huggingface.co}/datasets/$hf_repo/resolve/$hf_rev/$1"; }
    where="Hugging Face $hf_repo@$hf_rev"
    noaccess="request access at https://huggingface.co/datasets/$hf_repo , then run 'hf auth login' or export HF_TOKEN"
  else
    die "no source to download from: set ZENODO_RECORD (or HF_REPO) in site.conf, or pass --zenodo RECORD"
  fi
  echo "== downloading the reference bundle from $where into $outdir"
  if ! curl -fsSL ${auth[@]+"${auth[@]}"} "$(url_of SHA256SUMS)" -o "$outdir/SHA256SUMS"; then
    die "cannot download SHA256SUMS: $noaccess"
  fi
  while read -r want rel; do
    dest=$outdir/$rel; mkdir -p "$(dirname "$dest")"
    if [[ -s $dest && $(sha256 "$dest") == "$want" ]]; then echo "   ok (already here)  $rel"; continue; fi
    echo "   downloading  $rel"
    curl -fL --retry 5 --retry-delay 10 -C - ${auth[@]+"${auth[@]}"} "$(url_of "$rel")" -o "$dest" \
      || { rm -f "$dest"; curl -fL --retry 5 --retry-delay 10 ${auth[@]+"${auth[@]}"} "$(url_of "$rel")" -o "$dest"; }
    [[ $(sha256 "$dest") == "$want" ]] || die "checksum mismatch for $rel; run the same command again to retry"
  done < "$outdir/SHA256SUMS"
  echo "== reference bundle ready and verified: $outdir  (REFS=$outdir)"
  exit 0
fi

[[ $engine == docker || -n $sif_dir ]] || die "no images: pass --sif-dir (or --docker), or set SIF_DIR in site.conf"
mkdir -p "$outdir/pipeline_info"; outdir=$(cd "$outdir" && pwd)
if [[ $upgrade == 0 ]]; then
  [[ -e $outdir/star_index/genomeParameters.txt ]] && die "$outdir already has a star_index; use a new --outdir (or --upgrade)"
  mkdir -p "$outdir/downloads"
else
  [[ -e $outdir/star_index/genomeParameters.txt && -s $outdir/genes.gtf ]] || die "--upgrade needs an existing bundle (star_index/, genes.gtf) in $outdir"
fi
exec > >(tee -a "$outdir/pipeline_info/cog-ball-reference_$(date -u +%Y%m%dT%H%M%SZ).log") 2>&1

fetch() {   # fetch <local-or-empty> <url> <sha256> -> prints verified local path
  local src=$1 url=$2 want=$3 dest
  if [[ -n $src ]]; then dest=$(cd "$(dirname "$src")" && pwd)/$(basename "$src")
  else dest=$outdir/downloads/$(basename "$url"); [[ -s $dest ]] || curl -fL --retry 3 -o "$dest" "$url" >&2; fi
  [[ $(sha256 "$dest") == "$want" ]] || die "checksum mismatch for $dest (expected $want)"
  echo "$dest"
}
if [[ -n $sif_dir ]]; then
  engine=$(command -v apptainer || command -v singularity) || die "neither apptainer nor singularity on PATH"
  img=$(cd "$sif_dir" && pwd)/cog-ball-counts_$VERSION.sif; [[ -f $img ]] || die "image not found: $img"
else
  command -v docker >/dev/null || die "pass --sif-dir or install Docker"; engine=docker; img=$registry/counts:$VERSION
fi
binds=$outdir
run_in() {
  if [[ $engine == docker ]]; then
    local vols=() d; while read -r d; do vols+=(-v "$d:$d"); done <<< "$binds"
    docker run --rm -u "$(id -u):$(id -g)" "${vols[@]}" -w "$outdir" "$img" "$@"
  else
    "$engine" exec --cleanenv --bind "$(paste -sd, - <<< "$binds")" --pwd "$outdir" "$img" "$@"
  fi
}

if [[ $upgrade == 1 ]]; then
  sparse=$(awk '$1=="genomeSAsparseD"{print $2}' "$outdir/star_index/genomeParameters.txt")
  echo "== upgrading $outdir: collapsed annotation for RNA-SeQC QC"
  run_in collapse_annotation.py genes.gtf genes.collapsed.gtf > /dev/null
  run_in make_reference_manifest.py --bundle . --genome-url "$GENOME_URL" --genome-sha256 "$GENOME_SHA256" \
      --gtf-url "$GTF_URL" --gtf-sha256 "$GTF_SHA256" --sjdb-overhang 100 --sa-sparse "${sparse:-1}" > /dev/null
  echo "== bundle upgraded: $outdir (counts made with the old manifest will be redone by cog-ball-run.sh)"
  exit 0
fi

echo "== verifying inputs"
genome=$(fetch "$genome" "$GENOME_URL" "$GENOME_SHA256")
gtf=$(fetch "$gtf" "$GTF_URL" "$GTF_SHA256")
binds=$(printf '%s\n' "$outdir" "$(dirname "$genome")" "$(dirname "$gtf")" | sort -u)

ram=$(( (sparse > 1 ? 22 : 34) * 1024 * 1024 * 1024 ))
echo "== preparing genome and GTF"
run_in bash -c "pigz -dc -p $threads '$genome' > genome.fa && grep '^>' genome.fa > genome_headers.txt"
run_in prepare_gtf.py --gtf "$gtf" --fasta-headers genome_headers.txt --out genes.gtf
echo "== building STAR index (about 1 hour)"
run_in cog_star_index.sh genome.fa genes.gtf star_index "$threads" "$sparse" "$ram"
echo "== collapsed annotation for RNA-SeQC QC"
run_in collapse_annotation.py genes.gtf genes.collapsed.gtf > /dev/null
run_in make_reference_manifest.py --bundle . --genome-url "$GENOME_URL" --genome-sha256 "$GENOME_SHA256" \
    --gtf-url "$GTF_URL" --gtf-sha256 "$GTF_SHA256" --sjdb-overhang 100 --sa-sparse "$sparse" > /dev/null
rm -f "$outdir/genome.fa" "$outdir/genome_headers.txt"
rmdir "$outdir/downloads" 2>/dev/null || true   # empty when --genome/--gtf were given
echo "== reference bundle ready: $outdir  (use --refs $outdir)"
