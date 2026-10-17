# COG B-ALL MD-ALL pipeline: technical details

How to install and run is in the [README](../README.md). This document explains what
the pipeline does and why, what it writes, how it is validated, and how the images are
built.

## Contents

- [Steps and images](#steps-and-images)
- [Why the results are the same at every center](#why-the-results-are-the-same-at-every-center)
- [Reading the MD-ALL call](#reading-the-md-all-call)
- [Alignment and counting QC](#alignment-and-counting-qc)
- [Results layout](#results-layout)
- [Counts made elsewhere](#counts-made-elsewhere)
- [The results website](#the-results-website)
- [Validation](#validation)
- [Building and distributing the images](#building-and-distributing-the-images)
- [Publishing the reference bundle](#publishing-the-reference-bundle)
- [Versioning](#versioning)
- [Repository layout](#repository-layout)
- [Credits](#credits)

## Steps and images

| Step | Nextflow pipeline | Standalone script | Image | What it does |
|---|---|---|---|---|
| 0 | `pipelines/00-reference` | `bin/cog-ball-reference.sh` | `cog-ball/counts` | Downloads and checksums the genome and annotation, builds the STAR index and the collapsed annotation. Once per site. |
| 1 | `pipelines/01-counts` | `bin/cog-ball-run.sh` (part 1) | `cog-ball/counts` | FASTQ → STAR two-pass → sorted BAM → `htseq-count` → MD-ALL DUX4 patch → RNA-SeQC + gene-body coverage QC. |
| 2 | `pipelines/02-classify` | `bin/cog-ball-run.sh` (part 2) | `cog-ball/mdall` | Gene counts → MD-ALL expression classifier, one sample at a time. |
| 3 | — | `bin/sync_results.sh` | — | Mirrors a center's results to the shared space. |
| 4 | — | — | `cog-ball/web` | Read-only website over the shared space. |

Both routes call the same commands, which live inside the images
(`cog_align.sh`, `cog_count.sh`, `cog_star_index.sh`, `mdall_classify.R`), and write
the same files. Running the same sample both ways gave identical MD-ALL results and
identical counts for every gene outside the DUX4 family (see below).

Only MD-ALL's **gene-expression classifier** is run: PhenoGraph clustering and SVM
models against MD-ALL's 1,821-sample reference
([gu-lab20/MD-ALL](https://github.com/gu-lab20/MD-ALL)). Its fusion, mutation and
RNAseqCNV modules are not used.

## Why the results are the same at every center

* **Counting matches MD-ALL's reference.** MD-ALL normalises a new sample together
  with its reference counts, so the new sample must be counted the way the reference
  was. Step 1 copies the gu-lab RNA-seq pipeline
  ([gu-lab20/RNAseq](https://github.com/gu-lab20/RNAseq)): the GRCh38 no-alt analysis
  set with hs38d1, Ensembl 102 restricted to chr1–22/X/Y/MT (exactly the 60,616 genes in
  MD-ALL's reference), STAR two-pass with gu-lab's parameters, and
  `htseq-count -m intersection-strict -s no -a 10`, followed by MD-ALL's DUX4 patch.
  Count files come out in exactly the format of MD-ALL's own patched test files (same
  60,616 genes in the same order, `__DUX4 42`).
* **DUX4 BED.** The BED in MD-ALL's repository is exon-level (ids like
  `ENSG00000260596:001`); with it the patch script cannot match HTSeq's gene ids and
  never updates the DUX4 count. MD-ALL's reference was patched with a 42-gene,
  gene-level BED that gu-lab has not published, so it is rebuilt from Ensembl 102 gene
  coordinates (`containers/counts/scripts/make_dux4_gene_bed.py`). If gu-lab can share
  their exact file, swap it in and bump `VERSION`.
* **Known run-to-run noise: DUX4 only.** gu-lab's STAR settings place multi-mapping
  reads at a random copy (`--outMultimapperOrder Random`), which is not repeatable with
  several threads. HTSeq ignores multi-mappers, so every gene count is identical between
  runs except the DUX4 family, whose patch counts those reads (±1–2 reads in testing).
  DUX4 is not an MD-ALL key gene; calls and scores were identical.
* **Pinned everything.** Genome and GTF are checked against SHA-256 sums; STAR 2.7.11b,
  HTSeq 2.0.9, samtools 1.21 and RNA-SeQC 2.4.2 are fixed in the counts image; MD-ALL
  (`3047c05`) and Rphenograph are pinned to commits in the mdall image. One `VERSION`
  file tags all three images.
* **One sample at a time.** DESeq2's VST is computed for each sample against the
  reference alone, so a call never depends on which other samples were in the run.
* **Deterministic.** Random seeds are fixed for imputation, PhenoGraph and the UMAP
  projection. The reference UMAP is built once, inside the image, and every sample is
  projected onto it, so samples from all centers share one map.
* **Provenance travels with each result.** Every `*.mdall.json` records the pipeline
  version, MD-ALL commit, R and package versions, the counts file's MD5, how many
  reference genes were present and whether any were imputed. Every counts folder
  records STAR, HTSeq, samtools and RNA-SeQC versions and the reference manifest hash.

## Reading the MD-ALL call

* MD-ALL runs PhenoGraph and SVM with 11 feature-set sizes (100 … 1,058 key genes).
  Each method's call is the subtype found in more than half its runs; the score is that
  fraction (shown as e.g. `0.91 (10/11 runs)`).
* **concordant**: both methods give the same subtype. This is the GEP call.
* **needs review**: the methods disagree. MD-ALL assigns a subtype automatically only
  when they agree, so these need expert review (fusion/karyotype data, the gene plots).
* MD-ALL's **Ph** expression group contains both Ph-positive (BCR::ABL1) and Ph-like
  cases. Expression alone cannot separate them.
* CRLF2, CDX2 and NUTM1 at VST ≥ 9 are listed as highly expressed, MD-ALL's own cut-off.
  A marker gene absent from a sample's counts is reported as NA, never imputed.

## Alignment and counting QC

QC never changes the counts or the call.

| Shown on the sample page | Source |
|---|---|
| Input reads, average read length, uniquely mapped, unmapped, chimeric | STAR `Log.final.out` |
| Exonic / intronic / intergenic rate, rRNA rate, mapping efficiency, genes detected (≥ 5 reads), median 3′ bias | RNA-SeQC 2.4.2 (`rnaseqc.metrics.tsv` has the full list) |
| Gene-body coverage curve | `gene_body_coverage.py`: mean 5′→3′ coverage of the sample's 1,000 most-expressed protein-coding genes, each scaled to its own mean |

* RNA-SeQC runs on the BAM STAR already made, with `genes.collapsed.gtf` (GTEx
  `collapse_annotation.py`, vendored at a pinned commit) and `--mapping-quality 60`
  (gu-lab's STAR settings mark unique reads MAPQ 60, not STAR's default 255).
* The coverage curve uses one transcript per gene, chosen by Ensembl's pre-MANE
  canonical rule (longest CCDS coding sequence), because merged gene models stretch
  genes to their longest alternative 3′ end.
* A median 3′ bias near 0.5 and a flat curve indicate intact RNA; values near 1 and a
  curve rising to the 3′ end indicate degradation. The curve's absolute shape also
  depends on library preparation, so it is most useful to compare samples and centers.
* RNA-SeQC is only published for x86-64, so the counts image is linux/amd64 only.
* `--min-unique-pct` / `--min-assigned` thresholds are recorded in `counts_qc.json`
  only; the website shows the numbers, not pass/fail labels.

## Results layout

```
<OUTDIR>/<CENTER>/
  <sample>/
    counts/
      <sample>.htseq.dux4patched.tsv   ENSG<tab>count — input to step 2
      <sample>.htseq.tsv               raw htseq-count output
      <sample>.star.Log.final.out      STAR alignment summary
      <sample>.rnaseqc.metrics.tsv     RNA-SeQC 2 metrics
      <sample>.genebody.tsv            5'->3' gene-body coverage profile (100 bins)
      <sample>.counts_qc.json          STAR + HTSeq + RNA-SeQC + coverage summary
      <sample>.versions.json           tool versions, image, reference manifest hash
      .<sample>.inputs                 standalone runs only: what the counts were made from
    mdall/
      <sample>.mdall.json              full result + provenance (read by the website)
      <sample>.mdall.tsv               one row; first 10 columns = classic MDall_output_*.txt
      <sample>.predictions.tsv         PhenoGraph and SVM call for each feature-set size
      <sample>.vst.tsv.gz              VST expression of all reference genes (gene search)
      <sample>.mdall.log
    bam/                               only with --save_bam / --keep-bam (never synced)
  pipeline_info/                       run logs, Nextflow reports, per-run summary TSV
```

The reference bundle (`REFS`) holds `star_index/`, `genes.gtf`, `genes.collapsed.gtf`
and `reference_manifest.json` (checksums of everything).

## Counts made elsewhere

`pipelines/02-classify --input counts.csv` (columns `sample,counts`) accepts any file
of `ENSG id <tab> count` (HTSeq format; version suffixes, a header line and `__`
counter rows are ignored). The run fails if fewer than 15,000 of MD-ALL's 19,985
reference genes are present. Counts not produced with step 1's method (for example
Salmon/DRAGEN) will run but are **not** equivalent to MD-ALL's reference and should not
be pooled with step 1 results without a validation.

## The results website

Pages (look and feel of ball-classifier-web, MD-ALL's subtype palette throughout):

* **Samples** (`/`): every sample from every center with MD-ALL call, agreement,
  PhenoGraph and SVM; filter, search, sort; links to gene search and UMAP; TSV export.
* **Cohort statistics** (`/stats.html`): totals, samples by center, subtype
  distribution, calls by center, subtype mix by center, subtype × center counts (TSV).
* **Sample page** (`/sample.html`): the call, predictions per feature-set size, marker
  genes, alignment and counting QC with the coverage curve, provenance, downloads.
* **Gene search** (`/gene-search.html`): any gene against the 1,821 reference samples by
  subtype, with per-subtype and overall percentiles.
* **UMAP** (`/umap.html`): the sample highlighted on the fixed reference embedding,
  optionally with every COG sample; click a sample to highlight it.

The site only reads the results folder and rescans it every minute (`RESCAN_SECONDS`).
Environment: `PORT` (3000), `RESULTS_ROOT` (`/data/results`), `APP_PASSWORD` /
`APP_USER` (login), `RESCAN_SECONDS`.

`test/test_web.sh <results folder> [--sif cog-ball-web_<version>.sif | --image NAME]`
starts the image with a login password and checks every page and API, including
path-traversal attempts.

## Validation

* **Classifier:** `test/expected_mdall.tsv` holds the calls upstream MD-ALL's own
  functions give for the seven count files bundled with MD-ALL
  (`test/make_expected_vanilla.R`). Step 2 must reproduce them exactly:
  `test/fetch_test_data.sh`, then
  `nextflow run pipelines/02-classify -profile test,singularity`, then
  `test/check_classify.py results-test/TEST test/expected_mdall.tsv`. The folder names in
  MD-ALL's test set (`Ph/`, `Phlike/` …) do not always match MD-ALL's own expression call;
  the check compares against what MD-ALL computes.
* **End to end:** the `test1` FASTQs (5 M read pairs) give
  `iAMP21 (concordant)  PhenoGraph 0.73 | SVM 0.91` with both routes.
* Run both after every image rebuild and on every new site.

## Building and distributing the images

Images are built once, by COG, and shared, so every center runs byte-identical
containers. On a machine with Docker:

```bash
PLATFORM=linux/amd64 containers/build_images.sh        # cog-ball/{counts,mdall,web}:<VERSION>
containers/export_images.sh /tmp/cog-ball-images       # tarballs + SHA256SUMS, tagged cog-ball/<name>:<VERSION>
```

Releases are published on Docker Hub as `vyellapa/cog-ball-<name>:<VERSION>`, one tag per
image that serves amd64 (all three) and arm64 (mdall, web; RNA-SeQC is linux-64 only, so
counts is amd64-only). After building both architectures (the native Mac build is arm64):

```bash
V=$(cat VERSION)
for n in counts mdall web; do
  docker tag cog-ball-amd64/$n:$V vyellapa/cog-ball-$n:$V-amd64 && docker push vyellapa/cog-ball-$n:$V-amd64
  # mdall, web: also tag + push the arm64 build as :$V-arm64, and list it below
  docker buildx imagetools create -t vyellapa/cog-ball-$n:$V vyellapa/cog-ball-$n:$V-amd64 [vyellapa/cog-ball-$n:$V-arm64]
done
git tag v$V && git push origin v$V
```

On a server: `containers/make_sif.sh --pull <sif dir>` (from Docker Hub), or
`containers/make_sif.sh <archives> <sif dir>` offline; Docker users `docker pull` and tag
as `cog-ball/<name>:<VERSION>` (README step 2.2). A different registry:
`IMAGE_PREFIX=ghcr.io/<org>/cog-ball- containers/make_sif.sh --pull ...`.

On networks that inspect TLS (e.g. Cisco Umbrella), pass the proxy's root certificate
when building: `EXTRA_CA_CERT=/path/root.pem containers/build_images.sh`. It is used only
while downloading packages and is not stored in the images.

## Publishing the reference bundle

COG publishes one reference bundle per pipeline version so every center downloads
byte-identical files (`bin/cog-ball-reference.sh --download`). The main copy is a
**restricted Zenodo record** (free, permanent, citable DOI, reachable from networks that
filter Hugging Face).

```bash
# once: Zenodo token with deposit:write + deposit:actions, saved without echoing it
read -s T && printf '%s' "$T" > ~/.zenodo_token && chmod 600 ~/.zenodo_token && unset T

bin/publish_reference_zenodo.sh --refs /data/cog-ball/refs --dry-run   # what will be uploaded
bin/publish_reference_zenodo.sh --refs /data/cog-ball/refs             # upload to a draft
```

The script checksums the bundle (run logs excluded: they contain local paths), writes
`SHA256SUMS`, a README and a licence note, creates a **draft** record, uploads every file
(flat names: `star_index/SA` → `star_index__SA`), checks Zenodo's MD5 of each upload
against the local file, and fills in the metadata (restricted access). Re-running it
continues the same draft and skips files already uploaded. It never publishes:

1. Open the draft link it prints, check title, creators and description, click **Publish**.
   Publishing is permanent; later changes become a new version of the record.
2. On the published record: **Share → Links → create a View link**, and send the record
   number and the link's token to the centers (or approve access requests one by one).
3. Put `ZENODO_RECORD=<number>` in `site.conf.example` so every site picks it up.

Upload from the machine with the fastest route to Zenodo (usually the Linux server, not a
laptop behind a web filter: 29 GB at ~100 kB/s is three days). A draft started elsewhere
is continued with `--deposition <draft id>`; already-uploaded files are skipped.

`--sandbox` runs the same procedure against sandbox.zenodo.org to try it out.

Alternative: a gated Hugging Face dataset (`bin/publish_reference.sh --repo ORG/NAME`;
sites use `--hf-repo`). Some institutional web filters (e.g. Cisco Umbrella) block
Hugging Face uploads, so run that from a server.

## Versioning

Bump `VERSION` whenever anything that can change a result changes: a tool version, a
pipeline parameter, the MD-ALL commit, or a wrapper script. Rebuild and redistribute all
three images. The version is recorded in every result and shown on the website.

## Repository layout

```
VERSION                         one version for all images and pipelines
site.conf.example               per-site settings (copy to site.conf)
centers.tsv                     registered center codes
containers/counts/              STAR + samtools + HTSeq + DUX4 patch + RNA-SeQC + QC scripts
containers/mdall/               R + MD-ALL + mdall_classify.R + reference assets
containers/*.sh                 build, export and convert images
pipelines/conf/common.config    containers, Singularity/Apptainer/Docker, Slurm, site.conf
pipelines/00-reference/         reference bundle
pipelines/01-counts/            FASTQ → counts + QC
pipelines/02-classify/          counts → MD-ALL
bin/cog-ball-reference.sh       reference bundle without Nextflow
bin/cog-ball-run.sh             one sample FASTQ → MD-ALL without Nextflow
bin/sync_results.sh             center → shared space
web/                            results website
test/                           regression data and checks
```

## Credits

MD-ALL: Hu Z. et al., *Haematologica* 2024;109(6):1741–1754 (gu-lab20/MD-ALL).
STAR/HTSeq parameters and the DUX4 patch script come from the gu-lab RNA-seq pipeline and
the MD-ALL repository. RNA-SeQC 2 (getzlab) and the GTEx `collapse_annotation.py`
(Broad Institute, BSD-3). Research use only.
