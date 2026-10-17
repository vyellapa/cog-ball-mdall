#!/usr/bin/env python3
"""Build the gene-level DUX4 BED used by the MD-ALL DUX4 patch.

MD-ALL's repository ships an exon-level BED (52 rows, ids like ENSG00000260596:001).
With it the patch script cannot match HTSeq's gene ids and only appends extra rows,
so the DUX4 gene count is never updated. MD-ALL's reference and test files were
patched with a gene-level BED of 42 DUX4/DUX4L genes (their HTSeq files report
"__DUX4 42" and contain no ":00N" rows; gu-lab20/RNAseq config names it
Homo_sapiens.GRCh38.V102.withChr.DUX4.bed but does not publish it).

This rebuilds it: the 42 gene ids from the exon BED, with gene coordinates from the
prepared Ensembl 102 GTF, 0-based starts as in the exon BED.

  make_dux4_gene_bed.py --exon-bed ...Exon.DUX4.bed --gtf genes.gtf > ...DUX4.genes.bed
"""
import argparse
import re
import sys

ap = argparse.ArgumentParser()
ap.add_argument("--exon-bed", required=True)
ap.add_argument("--gtf", required=True)
args = ap.parse_args()

order, info = [], {}
for line in open(args.exon_bed):
    chrom, start, end, name, biotype, ident = line.split()[:6]
    gene = ident.split(":")[0]
    if gene not in info:
        order.append(gene)
        info[gene] = (name, biotype)

found = {}
gid = re.compile(r'gene_id "([^"]+)"')
for line in open(args.gtf):
    if line.startswith("#"):
        continue
    f = line.rstrip("\n").split("\t")
    if f[2] != "gene":
        continue
    g = gid.search(f[8]).group(1)
    if g in info:
        found[g] = (f[0], int(f[3]) - 1, int(f[4]))

missing = [g for g in order if g not in found]
if missing:
    sys.exit(f"Genes not in GTF: {', '.join(missing)}")
for g in order:
    chrom, start, end = found[g]
    name, biotype = info[g]
    print(f"{chrom}\t{start}\t{end}\t{name}\t{biotype}\t{g}")
print(f"{len(order)} DUX4 genes written", file=sys.stderr)
