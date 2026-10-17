# syntax=docker/dockerfile:1
#
# cog-ball/counts — STAR, samtools, HTSeq, the MD-ALL DUX4 patch, and RNA-SeQC 2 QC.
# linux/amd64 only (RNA-SeQC has no ARM build); runs under emulation on Apple Silicon.
# Used by pipelines/00-reference (index build) and pipelines/01-counts (FASTQ -> counts).
#
# Build:  containers/build_images.sh          (reads ../../VERSION)
#
# Works with Docker and with Singularity/Apptainer (docker:// or a converted .sif):
# PATH is set explicitly so nothing depends on the micromamba entrypoint, which
# Singularity ignores.

FROM mambaorg/micromamba:2.0.5

COPY --chown=$MAMBA_USER:$MAMBA_USER environment.yml /tmp/environment.yml
RUN micromamba install -y -n base -f /tmp/environment.yml \
 && micromamba clean --all --yes

USER root
# DUX4 patch: MD-ALL's HTSeqDUX4patch.pl (unmodified) with the gene-level BED that
# matches how MD-ALL's reference was patched (see make_dux4_gene_bed.py).
COPY scripts/ /opt/cog-ball/
RUN chmod 755 /opt/cog-ball/*.pl /opt/cog-ball/*.py /opt/cog-ball/*.sh

ENV PATH=/opt/conda/bin:/opt/cog-ball:$PATH \
    DUX4_BED=/opt/cog-ball/Homo_sapiens.GRCh38.V102.withChr.DUX4.genes.bed \
    LC_ALL=C.UTF-8

# Fail the build if any tool is missing.
RUN ps --version && STAR --version && samtools --version | head -1 && htseq-count --version \
 && rnaseqc --version && python3 -c "import bx.intervals, pandas, pysam" \
 && perl -MGetopt::Std -e 1 && python3 --version && test -s "$DUX4_BED"

ARG COG_BALL_VERSION=dev
LABEL org.opencontainers.image.title="cog-ball-counts" \
      org.opencontainers.image.version="${COG_BALL_VERSION}" \
      org.opencontainers.image.description="STAR 2.7.11b + HTSeq 2.0.9 + MD-ALL DUX4 patch for COG B-ALL MD-ALL classification"
ENV COG_BALL_VERSION=${COG_BALL_VERSION}

USER $MAMBA_USER
