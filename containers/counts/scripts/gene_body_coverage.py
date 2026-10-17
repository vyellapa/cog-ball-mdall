#!/usr/bin/env python3
"""Gene-body coverage (5'->3') profile for one sample.

Same idea as Picard CollectRnaSeqMetrics / RSeQC geneBody_coverage: take the sample's
most highly expressed protein-coding genes, walk one representative transcript of
each gene in transcription order, split its exonic length into 100 equal bins, take
the mean read depth per bin, scale each gene to its own mean, and average across
genes. A flat line means even coverage; a curve rising toward 100 means 3' bias
(typical of degraded RNA).

The representative transcript follows Ensembl's pre-MANE canonical rule (Ensembl 102
has no canonical tag): the CCDS transcript with the longest coding sequence, else the
longest coding transcript. A merged/collapsed gene model is not used here because it
stretches every gene to its longest alternative 3' end and makes the curve sag at 3'.

  gene_body_coverage.py --bam S.bam --gtf genes.gtf --counts S.htseq.tsv \
      --out S.genebody.tsv [--genes 1000] [--min-length 1000]

Output: TSV with columns percentile (1..100) and coverage; the number of genes used
is written as a '# genes=N' header line.
"""
import argparse
import re
from collections import defaultdict

import numpy as np
import pysam

ap = argparse.ArgumentParser()
ap.add_argument("--bam", required=True)
ap.add_argument("--gtf", required=True, help="full gene annotation (genes.gtf of the reference bundle)")
ap.add_argument("--counts", required=True, help="HTSeq counts, used to pick expressed genes")
ap.add_argument("--out", required=True)
ap.add_argument("--genes", type=int, default=1000)
ap.add_argument("--min-length", type=int, default=1000, help="minimum exonic length (bp)")
args = ap.parse_args()

attr_re = {k: re.compile(k + r' "([^"]+)"') for k in ("gene_id", "transcript_id", "gene_biotype", "transcript_biotype")}
tx_exons, tx_cds, tx_gene, tx_ccds, tx_coding, gene_loc = defaultdict(list), defaultdict(int), {}, set(), set(), {}
with open(args.gtf) as fh:
    for line in fh:
        if line.startswith("#"):
            continue
        f = line.rstrip("\n").split("\t")
        if f[2] not in ("transcript", "exon", "CDS") or f[0] in ("chrM", "MT"):
            continue
        if 'gene_biotype "protein_coding"' not in f[8]:
            continue
        t = attr_re["transcript_id"].search(f[8]).group(1)
        if f[2] == "transcript":
            g = attr_re["gene_id"].search(f[8]).group(1)
            tx_gene[t] = g
            gene_loc[g] = (f[0], f[6])
            if 'tag "CCDS"' in f[8]:
                tx_ccds.add(t)
            if 'transcript_biotype "protein_coding"' in f[8]:
                tx_coding.add(t)
        elif f[2] == "exon":
            tx_exons[t].append((int(f[3]) - 1, int(f[4])))   # 0-based half-open
        else:
            tx_cds[t] += int(f[4]) - int(f[3]) + 1

# Representative transcript per gene: longest CDS among CCDS transcripts, else among
# coding transcripts; ties broken by exonic length, then transcript id.
by_gene = defaultdict(list)
for t, g in tx_gene.items():
    if t in tx_coding and tx_exons[t]:
        by_gene[g].append(t)
exons, info = {}, {}
for g, ts in by_gene.items():
    pool = [t for t in ts if t in tx_ccds] or ts
    best = max(pool, key=lambda t: (tx_cds[t], sum(e - s for s, e in tx_exons[t]), t))
    exons[g], info[g] = tx_exons[best], gene_loc[g]

counts = {}
with open(args.counts) as fh:
    for line in fh:
        g, c = line.rstrip("\n").split("\t")[:2]
        if not g.startswith("__"):
            counts[g] = int(c)

def exonic_length(g):
    return sum(e - s for s, e in exons[g])

candidates = [g for g in exons if exonic_length(g) >= args.min_length and counts.get(g, 0) > 0]
chosen = sorted(candidates, key=lambda g: (-counts[g], g))[: args.genes]

bins = 100
profiles = []
with pysam.AlignmentFile(args.bam) as bam:
    for g in chosen:
        chrom, strand = info[g]
        depth = []
        for s, e in sorted(exons[g]):
            acgt = bam.count_coverage(chrom, s, e, quality_threshold=0)
            depth.append(np.sum(acgt, axis=0))
        depth = np.concatenate(depth).astype(float)
        if strand == "-":
            depth = depth[::-1]
        if depth.mean() <= 0:
            continue
        edges = np.linspace(0, len(depth), bins + 1).astype(int)
        prof = np.array([depth[a:b].mean() for a, b in zip(edges[:-1], edges[1:])])
        profiles.append(prof / prof.mean())

profile = np.mean(profiles, axis=0) if profiles else np.full(bins, np.nan)
with open(args.out, "w") as out:
    out.write(f"# genes={len(profiles)}\n")
    out.write("percentile\tcoverage\n")
    for i, v in enumerate(profile, 1):
        out.write(f"{i}\t{v:.4f}\n")
print(f"gene-body coverage from {len(profiles)} genes")
