#!/usr/bin/env python3
"""Summarise STAR and HTSeq logs for one sample into a QC JSON.

Usage:
  counts_qc.py --sample S --center C --star-log Log.final.out \
               --htseq S.htseq.dux4patched.tsv --out S.counts_qc.json \
               [--rnaseqc S.rnaseqc.metrics.tsv] [--genebody S.genebody.tsv] \
               [--min-unique-pct 50] [--min-assigned 5000000]

Flags are advisory: they are shown on the results website, never block a run.
"""
import argparse
import json
import re
import sys


def parse_star_log(path):
    """Return the numeric fields of STAR's Log.final.out keyed by a short name."""
    wanted = {
        "Number of input reads": "input_reads",
        "Average input read length": "avg_input_read_length",
        "Uniquely mapped reads number": "uniquely_mapped",
        "Uniquely mapped reads %": "uniquely_mapped_pct",
        "Number of reads mapped to multiple loci": "multi_mapped",
        "% of reads mapped to multiple loci": "multi_mapped_pct",
        "Number of reads mapped to too many loci": "too_many_loci",
        "% of reads unmapped: too many mismatches": "unmapped_mismatches_pct",
        "% of reads unmapped: too short": "unmapped_too_short_pct",
        "% of reads unmapped: other": "unmapped_other_pct",
        "Number of chimeric reads": "chimeric",
        "% of chimeric reads": "chimeric_pct",
        "Mismatch rate per base, %": "mismatch_rate_pct",
    }
    out = {}
    with open(path) as fh:
        for line in fh:
            if "|" not in line:
                continue
            key, value = (s.strip() for s in line.split("|", 1))
            if key in wanted:
                value = value.rstrip("%")
                try:
                    out[wanted[key]] = float(value) if "." in value else int(value)
                except ValueError:
                    out[wanted[key]] = value
    unmapped = [out.get(k) for k in ("unmapped_mismatches_pct", "unmapped_too_short_pct", "unmapped_other_pct")]
    if all(isinstance(v, (int, float)) for v in unmapped):
        out["unmapped_pct"] = round(sum(unmapped), 2)
    return out


def parse_rnaseqc(path):
    """RNA-SeQC 2 metrics.tsv: one 'Metric<TAB>Value' per line."""
    out = {}
    with open(path) as fh:
        for line in fh:
            parts = line.rstrip("\n").split("\t")
            if len(parts) != 2 or parts[0] == "Sample":
                continue
            try:
                out[parts[0]] = float(parts[1]) if any(c in parts[1] for c in ".eE") else int(parts[1])
            except ValueError:
                out[parts[0]] = parts[1]
    return out


def parse_genebody(path):
    genes, profile = None, []
    with open(path) as fh:
        for line in fh:
            if line.startswith("# genes="):
                genes = int(line.strip().split("=")[1])
            elif line[0].isdigit():
                v = line.rstrip("\n").split("\t")[1]
                profile.append(None if v == "nan" else float(v))
    return {"genes": genes, "profile": profile}


def parse_htseq(path):
    genes = 0
    assigned = 0
    nonzero = 0
    special = {}
    with open(path) as fh:
        for line in fh:
            parts = line.rstrip("\n").split("\t")
            if len(parts) < 2:
                continue
            name, count = parts[0], int(parts[1])
            if name.startswith("__"):
                special[name.lstrip("_")] = count
                continue
            genes += 1
            assigned += count
            nonzero += count > 0
    return {
        "genes": genes,
        "genes_detected": nonzero,
        "assigned_reads": assigned,
        "no_feature": special.get("no_feature"),
        "ambiguous": special.get("ambiguous"),
        "too_low_aQual": special.get("too_low_aQual"),
        "not_aligned": special.get("not_aligned"),
        "alignment_not_unique": special.get("alignment_not_unique"),
        "dux4_regions_scanned": special.get("DUX4"),
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sample", required=True)
    ap.add_argument("--center", required=True)
    ap.add_argument("--star-log", required=True)
    ap.add_argument("--htseq", required=True)
    ap.add_argument("--dux4-count", type=int, default=None,
                    help="DUX4 (ENSG00000260596) count after patching")
    ap.add_argument("--rnaseqc", default=None, help="RNA-SeQC metrics.tsv")
    ap.add_argument("--genebody", default=None, help="gene_body_coverage.py output")
    ap.add_argument("--out", required=True)
    ap.add_argument("--min-unique-pct", type=float, default=50.0)
    ap.add_argument("--min-assigned", type=int, default=5_000_000)
    args = ap.parse_args()

    star = parse_star_log(args.star_log)
    htseq = parse_htseq(args.htseq)

    flags = []
    if star.get("uniquely_mapped_pct", 0) < args.min_unique_pct:
        flags.append(f"uniquely mapped {star.get('uniquely_mapped_pct')}% < {args.min_unique_pct}%")
    if htseq["assigned_reads"] < args.min_assigned:
        flags.append(f"{htseq['assigned_reads']:,} reads assigned to genes < {args.min_assigned:,}")

    qc = {
        "sample_id": args.sample,
        "center_id": args.center,
        "star": star,
        "htseq": htseq,
        "dux4_patched_count": args.dux4_count,
        "rnaseqc": parse_rnaseqc(args.rnaseqc) if args.rnaseqc else None,
        "genebody": parse_genebody(args.genebody) if args.genebody else None,
        "thresholds": {"min_unique_pct": args.min_unique_pct, "min_assigned": args.min_assigned},
        "flags": flags,
        "pass": not flags,
    }
    with open(args.out, "w") as fh:
        json.dump(qc, fh, indent=2)
    print(json.dumps({"sample": args.sample, "pass": qc["pass"], "flags": flags}))


if __name__ == "__main__":
    sys.exit(main())
