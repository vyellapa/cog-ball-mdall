#!/usr/bin/env python3
"""Make the Ensembl GTF match the GRCh38 analysis-set FASTA the way MD-ALL's
reference was counted.

MD-ALL's reference (gu-lab20/RNAseq: Homo_sapiens.GRCh38.V102.withChr.gtf) counts
60,616 genes: everything on chromosomes 1-22, X, Y and MT, with UCSC names
(chr1 ... chrY, chrM). Genes on unplaced/unlocalized scaffolds are not counted.
This script keeps exactly those contigs, renames them, and checks every kept
contig exists in the FASTA headers so no gene silently gets zero counts.

Usage:
  prepare_gtf.py --gtf Homo_sapiens.GRCh38.102.gtf.gz --fasta-headers headers.txt \
                 --out genes.gtf [--expect-genes 60616]
"""
import argparse
import gzip
import sys

PRIMARY = [str(i) for i in range(1, 23)] + ["X", "Y", "MT"]


def ucsc(name):
    return "chrM" if name == "MT" else f"chr{name}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--gtf", required=True)
    ap.add_argument("--fasta-headers", required=True, help="'>' lines of the genome FASTA")
    ap.add_argument("--out", required=True)
    ap.add_argument("--expect-genes", type=int, default=60616)
    args = ap.parse_args()

    with open(args.fasta_headers) as fh:
        fasta_contigs = {line[1:].split()[0] for line in fh if line.startswith(">")}
    missing = [ucsc(c) for c in PRIMARY if ucsc(c) not in fasta_contigs]
    if missing:
        sys.exit(f"FASTA lacks contigs: {', '.join(missing)}")

    opener = gzip.open if args.gtf.endswith(".gz") else open
    keep = set(PRIMARY)
    genes = dropped_genes = 0
    with opener(args.gtf, "rt") as src, open(args.out, "w") as dst:
        for line in src:
            if line.startswith("#"):
                dst.write(line)
                continue
            fields = line.split("\t", 2)
            if fields[0] not in keep:
                if len(fields) > 2 and fields[2].startswith("gene\t"):
                    dropped_genes += 1
                continue
            if fields[2].startswith("gene\t"):
                genes += 1
            dst.write(ucsc(fields[0]) + "\t" + fields[1] + "\t" + fields[2])

    print(f"kept {genes} genes on {len(PRIMARY)} primary contigs; dropped {dropped_genes} scaffold genes")
    if args.expect_genes and genes != args.expect_genes:
        sys.exit(f"Expected {args.expect_genes} genes (MD-ALL reference), got {genes}. Wrong GTF release?")


if __name__ == "__main__":
    main()
