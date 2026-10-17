#!/usr/bin/env bash
# Gene counts, DUX4 patch, QC and provenance for one aligned sample, in the current
# directory. The single definition of the counting step: called by
# pipelines/01-counts and by bin/cog-ball-run.sh.
#
#   cog_count.sh --sample S --center C --bam S.bam --gtf genes.gtf --collapsed-gtf genes.collapsed.gtf \
#                --star-log S.Log.final.out --manifest-sha SHA256 \
#                [--min-unique-pct 50] [--min-assigned 5000000] \
#                [--runner NAME] [--run-id ID] [--container IMAGE]
#
# Writes <S>.htseq.tsv, <S>.htseq.dux4patched.tsv, <S>.rnaseqc.metrics.tsv,
# <S>.genebody.tsv, <S>.counts_qc.json, <S>.versions.json.
set -euo pipefail
min_unique=50 min_assigned=5000000 runner=unknown run_id=unknown container=unknown
while [[ $# -gt 0 ]]; do
  case $1 in
    --sample) sample=$2 ;; --center) center=$2 ;; --bam) bam=$2 ;; --gtf) gtf=$2 ;;
    --collapsed-gtf) cgtf=$2 ;;
    --star-log) star_log=$2 ;; --manifest-sha) manifest_sha=$2 ;;
    --min-unique-pct) min_unique=$2 ;; --min-assigned) min_assigned=$2 ;;
    --runner) runner=$2 ;; --run-id) run_id=$2 ;; --container) container=$2 ;;
    *) sed -n '2,13p' "$0"; exit 2 ;;
  esac
  shift 2
done
: "${sample:?--sample}" "${center:?--center}" "${bam:?--bam}" "${gtf:?--gtf}" "${cgtf:?--collapsed-gtf}" "${star_log:?--star-log}" "${manifest_sha:?--manifest-sha}"

# htseq-count options copied verbatim from gu-lab20/RNAseq (rule HTSeq_count).
htseq-count -m intersection-strict -f bam -r pos -s no -a 10 "$bam" "$gtf" > "$sample.htseq.tsv"

# MD-ALL's HTSeqDUX4patch.pl, unmodified, with the gene-level DUX4 BED ($DUX4_BED).
# Run with the image's perl: the script's shebang (/usr/bin/perl) lacks Getopt::Std.
perl /opt/cog-ball/HTSeqDUX4patch.pl -f "$DUX4_BED" -b "$bam" -h "$sample.htseq.tsv" -o "$sample.htseq.dux4patched.tsv"

# QC only (does not change counts): RNA-SeQC 2 metrics and a 5'->3' gene-body profile.
unpaired=()
[[ -n $(samtools view -f 1 "$bam" 2>/dev/null | head -1) ]] || unpaired=(--unpaired)
# --mapping-quality 60: STAR here marks unique hits MAPQ 60 (--outSAMmapqUnique 60, as in
# gu-lab's settings); RNA-SeQC's default of 255 would treat every read as low quality.
rnaseqc "$cgtf" "$bam" rnaseqc_out -s "$sample" --mapping-quality 60 "${unpaired[@]}" > rnaseqc.log 2>&1 || { cat rnaseqc.log >&2; exit 1; }
mv "rnaseqc_out/$sample.metrics.tsv" "$sample.rnaseqc.metrics.tsv"
rm -rf rnaseqc_out
gene_body_coverage.py --bam "$bam" --gtf "$gtf" --counts "$sample.htseq.tsv" --out "$sample.genebody.tsv"

counts_qc.py --sample "$sample" --center "$center" \
    --star-log "$star_log" --htseq "$sample.htseq.dux4patched.tsv" \
    --rnaseqc "$sample.rnaseqc.metrics.tsv" --genebody "$sample.genebody.tsv" \
    --dux4-count "$(awk '$1=="ENSG00000260596"{print $2}' "$sample.htseq.dux4patched.tsv")" \
    --min-unique-pct "$min_unique" --min-assigned "$min_assigned" \
    --out "$sample.counts_qc.json"

cat > "$sample.versions.json" <<EOF
{
  "pipeline": "cog-ball/01-counts",
  "pipeline_version": "${COG_BALL_VERSION:-unknown}",
  "runner": "$runner",
  "container": "$container",
  "star": "$(STAR --version)",
  "samtools": "$(samtools --version | head -1 | cut -d' ' -f2)",
  "htseq": "$(htseq-count --version)",
  "rnaseqc": "$(rnaseqc --version 2>&1 | tr -d '\n' | sed 's/^RNASeQC //')",
  "dux4_bed_sha256": "$(sha256sum "$DUX4_BED" | cut -d' ' -f1)",
  "reference_manifest_sha256": "$manifest_sha",
  "run_id": "$run_id",
  "completed_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
