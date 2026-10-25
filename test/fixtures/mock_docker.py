#!/usr/bin/env python3
"""Tiny container fixture for the standalone runner's failure/reuse tests."""
import gzip
import hashlib
import json
import os
from pathlib import Path
import sys


args = sys.argv[1:]
if args[:2] == ["image", "inspect"]:
    print("sha256:test-counts-image")
    sys.exit(0)

assert args[0] == "run", args
work_arg = args.index("-w")
work = Path(args[work_arg + 1])
command = args[work_arg + 3]
argv = args[work_arg + 4:]
os.chdir(work)
with open(os.environ["MOCK_CALLS"], "a") as log:
    log.write(json.dumps({"command": command, "work": str(work)}) + "\n")


def option(flag):
    return argv[argv.index(flag) + 1]


step = {"cog_align.sh": "align", "cog_count.sh": "count", "mdall_classify.R": "classify"}[command]
failure = os.environ.get("MOCK_FAIL_STEP")
if failure == step:
    print(f"simulated {step} failure", file=sys.stderr)
    sys.exit(42)

if step == "align":
    sample = argv[0]
    for ext in ["bam", "bam.bai", "Log.final.out"]:
        Path(f"{sample}.{ext}").write_text("alignment for " + Path(argv[3]).read_text())
elif step == "count":
    sample = option("--sample")
    for ext in ["htseq.tsv", "htseq.dux4patched.tsv"]:
        Path(f"{sample}.{ext}").write_text(os.environ.get("MOCK_COUNTS", "ENSG1\t1\n"))
    for ext in ["counts_qc.json", "versions.json"]:
        Path(f"{sample}.{ext}").write_text("{}")
    for ext in ["rnaseqc.metrics.tsv", "genebody.tsv"]:
        Path(f"{sample}.{ext}").write_text("fixture\n")
else:
    sample = option("--sample")
    counts = Path(option("--counts"))
    result = {
        "call": {"gep_call": "Ph", "agreement": "concordant"},
        "input": {"counts_md5": hashlib.md5(counts.read_bytes()).hexdigest()},
    }
    Path(f"{sample}.mdall.json").write_text(json.dumps(result))
    Path(f"{sample}.mdall.tsv").write_text(
        "sample_id\tgep_call\tagreement\tphenoGraph_pred\tphenoGraph_predScore\tsvm_pred\tsvm_predScore\n"
        f"{sample}\tPh\tconcordant\tPh\t1\tPh\t1\n"
    )
    Path(f"{sample}.predictions.tsv").write_text("method\tfeatureN\tpred\nSVM\t100\tPh\n")
    if failure != "classify_incomplete":
        with gzip.open(f"{sample}.vst.tsv.gz", "wt") as out:
            out.write("feature\tvst\nENSG1\t10\n")
    if failure == "classify_partial":
        print("simulated failure after writing outputs", file=sys.stderr)
        sys.exit(42)
