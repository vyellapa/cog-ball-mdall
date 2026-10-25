#!/usr/bin/env bash
# One sample, FASTQ -> MD-ALL call, without Nextflow.
#
# Runs exactly the same commands as pipelines/01-counts + pipelines/02-classify
# (the commands live inside the images: cog_align.sh, cog_count.sh, mdall_classify.R)
# and writes the same layout, so the output can be synced to the results website
# as-is. Needs only bash and Singularity/Apptainer or Docker.
#
# Usage (with site.conf filled in, see site.conf.example):
#   bin/cog-ball-run.sh --sample ID --r1 R1.fastq.gz [--r2 R2.fastq.gz]
# Without site.conf, give everything on the command line:
#   bin/cog-ball-run.sh --sample ID --center ID --r1 R1.fastq.gz [--r2 R2.fastq.gz] \
#                       --refs /path/to/reference_bundle --outdir /path/to/results \
#                       [--sif-dir DIR | --docker] [options]
#
# Required (CENTER, REFS, OUTDIR, SIF_DIR, THREADS default from site.conf):
#   --sample ID        de-identified sample id (letters, digits, . _ -)
#   --center ID        center code registered in centers.tsv (CHOP, NCH, CHLA)
#   --r1 FILE[,FILE]   read 1 FASTQ(s); several lanes comma-separated, in lane order
#   --r2 FILE[,FILE]   read 2 FASTQ(s), same order as --r1 (omit for single-end)
#   --refs DIR         reference bundle (star_index/, genes.gtf, reference_manifest.json)
#                      from pipelines/00-reference or bin/cog-ball-reference.sh
#   --outdir DIR       results root; output goes to DIR/<center>/<sample>/
# Containers (one of):
#   --sif-dir DIR      Singularity/Apptainer images cog-ball-{counts,mdall}_<VERSION>.sif
#   --docker           Docker images <registry>/{counts,mdall}:<VERSION>
#   --registry NAME    Docker registry/prefix [cog-ball]
# Options:
#   --site-conf FILE   settings file [<repo>/site.conf or $COG_BALL_SITE_CONF]
#   --threads N        CPU threads [8]
#   --work DIR         scratch for BAM/intermediates [<outdir>/<center>/<sample>/work]
#   --keep-bam         retain the sorted BAM in <outdir>/<center>/<sample>/bam/
#                      (redo alignment/counting if cached counts have no retained BAM)
#   --keep-work        do not delete the scratch directory
#   --force            redo counting even if counts from identical inputs exist
#                      (counts made from different FASTQs, reference or image are
#                      always redone)
#   --min-unique-pct N QC threshold recorded in counts_qc.json [50]
#   --min-assigned N   QC threshold recorded in counts_qc.json [5000000]
#
# Memory: STAR needs about 32 GB RAM with the default reference.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
VERSION=$(cat "$here/../VERSION")
source "$here/_site_conf.sh"
# site.conf supplies defaults; command-line options override them.
conf_arg=""; for ((i = 1; i < $#; i++)); do [[ ${!i} == --site-conf ]] && { j=$((i + 1)); conf_arg=${!j}; }; done
load_site_conf "$conf_arg"
center=${SITE_CENTER:-} refs=${SITE_REFS:-} outdir=${SITE_OUTDIR:-} sif_dir=${SITE_SIF_DIR:-}
threads=${SITE_THREADS:-8} registry=cog-ball engine="" work="" keep_bam=0 keep_work=0 force=0
min_unique=50 min_assigned=5000000 r2=""

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit "${1:-0}"; }
die() { echo "ERROR: $*" >&2; exit 1; }
[[ $# -eq 0 ]] && usage 0
while [[ $# -gt 0 ]]; do
  case $1 in
    --sample) sample=$2; shift ;;        --center) center=$2; shift ;;
    --r1) r1=$2; shift ;;                --r2) r2=$2; shift ;;
    --refs) refs=$2; shift ;;            --outdir) outdir=$2; shift ;;
    --sif-dir) sif_dir=$2; shift ;;      --docker) engine=docker ;;
    --registry) registry=$2; shift ;;    --threads) threads=$2; shift ;;
    --work) work=$2; shift ;;            --keep-bam) keep_bam=1 ;;
    --keep-work) keep_work=1 ;;          --force) force=1 ;;
    --min-unique-pct) min_unique=$2; shift ;;
    --min-assigned) min_assigned=$2; shift ;;
    --site-conf) shift ;;   # read above
    -h|--help) usage 0 ;;
    *) die "unknown option $1 (see --help)" ;;
  esac
  shift
