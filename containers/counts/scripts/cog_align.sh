#!/usr/bin/env bash
# STAR two-pass alignment + coordinate sort + index for one sample, in the current
# directory. The single definition of the alignment step: called by
# pipelines/01-counts and by bin/cog-ball-run.sh.
#
#   cog_align.sh <sample> <star_index_dir> <threads> <r1[,r1_lane2,...]> [<r2[,r2_lane2,...]>]
#
# Writes <sample>.bam, <sample>.bam.bai, <sample>.Log.final.out and, when STAR finds
# chimeric reads, <sample>.Chimeric.out.junction.
set -euo pipefail
[[ $# -ge 4 ]] || { sed -n '2,10p' "$0"; exit 2; }
sample=$1 index=$2 threads=$3 reads1=$4 reads2=${5:-}

zipped=()
[[ ${reads1%%,*} == *.gz ]] && zipped=(--readFilesCommand zcat)

# Parameters copied verbatim from gu-lab20/RNAseq rnaseq.smk (rule Star), which is
# how MD-ALL's reference cohort was aligned.
STAR \
    --twopassMode Basic \
    --runThreadN "$threads" \
    "${zipped[@]}" \
    --limitOutSAMoneReadBytes 90000000 \
    --outSAMtype BAM Unsorted \
    --outSAMstrandField intronMotif \
    --outSAMunmapped Within \
    --outSAMmapqUnique 60 \
    --outSAMmultNmax 1 \
    --outReadsUnmapped None \
    --outMultimapperOrder Random \
    --outSAMattributes NH HI AS nM NM MD \
    --outSAMattrRGline "ID:$sample" PL:ILLUMINA PU:ILLUMINA LB:RNAseq "SM:$sample" \
    --outFilterType BySJout \
    --outFilterMultimapNmax 100 \
    --outFilterMismatchNmax 999 \
    --outFilterMismatchNoverReadLmax 0.04 \
    --alignIntronMin 20 \
    --alignSJstitchMismatchNmax 5 -1 5 5 \
    --alignIntronMax 1000000 \
    --alignMatesGapMax 1000000 \
    --alignSJoverhangMin 8 \
    --alignSJDBoverhangMin 4 \
    --alignInsertionFlush Right \
    --chimOutType Junctions \
    --chimSegmentMin 12 \
    --chimJunctionOverhangMin 12 \
    --chimSegmentReadGapMax 3 \
    --chimMultimapNmax 100 \
    --chimMultimapScoreRange 10 \
    --chimNonchimScoreDropMin 10 \
    --chimOutJunctionFormat 1 \
    --peOverlapNbasesMin 12 \
    --peOverlapMMp 0.1 \
    --outFileNamePrefix star/ \
    --genomeDir "$index" \
    --genomeLoad NoSharedMemory \
    --readFilesIn "$reads1" $reads2 \
    --sjdbOverhang 100

mv star/Log.final.out "$sample.Log.final.out"
if [[ -f star/Chimeric.out.junction ]]; then mv star/Chimeric.out.junction "$sample.Chimeric.out.junction"; fi
samtools sort -m 1G -@ "$threads" -O bam -T sort_tmp -o "$sample.bam" star/Aligned.out.bam
samtools index "$sample.bam"
rm -rf star sort_tmp*
