#!/usr/bin/env python3
"""Write reference_manifest.json for a reference bundle (genes.gtf + star_index/).

Called by pipelines/00-reference and bin/cog-ball-reference.sh.

  make_reference_manifest.py --bundle DIR --genome-url U --genome-sha256 S \
      --gtf-url U --gtf-sha256 S --sjdb-overhang 100 --sa-sparse 1
"""
import argparse
import datetime
import hashlib
import json
import os
import subprocess


def sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


ap = argparse.ArgumentParser()
ap.add_argument("--bundle", required=True)
ap.add_argument("--genome-url", required=True)
ap.add_argument("--genome-sha256", required=True)
ap.add_argument("--gtf-url", required=True)
ap.add_argument("--gtf-sha256", required=True)
ap.add_argument("--sjdb-overhang", type=int, default=100)
ap.add_argument("--sa-sparse", type=int, default=1)
a = ap.parse_args()

star_ver = subprocess.run(["STAR", "--version"], capture_output=True, text=True).stdout.strip()
gtf = os.path.join(a.bundle, "genes.gtf")
idx = os.path.join(a.bundle, "star_index")
manifest = {
    "reference_id": f"GRCh38-analysis-set_Ensembl102_STAR{star_ver}_sjdb{a.sjdb_overhang}",
    "created_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "pipeline_version": os.environ.get("COG_BALL_VERSION", "unknown"),
    "genome": {"url": a.genome_url, "sha256": a.genome_sha256},
    "gtf": {"url": a.gtf_url, "sha256": a.gtf_sha256, "prepared_sha256": sha(gtf),
            "contigs": "chr1-22,chrX,chrY,chrM", "genes": 60616},
    "collapsed_gtf": ({"file": "genes.collapsed.gtf", "sha256": sha(os.path.join(a.bundle, "genes.collapsed.gtf")),
                       "made_by": "GTEx collapse_annotation.py", "used_for": "RNA-SeQC QC only"}
                      if os.path.exists(os.path.join(a.bundle, "genes.collapsed.gtf")) else None),
    "dux4_bed": {"path_in_image": os.environ.get("DUX4_BED"), "sha256": sha(os.environ["DUX4_BED"])},
    "star": {"version": star_ver, "sjdbOverhang": a.sjdb_overhang, "genomeSAsparseD": a.sa_sparse,
             "genomeParameters_sha256": sha(os.path.join(idx, "genomeParameters.txt"))},
}
with open(os.path.join(a.bundle, "reference_manifest.json"), "w") as fh:
    json.dump(manifest, fh, indent=2)
print(json.dumps(manifest, indent=2))