done
[[ $engine == docker ]] && sif_dir=""   # --docker overrides SIF_DIR from site.conf
hint="(set it in site.conf: cp site.conf.example site.conf)"
[[ -n ${sample:-} ]] || die "--sample is required"
[[ -n ${r1:-} ]] || die "--r1 is required"
[[ -n $center ]] || die "no center given: pass --center or set CENTER $hint"
[[ -n $refs ]] || die "no reference bundle: pass --refs or set REFS $hint"
[[ -n $outdir ]] || die "no output folder: pass --outdir or set OUTDIR $hint"
[[ $engine == docker || -n $sif_dir ]] || die "no images: pass --sif-dir (or --docker), or set SIF_DIR $hint"
check_center "$center"

id_re='^[A-Za-z0-9][A-Za-z0-9._-]*$'
[[ $sample =~ $id_re ]] || die "invalid --sample '$sample' (letters, digits, . _ - only; no PHI)"
[[ $center =~ $id_re ]] || die "invalid --center '$center'"
[[ $threads =~ ^[0-9]+$ ]] || die "--threads must be a number"

abspath() { (cd "$(dirname "$1")" && printf '%s/%s\n' "$(pwd)" "$(basename "$1")"); }
sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }

# ── Inputs ────────────────────────────────────────────────────────────────────
binds=()
resolve_list() {   # comma list of files -> comma list of absolute paths
  local out=() f files
  IFS=',' read -r -a files <<< "$1"
  for f in "${files[@]}"; do
    [[ -f $f ]] || die "FASTQ not found: $f"
    [[ $f != *" "* ]] || die "FASTQ paths must not contain spaces: $f"
    out+=("$(abspath "$f")")
  done
  (IFS=','; echo "${out[*]}")
}
r1=$(resolve_list "$r1")
if [[ -n $r2 ]]; then
  r2=$(resolve_list "$r2")
  [[ $(tr -cd , <<< "$r1" | wc -c) -eq $(tr -cd , <<< "$r2" | wc -c) ]] || die "--r1 and --r2 list different numbers of files"
fi
# Mount every FASTQ directory (done here, not inside resolve_list's subshell).
IFS=',' read -r -a fq_all <<< "$r1${r2:+,$r2}"
for f in "${fq_all[@]}"; do binds+=("$(dirname "$f")"); done

[[ -d $refs ]] || die "--refs directory not found: $refs"
refs=$(cd "$refs" && pwd)
for f in star_index/genomeParameters.txt genes.gtf reference_manifest.json; do
  [[ -e $refs/$f ]] || die "reference bundle incomplete: $refs/$f missing"
done
[[ -e $refs/genes.collapsed.gtf ]] || die "reference bundle lacks genes.collapsed.gtf (RNA-SeQC QC); add it with: bin/cog-ball-reference.sh --outdir $refs --upgrade ${sif_dir:+--sif-dir $sif_dir}"
manifest_sha=$(sha256 "$refs/reference_manifest.json")

mkdir -p "$outdir"; outdir=$(cd "$outdir" && pwd)
sdir=$outdir/$center/$sample
counts_dir=$sdir/counts mdall_dir=$sdir/mdall
work=${work:-$sdir/work}
mkdir -p "$counts_dir" "$mdall_dir" "$work" "$outdir/$center/pipeline_info"
work=$(cd "$work" && pwd)
binds+=("$refs" "$sdir" "$work")

run_id="cog-ball-run_$(date -u +%Y%m%dT%H%M%SZ)"
log=$outdir/$center/pipeline_info/${run_id}_${sample}.log
exec > >(tee -a "$log") 2>&1

