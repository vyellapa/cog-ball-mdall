#!/usr/bin/env python3
"""Compare 02-classify output with upstream MD-ALL's expected calls.

  test/check_classify.py <outdir>/<center> test/expected_mdall.tsv
Exit 0 only if every expected sample has identical PhenoGraph and SVM calls,
scores and labels.
"""
import csv, sys, pathlib
root, expected = pathlib.Path(sys.argv[1]), sys.argv[2]
cols = ["phenoGraph_pred", "phenoGraph_predScore", "phenoGraph_predLabel", "svm_pred", "svm_predScore", "svm_predLabel"]
bad = 0
for exp in csv.DictReader(open(expected), delimiter="\t"):
    s = exp["sample_id"]
    f = root / s / "mdall" / f"{s}.mdall.tsv"
    if not f.exists():
        print(f"MISSING  {s}: {f}"); bad += 1; continue
    got = next(csv.DictReader(open(f), delimiter="\t"))
    diffs = [f"{c}: expected {exp[c]!r} got {got[c]!r}" for c in cols if str(float(exp[c]) if 'Score' in c else exp[c]) != str(float(got[c]) if 'Score' in c else got[c])]
    print(("FAIL     " if diffs else "OK       ") + f"{s}: {got['svm_pred']} / {got['phenoGraph_pred']}" + ("".join("\n           " + d for d in diffs)))
    bad += bool(diffs)
print("\nAll samples match upstream MD-ALL." if not bad else f"\n{bad} sample(s) differ.")
sys.exit(1 if bad else 0)
