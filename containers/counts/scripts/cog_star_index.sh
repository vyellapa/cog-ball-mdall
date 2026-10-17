#!/usr/bin/env bash
# Build the STAR index of the reference bundle. Called by pipelines/00-reference and
# bin/cog-ball-reference.sh.
#
#   cog_star_index.sh <genome.fa> <genes.gtf> <out_dir> <threads> <sa_sparse> <ram_bytes>
set -euo pipefail
[[ $# -eq 6 ]] || { sed -n '2,6p' "$0"; exit 2; }
fasta=$1 gtf=$2 out=$3 threads=$4 sparse=$5 ram=$6
mkdir -p "$out"
STAR --runMode genomeGenerate \
    --runThreadN "$threads" \
    --genomeDir "$out" \
    --genomeFastaFiles "$fasta" \
    --sjdbGTFfile "$gtf" \
    --sjdbOverhang 100 \
    --genomeSAsparseD "$sparse" \
    --limitGenomeGenerateRAM "$ram" \
    --outFileNamePrefix "$out/"