# ── Containers ────────────────────────────────────────────────────────────────
if [[ -n $sif_dir ]]; then
  engine=$(command -v apptainer || command -v singularity) || die "--sif-dir given but neither apptainer nor singularity is on PATH"
  sif_dir=$(cd "$sif_dir" && pwd)
  img_counts=$sif_dir/cog-ball-counts_$VERSION.sif img_mdall=$sif_dir/cog-ball-mdall_$VERSION.sif
  for i in "$img_counts" "$img_mdall"; do [[ -f $i ]] || die "image not found: $i"; done
elif [[ $engine == docker || -z $engine ]]; then
  command -v docker >/dev/null || die "no container engine: pass --sif-dir (Singularity/Apptainer) or install Docker"
  engine=docker
  img_counts=$registry/counts:$VERSION img_mdall=$registry/mdall:$VERSION
fi

bind_list=$(printf '%s\n' "${binds[@]}" | sort -u)
run_in() {   # run_in <image> <workdir> <command...>
  local image=$1 cwd=$2; shift 2
  if [[ $engine == docker ]]; then
    local vols=() d
    while read -r d; do vols+=(-v "$d:$d"); done <<< "$bind_list"
    docker run --rm -u "$(id -u):$(id -g)" "${vols[@]}" -w "$cwd" "$image" "$@"
  else
    # --cleanenv keeps host R/Python/Perl settings (R_LIBS, PERL5LIB ...) out of the container.
    "$engine" exec --cleanenv --bind "$(paste -sd, - <<< "$bind_list")" --pwd "$cwd" "$image" "$@"
  fi
}

echo "== cog-ball-run $VERSION | sample $sample | center $center | $(date -u +%FT%TZ)"
echo "   engine: $engine | images: $img_counts , $img_mdall"
echo "   refs: $refs (manifest sha256 ${manifest_sha:0:12}…) | threads: $threads${SITE_CONF_FILE:+ | settings: $SITE_CONF_FILE}"
if [[ -r /proc/meminfo ]]; then
  mem_gb=$(awk '/MemTotal/{printf "%d", $2/1048576}' /proc/meminfo)
  (( mem_gb >= 34 )) || echo "WARNING: ${mem_gb} GB RAM on this machine; STAR needs about 32 GB."
fi

# ── 1. Counts (same commands as pipelines/01-counts) ─────────────────────────
counts=$counts_dir/$sample.htseq.dux4patched.tsv
# Existing counts are reused only if they were made from exactly these inputs: same
# FASTQ files (path, size, modification time), reference bundle, image and QC
# thresholds. Anything else (or no record) means count again.
fsig() { stat -L -c '%s %Y' "$1" 2>/dev/null || stat -L -f '%z %m' "$1"; }
if [[ $engine == docker ]]; then img_id=$(docker image inspect -f '{{.Id}}' "$img_counts" 2>/dev/null || echo "$img_counts")
else img_id="$img_counts $(fsig "$img_counts")"; fi
fingerprint=$(
  echo "version $VERSION"
  echo "image $img_id"
  echo "reference $manifest_sha"
  echo "qc $min_unique $min_assigned"
  IFS=',' read -r -a fq_r1 <<< "$r1"; for f in "${fq_r1[@]}"; do echo "r1 $f $(fsig "$f")"; done
  if [[ -n $r2 ]]; then IFS=',' read -r -a fq_r2 <<< "$r2"; for f in "${fq_r2[@]}"; do echo "r2 $f $(fsig "$f")"; done; fi
)
fp_file=$counts_dir/.$sample.inputs
reuse_counts=0
if [[ -s $counts && $force == 0 && -f $fp_file && $(cat "$fp_file") == "$fingerprint" ]]; then
  reuse_counts=1
  if [[ $keep_bam == 1 && ( ! -s $sdir/bam/$sample.bam || ! -s $sdir/bam/$sample.bam.bai ) ]]; then
    echo "== --keep-bam requested but the retained BAM/index is missing; aligning and counting again"
    reuse_counts=0
  fi
fi

