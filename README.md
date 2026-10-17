# COG B-ALL subtype classification with MD-ALL

One shared pipeline for the COG working group: every center runs the same containers,
with the same tool versions and reference, from FASTQ to an MD-ALL gene-expression
subtype call. Each center's results are synced to one shared space and viewed in a
single website.

```
FASTQ ──► counts (STAR → HTSeq → DUX4 patch, + RNA-SeQC QC) ──► MD-ALL call ──► sync ──► website
```

There are two ways to run it. Both use the same containers, run the same commands and
write the same files, so their results can be mixed freely:

| | **A. Nextflow** | **B. Standalone server (bash scripts)** |
|---|---|---|
| Needs | Nextflow + Java, Singularity/Apptainer | bash + Singularity/Apptainer only |
| Good for | many samples, Slurm clusters, automatic resume | a few samples, servers without Nextflow |
| Reference (once) | `nextflow run pipelines/00-reference` | `bin/cog-ball-reference.sh` |
| Per batch / sample | `pipelines/01-counts` then `pipelines/02-classify` | `bin/cog-ball-run.sh` |

How the pipeline works, what each output file contains, and how it was validated:
[docs/DETAILS.md](docs/DETAILS.md).

---

## Contents

1. [Requirements](#1-requirements)
2. [One-time setup](#2-one-time-setup) (both routes)
3. [Route A — run with Nextflow](#3-route-a--run-with-nextflow)
4. [Route B — run on a standalone server](#4-route-b--run-on-a-standalone-server)
5. [Check the install with known answers](#5-check-the-install-with-known-answers)
6. [Send results to the shared space](#6-send-results-to-the-shared-space)
7. [The results website](#7-the-results-website)
8. [Troubleshooting](#8-troubleshooting)

---

## 1. Requirements

* Linux x86-64 (Intel or AMD) server or cluster node
* Singularity ≥ 3.8 or Apptainer ≥ 1.1 (Docker also works)
* About **40 GB RAM** and 8 cores per sample (STAR alignment)
* About **50 GB** disk for the reference bundle and images, plus space for results
* Internet access once, to download the genome (0.9 GB) when building the reference
* Route A only: Nextflow ≥ 24.10 with Java 17+ (tested with 25.10.8)

You receive two folders from COG:

* `cog-ball-mdall/` — this repository (code and settings)
* `cog-ball-images-<version>/` — the three container images and their `SHA256SUMS`

---

## 2. One-time setup

Replace `/data/cog-ball` with a folder on your server.

**2.1 Copy the files to the server** (from your workstation):

```bash
rsync -av --exclude web/node_modules --exclude test/data \
      cog-ball-mdall cog-ball-images-0.1.0  you@server:/data/cog-ball/
```

**2.2 Convert the images to Singularity/Apptainer format** (on the server, a few minutes):

```bash
cd /data/cog-ball/cog-ball-mdall
module load apptainer 2>/dev/null || module load singularity 2>/dev/null || true
export APPTAINER_TMPDIR=/data/cog-ball/tmp SINGULARITY_TMPDIR=/data/cog-ball/tmp   # needs ~10 GB
mkdir -p $APPTAINER_TMPDIR
containers/make_sif.sh ../cog-ball-images-0.1.0 /data/cog-ball/sif
```

The script verifies the archives' checksums and writes
`cog-ball-{counts,mdall,web}_0.1.0.sif`.

**2.3 Fill in your site settings** — once per site, so the center and paths never have
to be typed again:

```bash
cp site.conf.example site.conf
nano site.conf
```

```ini
CENTER=CHOP                          # your center code (table below)
REFS=/data/cog-ball/refs             # where the reference bundle is built
SIF_DIR=/data/cog-ball/sif           # the .sif images from step 2.2
OUTDIR=/data/cog-ball/results        # results go to OUTDIR/CENTER/<sample>/
THREADS=8                            # CPU threads per sample
HUB=user@hub:/srv/cog-ball/results   # shared space for syncing (optional)
```

| Code | Center |
|---|---|
| `CHOP` | Children's Hospital of Philadelphia |
| `NCH` | Nationwide Children's Hospital |
| `CHLA` | Children's Hospital Los Angeles |

Only codes listed in `centers.tsv` are accepted (`TEST` is reserved for test runs); COG
adds new centers there. Both routes read `site.conf` automatically; any command-line
option overrides it.

**2.4 Get the reference bundle** — once per site. Download the ready-made bundle
(recommended: identical at every center, no index build) or build it yourself.

*Download (≈ 30 GB, needs only `curl`).* The bundle is a restricted Zenodo record
shared with the COG team:

1. Get the **record number** and the **access-link token** from COG (the token is the
   part after `token=` in the access link COG sends you).
2. Add both to `site.conf`:
   ```ini
   ZENODO_RECORD=1234567
   ZENODO_LINK_TOKEN=eyJhbGciOi...
   ```
3. Download into `REFS`:
   ```bash
   bin/cog-ball-reference.sh --download
   ```
   This takes about 15–60 minutes. Every file is checked against the bundle's
   `SHA256SUMS`, and the folder layout is restored (Zenodo stores `star_index/SA` as
   `star_index__SA`). If it stops, run the same command again: finished files are kept
   and partial ones resume.

Without `site.conf`: `bin/cog-ball-reference.sh --download --outdir /data/cog-ball/refs
--zenodo 1234567 --zenodo-link-token <token>`. If COG granted you access personally
instead of sending a link, create a Zenodo token (Settings → Applications) and
`export ZENODO_TOKEN=<token>` instead of the link token.

*Or build it here* (about 1 hour and 40 GB RAM; run on a compute node):

```bash
nextflow run pipelines/00-reference -profile singularity    # Route A
bin/cog-ball-reference.sh                                    # Route B
```

Building downloads GRCh38 and Ensembl 102, checks their SHA-256 checksums and writes
`star_index/`, `genes.gtf`, `genes.collapsed.gtf` and `reference_manifest.json` to
`REFS`. If compute nodes have no internet, download the two files on a login node and
pass them in (`--genome FILE --gtf FILE` for the script; `--genome_url FILE --gtf_url FILE`
for Nextflow); checksums are still checked.

---

## 3. Route A — run with Nextflow

**Install Nextflow** (once, in your home folder):

```bash
curl -s https://get.nextflow.io | bash && mv nextflow ~/bin/
export NXF_VER=25.10.8          # pin the tested version (add to ~/.bashrc)
nextflow -version
```

**Make a samplesheet** (`samplesheet.csv`). One row per lane; repeat the sample id for
multi-lane samples; leave `fastq_2` empty for single-end:

```csv
sample,fastq_1,fastq_2
SAMPLE_0001,/data/fastq/SAMPLE_0001_L001_R1.fastq.gz,/data/fastq/SAMPLE_0001_L001_R2.fastq.gz
SAMPLE_0001,/data/fastq/SAMPLE_0001_L002_R1.fastq.gz,/data/fastq/SAMPLE_0001_L002_R2.fastq.gz
SAMPLE_0002,/data/fastq/SAMPLE_0002_R1.fastq.gz,/data/fastq/SAMPLE_0002_R2.fastq.gz
```

Sample ids may contain only letters, digits, `.`, `_` and `-`. **Use de-identified
ids** — they are shown on the shared website.

**Run the two steps:**

```bash
cd /data/cog-ball/cog-ball-mdall

# FASTQ -> counts + QC   (add ,slurm to submit each task to Slurm)
nextflow run pipelines/01-counts   -profile singularity,slurm --input samplesheet.csv

# counts -> MD-ALL call  (picks up everything 01-counts wrote for your center)
nextflow run pipelines/02-classify -profile singularity,slurm
```

* Results go to `OUTDIR/CENTER/<sample>/`; each run's reports and a summary TSV go to
  `OUTDIR/CENTER/pipeline_info/`.
* Add `-resume` to rerun after a failure or to add samples; finished samples are reused.
* Slurm: `--slurm_queue NAME` and `--slurm_options "--account=XYZ"` if your cluster
  needs them. Without `slurm`, tasks run on the current machine.
* Docker instead of Singularity: `-profile docker` (load the archives with
  `docker load -i` first).

| Useful options | |
|---|---|
| `--save_bam` | keep the sorted BAM in `<sample>/bam/` |
| `--save_chimeric` | keep STAR's chimeric junctions (for later fusion calling) |
| `--max_cpus 16 --max_memory 64.GB` | cap resources per task |
| `--center`, `--outdir`, `--refs`, `--sif_dir` | override `site.conf` |

---

## 4. Route B — run on a standalone server

No Nextflow needed. One command takes one sample from FASTQ to the MD-ALL call:

```bash
cd /data/cog-ball/cog-ball-mdall
bin/cog-ball-run.sh --sample SAMPLE_0001 \
  --r1 /data/fastq/SAMPLE_0001_R1.fastq.gz --r2 /data/fastq/SAMPLE_0001_R2.fastq.gz
```

It aligns, counts, runs QC and MD-ALL, then prints the call, for example:

```
== SAMPLE_0001: MD-ALL call iAMP21 (concordant)  PhenoGraph iAMP21 0.73 | SVM iAMP21 0.91
   results: /data/cog-ball/results/CHOP/SAMPLE_0001
```

* **Several lanes:** comma-separated, in the same order for R1 and R2:
  `--r1 L001_R1.fq.gz,L002_R1.fq.gz --r2 L001_R2.fq.gz,L002_R2.fq.gz`
* **Single-end:** leave out `--r2`.
* **Re-running** a sample reuses its counts only if they were made from exactly the same
  FASTQs, reference and image; otherwise it counts again. `--force` always recounts.
* A log of every run is written to `OUTDIR/CENTER/pipeline_info/`.

**Several samples** — a CSV with one row per sample (`sample,fastq_1,fastq_2`). For
multi-lane samples, call the script per sample with comma-separated lanes as above, or
use Route A.

```bash
tail -n +2 samples.csv | while IFS=, read -r s r1 r2; do
  bin/cog-ball-run.sh --sample "$s" --r1 "$r1" --r2 "$r2"
done
```

**On Slurm**, one job per sample:

```bash
tail -n +2 samples.csv | while IFS=, read -r s r1 r2; do
  sbatch --job-name="cog_$s" --cpus-per-task=8 --mem=40G --time=6:00:00 \
    --wrap="$PWD/bin/cog-ball-run.sh --sample $s --r1 $r1 --r2 $r2"
done
```

| Useful options (`bin/cog-ball-run.sh --help` lists all) | |
|---|---|
| `--keep-bam` | keep the sorted BAM in `<sample>/bam/` |
| `--work DIR` | scratch folder for the BAM (default: inside the sample folder, deleted afterwards) |
| `--threads N` | override `THREADS` |
| `--docker` | use Docker images instead of `SIF_DIR` |
| `--center`, `--outdir`, `--refs`, `--sif-dir` | override `site.conf` |

---

## 5. Check the install with known answers

Do this once on every new site, and after every image update, before running patient
samples.

**End to end (either route)** — the `test1` FASTQs from COG must give this call:

```bash
bin/cog-ball-run.sh --sample TEST_01 --center TEST \
  --r1 /data/cog-ball/test1_R1.fastq.gz --r2 /data/cog-ball/test1_R2.fastq.gz
# expected:  MD-ALL call iAMP21 (concordant)  PhenoGraph iAMP21 0.73 | SVM iAMP21 0.91
```

**Classifier against upstream MD-ALL (Route A)** — seven count files bundled with
MD-ALL must give exactly MD-ALL's own calls:

```bash
test/fetch_test_data.sh
nextflow run pipelines/02-classify -profile test,singularity
test/check_classify.py results-test/TEST test/expected_mdall.tsv      # "All samples match upstream MD-ALL."
```

`--center TEST` keeps test runs out of your center's results.

---

## 6. Send results to the shared space

With `HUB` set in `site.conf`:

```bash
bin/sync_results.sh --dry-run      # preview
bin/sync_results.sh                # copy
```

* The hub copy of your center **mirrors** your `OUTDIR/CENTER` folder: new and changed
  results are copied, and results you delete locally are removed from the hub. To
  withdraw or correct a sample, delete or re-run it locally, then sync.
* Only result, QC and provenance files are sent — never BAMs or FASTQs.
* The script refuses to run on an empty source folder, so a wrong path cannot wipe your
  center's hub folder.
* Without `HUB`: `bin/sync_results.sh OUTDIR/CENTER /path/on/hub/CENTER`.

Run it after each batch, or from cron. The website shows changes within a minute.

---

## 7. The results website

Run on the server that holds the shared space (one site for all centers):

```bash
APPTAINERENV_APP_PASSWORD='choose-a-password' \
apptainer run --cleanenv --bind /srv/cog-ball/results:/data/results:ro \
  /data/cog-ball/sif/cog-ball-web_0.1.0.sif
```

* It listens on port 3000 (`APPTAINERENV_PORT=3010` to change it). Viewers sign in
  with user `admin` and the password. Put it behind your institution's HTTPS proxy or
  sign-on for wider access.
* To look at it from your laptop: `ssh -L 3000:localhost:3000 you@server`, then open
  <http://localhost:3000>.
* Docker hosts: `RESULTS_ROOT=/srv/cog-ball/results APP_PASSWORD=... docker compose -f web/docker-compose.yml up -d`
* Check it: `test/test_web.sh /srv/cog-ball/results --sif /data/cog-ball/sif/cog-ball-web_0.1.0.sif`

Pages: all samples (filter, search, export), cohort statistics, and per sample the
MD-ALL call, QC (STAR, RNA-SeQC, gene-body coverage), gene search against the reference
cohort, and the sample on the reference UMAP.

---

## 8. Troubleshooting

| Message | What to do |
|---|---|
| `center 'X' is not registered in centers.tsv` | Set `CENTER` in `site.conf` to your code (`CHOP`, `NCH`, `CHLA`). |
| `no center given` / `no reference bundle` / `no images` | Fill in `site.conf` (step 2.3) or pass the option on the command line. |
| `reference bundle lacks genes.collapsed.gtf` | Bundle from an older version: `bin/cog-ball-reference.sh --upgrade` (about 30 s, no re-index). |
| `cannot download SHA256SUMS` | Check `ZENODO_RECORD` and `ZENODO_LINK_TOKEN` in `site.conf` (ask COG for a fresh access link), or request access on the record page. |
| `checksum mismatch` when downloading | Interrupted or corrupted transfer: run `bin/cog-ball-reference.sh --download` again. |
| STAR killed / exit 137 | Not enough memory: request 40 GB per sample (`--mem=40G` on Slurm). |
| `make_sif.sh` fails with "no space left" | Point `APPTAINER_TMPDIR`/`SINGULARITY_TMPDIR` at a larger folder. |
| Port 3000 already in use | Start the website with `APPTAINERENV_PORT=3010`. |
| Anything else | Send the run log from `OUTDIR/CENTER/pipeline_info/` to the contact below. |

---

Questions or feature requests: Venkata Yellapantula (y.venkatad@gmail.com).
Technical details: [docs/DETAILS.md](docs/DETAILS.md). Research use only.
