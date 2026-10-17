---
license: other
license_name: public-reference-data
license_link: LICENSE
pretty_name: COG B-ALL MD-ALL reference bundle (GRCh38 + Ensembl 102, STAR 2.7.11b)
tags:
  - biology
  - genomics
  - rna-seq
  - star-aligner
  - leukemia
  - b-all
size_categories:
  - n<1K
extra_gated_prompt: >-
  This reference bundle is provided for the COG B-ALL working group's MD-ALL
  classification pipeline. Please tell us your center and how you will use it.
extra_gated_fields:
  Center or institution: text
  Intended use: text
---

# COG B-ALL MD-ALL reference bundle

The ready-made reference used by the COG B-ALL MD-ALL pipeline, so every center aligns
and counts against byte-identical files instead of building them (about 1 hour and
40 GB RAM per site).

| File | Size | What it is |
|---|---|---|
| `star_index/` | 28 GB | STAR 2.7.11b index, `--sjdbOverhang 100`, `--genomeSAsparseD 1` |
| `genes.gtf` | 1.3 GB | Ensembl 102, chr1–22/X/Y/MT only (60,616 genes, the genes in MD-ALL's reference), contigs renamed to `chr*`/`chrM` |
| `genes.collapsed.gtf` | 0.14 GB | one transcript per gene (GTEx `collapse_annotation.py`), used only for RNA-SeQC QC |
| `reference_manifest.json` | | sources, checksums and build parameters |
| `SHA256SUMS` | | SHA-256 of every file above |

## Download and use

With the pipeline repository (needs only `curl`; resumes if interrupted; checks every
file against `SHA256SUMS`):

```bash
bin/cog-ball-reference.sh --download          # writes to REFS from site.conf
```

Or with the Hugging Face CLI:

```bash
hf download __HF_REPO__ --repo-type dataset --revision v__VERSION__ --local-dir /data/cog-ball/refs
cd /data/cog-ball/refs && sha256sum -c SHA256SUMS
```

This dataset is gated: request access on this page once, then `hf auth login` (or set
`HF_TOKEN`) before downloading.

## How it was built

`bin/cog-ball-reference.sh` / `pipelines/00-reference` of the COG pipeline, version __VERSION__:

* Genome: GRCh38 no-alt analysis set + hs38d1 decoys, NCBI
  `GCA_000001405.15_GRCh38_no_alt_plus_hs38d1_analysis_set.fna.gz`
  (SHA-256 `08959902840a28f410ad1220e36b2a3fbe2cb90beecceb6ea5b050a0e68ed96d`)
* Annotation: Ensembl release 102 `Homo_sapiens.GRCh38.102.gtf.gz`
  (SHA-256 `307038294611aaf86c3e61e70273a26c7b3a343cd416feed137e6e86d471ea32`)
* STAR 2.7.11b `--runMode genomeGenerate --sjdbOverhang 100`

This matches how MD-ALL's 1,821-sample reference cohort was counted (gu-lab20/RNAseq).
The index was built twice, by the Nextflow pipeline and by the standalone script, and
both builds were byte-identical.

## Sources and licence

Derived entirely from public reference data: the GRCh38 assembly from NCBI (public
domain) and Ensembl release 102 annotation (no restrictions on use). No patient or
sample data is included. Research use only.