# Once a rerun starts, its previous classification must not be shown or synced as
# current, even if alignment, counting or classification fails. New classifier
# outputs are staged below so failures cannot publish a partial replacement.
for ext in mdall.json mdall.tsv predictions.tsv vst.tsv.gz mdall.log; do
  rm -f "$mdall_dir/$sample.$ext"
done

if [[ $reuse_counts == 1 ]]; then
  echo "== counts exist for these exact inputs; skipping alignment (use --force to redo)"
else
  if [[ -s $counts && $force == 0 ]]; then
    echo "== existing counts cannot be reused for this run; counting again"
  fi
  rm -f "$fp_file"
  # A retained BAM from the previous inputs must not satisfy a later --keep-bam.
  rm -f "$sdir/bam/$sample.bam" "$sdir/bam/$sample.bam.bai"
  echo "== [1/3] STAR alignment + sort"
  run_in "$img_counts" "$work" cog_align.sh "$sample" "$refs/star_index" "$threads" "$r1" $r2
  echo "== [2/3] htseq-count + DUX4 patch + RNA-SeQC + gene-body coverage"
  run_in "$img_counts" "$work" cog_count.sh --sample "$sample" --center "$center" \
      --bam "$sample.bam" --gtf "$refs/genes.gtf" --collapsed-gtf "$refs/genes.collapsed.gtf" --star-log "$sample.Log.final.out" \
      --manifest-sha "$manifest_sha" --min-unique-pct "$min_unique" --min-assigned "$min_assigned" \
      --runner cog-ball-run.sh --run-id "$run_id" --container "$img_counts"
  for f in htseq.tsv htseq.dux4patched.tsv counts_qc.json versions.json rnaseqc.metrics.tsv genebody.tsv; do cp "$work/$sample.$f" "$counts_dir/"; done
  cp "$work/$sample.Log.final.out" "$counts_dir/$sample.star.Log.final.out"
  if [[ $keep_bam == 1 ]]; then mkdir -p "$sdir/bam"; cp "$work/$sample.bam" "$work/$sample.bam.bai" "$sdir/bam/"; fi
  printf '%s\n' "$fingerprint" > "$fp_file"   # written last: only complete counts get a record
fi

# ── 2. MD-ALL (same command as pipelines/02-classify) ────────────────────────
echo "== [3/3] MD-ALL expression classifier"
classify_work=$(mktemp -d "$mdall_dir/.classify.XXXXXX")
trap 'rm -rf "$classify_work"' EXIT
run_in "$img_mdall" "$classify_work" mdall_classify.R --counts "$counts" --sample "$sample" --center "$center" \
    --cores "$threads" --outdir . 2>&1 | tee "$mdall_dir/$sample.mdall.log"
# Check the complete output set before publishing anything; JSON is published last
# because its presence tells the website that the sample has been classified.
for ext in mdall.tsv predictions.tsv vst.tsv.gz mdall.json; do
  [[ -s $classify_work/$sample.$ext ]] || die "classifier output missing or empty: $sample.$ext"
done
for ext in mdall.tsv predictions.tsv vst.tsv.gz mdall.json; do
  mv "$classify_work/$sample.$ext" "$mdall_dir/$sample.$ext"
done

if [[ $keep_work == 0 && $work == "$sdir/work" ]]; then rm -rf "$work"; fi

# ── Summary ───────────────────────────────────────────────────────────────────
awk -F'\t' 'NR==1{for(i=1;i<=NF;i++)c[$i]=i; next}
  {printf "\n== %s: MD-ALL call %s (%s)  PhenoGraph %s %.2f | SVM %s %.2f\n", $c["sample_id"],
     ($c["gep_call"]==""?"needs review":$c["gep_call"]), $c["agreement"],
     $c["phenoGraph_pred"], $c["phenoGraph_predScore"], $c["svm_pred"], $c["svm_predScore"]}' \
  "$mdall_dir/$sample.mdall.tsv"
echo "   results: $sdir"
echo "   log:     $log"
echo "   sync:    bin/sync_results.sh $outdir/$center <hub-root>/$center"
