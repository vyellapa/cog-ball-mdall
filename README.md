# COG B-ALL subtype classification with MD-ALL

This pipeline takes RNA-seq FASTQ files from a B-ALL sample and gives its gene-expression
subtype call from [MD-ALL](https://github.com/gu-lab20/MD-ALL) (for example *iAMP21*,
*Ph*, *DUX4*). Every COG center runs the same containers with the same reference, so
results from all centers can be compared directly and viewed on one shared website.

```
FASTQ ──► align and count (STAR, HTSeq, RNA-SeQC QC) ──► MD-ALL call ──► shared website
```

**Who this guide is for:** anyone who can log in to a Linux server and paste commands
into a terminal. Every step shows the commands to paste and what you should see.
Technical background (methods, validation, file formats) is in
[docs/DETAILS.md](docs/DETAILS.md).

---

## The steps at a glance

| Step | What you do | Time | How often |
|---|---|---|---|
| [1](#step-1--check-your-server) | Check your server has what it needs | 5 min | once |
| [2](#step-2--make-a-work-folder-and-get-the-code) | Make a work folder and get the code | 5 min | once |
| [3](#step-3--get-the-containers) | Get the containers (the software) | 15–30 min | once |
| [4](#step-4--fill-in-your-site-settings) | Fill in your site settings | 5 min | once |
| [5](#step-5--get-the-reference-genome-files) | Get the reference genome files | 1–2 hours | once |
| [6](#step-6--test-with-a-sample-of-known-subtype) | Test with a sample of known subtype | 20–40 min | once, and after updates |
| [7](#step-7--run-your-samples) | Run your samples | about 1 hour per sample | every batch |
| [8](#step-8--look-at-the-results) | Look at the results | 1 min | every batch |
| [9](#step-9--send-results-to-the-shared-website) | Send results to the shared website | 1 min | every batch |

Also: [Words used in this guide](#words-used-in-this-guide) ·
[Many samples with Nextflow](#many-samples-at-once-with-nextflow-optional) ·
[Running the website](#running-the-results-website-hub-administrators-only) ·
[Troubleshooting](#troubleshooting) · [Getting help](#getting-help)

### How to read the commands

* Paste the commands into a terminal **on your server**, not on your laptop.
* Lines starting with `#` are comments that explain the command; they do nothing.
* Wherever you see `CHOP`, use your own center code (`CHOP`, `NCH` or `CHLA`).
* If a command prints a line starting with `ERROR`, stop and look it up under
  [Troubleshooting](#troubleshooting).

---

## Step 1 — Check your server

You need a Linux server or cluster with:

* an Intel or AMD processor (not ARM)
* **40 GB of memory** and **8 CPU cores** for each sample you run at the same time
* **100 GB of free disk** for the setup (50 GB stays in use afterwards, plus about
  50 MB of results per sample)
* **Apptainer** or **Singularity**, the free programs that run the containers
* internet access during setup

Paste these checks:

```bash
uname -m                                       # should print: x86_64
nproc                                          # number of CPU cores: 8 or more
free -g | head -2                              # "total" under Mem: 40 or more (GB)
apptainer --version || singularity --version   # any version number is fine
```

If the last line says `command not found`, your server may provide Apptainer as a
*module*. Try:

```bash
module load apptainer || module load singularity
apptainer --version || singularity --version
```

If that works, you'll need to run the same `module load` line each time you log in
(or add it to the end of your `~/.bashrc` file). If neither works, ask your IT or
research-computing team to install Apptainer: it is free and commonly installed.

> **On a cluster with Slurm** (you submit jobs with `sbatch`), the memory check above
> is about the login node and doesn't matter: memory is requested per job, and this
> guide shows the `sbatch` commands.

---

## Step 2 — Make a work folder and get the code

**2a. Choose a folder with at least 100 GB free.** Ask your IT team if you're unsure
which disk to use: home folders are often too small. Go there and make the work folder:

```bash
cd /path/to/a/big/disk                  # ← type your own path here
mkdir -p cog-ball && cd cog-ball
echo "export COG=$PWD" >> ~/.bashrc     # remember this folder as $COG, also in future logins
source ~/.bashrc
echo $COG                               # prints the full path of your work folder
df -h $COG                              # "Avail" should be 100G or more
```

From now on, `$COG` means this folder in every command.

**2b. Get the code.** The repository is private: first email Venkata Yellapantula
(y.venkatad@gmail.com) your GitHub username and wait for the invitation email from
GitHub, then accept it. Then:

```bash
cd $COG
git clone https://github.com/vyellapa/cog-ball-mdall.git
cd cog-ball-mdall
git checkout v0.1.0                     # the version every center runs
```

* When git asks for a **Username**, type your GitHub username. When it asks for a
  **Password**, paste a GitHub *personal access token*, not your GitHub password
  (GitHub no longer accepts passwords here). To make a token: on github.com click your
  picture → **Settings** → **Developer settings** → **Personal access tokens** →
  **Tokens (classic)** → **Generate new token (classic)**, tick **repo**, then
  **Generate**, and copy the token.
* `git checkout v0.1.0` prints a note about a *detached HEAD*. That is normal.
* **No git on the server?** On the GitHub page, open the branch menu (it says
  **main**), choose **Tags** → **v0.1.0**, then click **Code** → **Download ZIP**. Copy
  the ZIP to `$COG` on the server and run
  `cd $COG && unzip cog-ball-mdall-*.zip && mv cog-ball-mdall-*/ cog-ball-mdall`.

---

## Step 3 — Get the containers

The containers hold all the software (STAR, HTSeq, RNA-SeQC, R and MD-ALL) with fixed
versions. This downloads them and converts them to Apptainer format:

```bash
cd $COG/cog-ball-mdall
mkdir -p $COG/tmp
export APPTAINER_TMPDIR=$COG/tmp SINGULARITY_TMPDIR=$COG/tmp
containers/make_sif.sh --pull $COG/sif
```

This takes 15–30 minutes. When it finishes, it lists three files:

```
cog-ball-counts_0.1.0.sif
cog-ball-mdall_0.1.0.sif
cog-ball-web_0.1.0.sif
```

You can then delete the temporary folder: `rm -rf $COG/tmp`.

---

## Step 4 — Fill in your site settings

The settings file `site.conf` tells every script your center and where your files are,
so you never have to type them again. Paste this block as it is; it fills in your
folders automatically:

```bash
cd $COG/cog-ball-mdall
cat > site.conf <<EOF
CENTER=CHOP
REFS=$COG/refs
SIF_DIR=$COG/sif
OUTDIR=$COG/results
THREADS=8
HUB=
EOF
```

Then open the file to set **your center code**:

```bash
nano site.conf
```

Change `CHOP` on the first line to your code from this table. To save, press
**Ctrl-O** then **Enter**; to exit, press **Ctrl-X**.

| Code | Center |
|---|---|
| `CHOP` | Children's Hospital of Philadelphia |
| `NCH` | Nationwide Children's Hospital |
| `CHLA` | Children's Hospital Los Angeles |

What the settings mean:

| Setting | Meaning |
|---|---|
| `CENTER` | your center code; results are stored and shown on the website under it |
| `REFS` | where the reference genome files go (Step 5) |
| `SIF_DIR` | where the containers are (Step 3) |
| `OUTDIR` | where results go: `OUTDIR/CENTER/<sample>/` |
| `THREADS` | CPU cores per sample (8 is right for most servers; up to 16 helps a little) |
| `HUB` | the shared results folder for Step 9; leave empty until COG gives you one |

Check the file with `cat site.conf`.

---

## Step 5 — Get the reference genome files

Every center must use identical reference files: the human genome (GRCh38), the gene
annotation (Ensembl 102) and the STAR index built from them. This is done once and
needs about 1–2 hours, 40 GB of memory and 70 GB of free disk while it runs.

**If COG has sent you a Zenodo download link**, skip to [Option B](#option-b-download-the-ready-made-files).
Otherwise use Option A.

### Option A: build the files on your server

The script downloads the genome and annotation from NCBI and Ensembl, checks their
checksums and builds the STAR index. Pick the command that matches your server.

**Your own server** (no Slurm): `nohup` keeps the build running if you log out.

```bash
cd $COG/cog-ball-mdall
nohup bin/cog-ball-reference.sh > $COG/reference.log 2>&1 &
tail -f $COG/reference.log      # watch progress; Ctrl-C stops watching, not the build
```

**A Slurm cluster:**

```bash
cd $COG/cog-ball-mdall
sbatch --job-name=cog_ref --cpus-per-task=8 --mem=48G --time=6:00:00 \
       --output=$COG/reference.log --wrap="$PWD/bin/cog-ball-reference.sh"
squeue -u $USER                 # your job is listed while it runs
tail -f $COG/reference.log      # watch progress; Ctrl-C stops watching
```

It's finished when the log's last line is:

```
== reference bundle ready: /…/cog-ball/refs  (use --refs /…/cog-ball/refs)
```

> **Cluster nodes without internet?** Download the two input files on the login node
> first and pass them to the script (it still checks them):
> ```bash
> cd $COG
> wget https://ftp.ncbi.nlm.nih.gov/genomes/all/GCA/000/001/405/GCA_000001405.15_GRCh38/seqs_for_alignment_pipelines.ucsc_ids/GCA_000001405.15_GRCh38_no_alt_plus_hs38d1_analysis_set.fna.gz
> wget https://ftp.ensembl.org/pub/release-102/gtf/homo_sapiens/Homo_sapiens.GRCh38.102.gtf.gz
> ```
> Then add `--genome $COG/GCA_000001405.15_GRCh38_no_alt_plus_hs38d1_analysis_set.fna.gz
> --gtf $COG/Homo_sapiens.GRCh38.102.gtf.gz` after `bin/cog-ball-reference.sh` in the
> command above (inside the quotes for `sbatch`).

### Option B: download the ready-made files

COG gives you a **record number** and an **access token** (the part after `token=` in
the link). Add them to `site.conf` with `nano site.conf`:

```ini
ZENODO_RECORD=1234567
ZENODO_LINK_TOKEN=paste-the-token-here
```

Then download (about 30 GB; needs only an internet connection, not 40 GB of memory):

```bash
cd $COG/cog-ball-mdall
nohup bin/cog-ball-reference.sh --download > $COG/reference.log 2>&1 &
tail -f $COG/reference.log
```

It's finished when the log says `== reference bundle ready and verified`. Every file
is checked against the published checksums. If the download stops, run the same
command again: finished files are kept and the rest continue.

---

## Step 6 — Test with a sample of known subtype

Before running patient samples, check that your installation gives the expected answer.
COG sends you two test files, `test1_R1.fastq.gz` and `test1_R2.fastq.gz`. Copy them to
`$COG/test/`, then run:

**Your own server:**

```bash
cd $COG/cog-ball-mdall
bin/cog-ball-run.sh --sample TEST_01 --center TEST \
  --r1 $COG/test/test1_R1.fastq.gz --r2 $COG/test/test1_R2.fastq.gz
```

**A Slurm cluster:**

```bash
cd $COG/cog-ball-mdall
sbatch --job-name=cog_test --cpus-per-task=8 --mem=40G --time=4:00:00 \
       --output=$COG/test.log \
       --wrap="$PWD/bin/cog-ball-run.sh --sample TEST_01 --center TEST --r1 $COG/test/test1_R1.fastq.gz --r2 $COG/test/test1_R2.fastq.gz"
tail -f $COG/test.log
```

It prints its progress (`[1/3] STAR alignment`, `[2/3] htseq-count …`,
`[3/3] MD-ALL …`) and ends with:

```
== TEST_01: MD-ALL call iAMP21 (concordant)  PhenoGraph iAMP21 0.73 | SVM iAMP21 0.91
```

If you see exactly this call and these scores, your installation is correct. If not,
don't run patient samples yet; send the log (see [Getting help](#getting-help)).

`--center TEST` keeps the test out of your center's results. You can delete it
afterwards with `rm -rf $COG/results/TEST`.

---

## Step 7 — Run your samples

**Before you start:**

* Find your FASTQ files, for example with `ls /path/to/fastq/`. Paired-end RNA-seq has
  two files per sample, usually named `…_R1….fastq.gz` and `…_R2….fastq.gz`.
* Pick a **de-identified sample id** for each sample (no names, MRNs or dates of
  birth): it is shown on the shared website. Use only letters, digits, `.`, `_` and `-`,
  for example `CHOP_0001`.

### One sample

```bash
cd $COG/cog-ball-mdall
bin/cog-ball-run.sh --sample CHOP_0001 \
  --r1 /path/to/fastq/CHOP_0001_R1.fastq.gz \
  --r2 /path/to/fastq/CHOP_0001_R2.fastq.gz
```

On a Slurm cluster, wrap the same command in `sbatch` as in Step 6
(`--cpus-per-task=8 --mem=40G --time=6:00:00`).

* **Sequenced on several lanes** (several R1 and R2 files)? List them separated by
  commas, without spaces, in the same order for R1 and R2:
  `--r1 L001_R1.fastq.gz,L002_R1.fastq.gz --r2 L001_R2.fastq.gz,L002_R2.fastq.gz`
* **Single-end** (only R1 files)? Leave out `--r2`.
* **Ran it again by mistake?** The script notices when a sample's counts already
  exist for the exact same FASTQ files and skips the slow alignment.
  If you add `--keep-bam` and the BAM or its index is missing, it repeats alignment
  and counting to retain them. A rerun clears the previous classification; a failed
  run will not leave the old call displayed as current.

### Several samples

**1. Make a list.** Create a file `samples.csv`: one line per sample, a header line
first, and full paths to the FASTQ files:

```bash
nano $COG/samples.csv
```

```csv
sample,fastq_1,fastq_2
CHOP_0001,/path/to/fastq/CHOP_0001_R1.fastq.gz,/path/to/fastq/CHOP_0001_R2.fastq.gz
CHOP_0002,/path/to/fastq/CHOP_0002_R1.fastq.gz,/path/to/fastq/CHOP_0002_R2.fastq.gz
```

Save with **Ctrl-O**, **Enter**, then exit with **Ctrl-X**. If you made the list in
Excel, save it as *CSV (comma delimited)* and copy it to the server.

**2. Run every sample in the list.**

*Your own server* (one sample after another, in the background):

```bash
cd $COG/cog-ball-mdall
nohup bash -c 'tail -n +2 $COG/samples.csv | tr -d "\r" | while IFS=, read -r s r1 r2; do
  bin/cog-ball-run.sh --sample "$s" --r1 "$r1" --r2 "$r2" < /dev/null
done' > $COG/batch.log 2>&1 &
tail -f $COG/batch.log
```

*A Slurm cluster* (one job per sample, all running at the same time):

```bash
cd $COG/cog-ball-mdall
mkdir -p $COG/logs
tail -n +2 $COG/samples.csv | tr -d '\r' | while IFS=, read -r s r1 r2; do
  sbatch --job-name="cog_$s" --cpus-per-task=8 --mem=40G --time=6:00:00 \
    --output="$COG/logs/$s.log" \
    --wrap="$PWD/bin/cog-ball-run.sh --sample $s --r1 $r1 --r2 $r2" < /dev/null
done
squeue -u $USER                 # your jobs, while they run
```

Samples sequenced on several lanes don't fit this list: run them one at a time as
shown above, or use [Nextflow](#many-samples-at-once-with-nextflow-optional).

---

## Step 8 — Look at the results

See every finished sample's call in one table:

```bash
cd $COG/cog-ball-mdall
bin/cog-ball-summary.sh
```

```
sample     MD-ALL call   agreement   PhenoGraph  score  SVM     score
CHOP_0001  iAMP21        concordant  iAMP21      0.73   iAMP21  0.91
CHOP_0002  needs review  discordant  Ph          0.64   KMT2A   0.55
```

To open it in Excel: `bin/cog-ball-summary.sh --tsv > $COG/calls.tsv`, then copy
`calls.tsv` to your computer.

**How to read the call.** MD-ALL runs two methods, PhenoGraph and SVM, each 11 times
with different gene sets. The score is the fraction of runs that gave that subtype
(0.91 = 10 of 11).

* **concordant**: both methods agree. This is the sample's expression subtype.
* **needs review**: the methods disagree. MD-ALL does not assign a subtype
  automatically in this case; review it together with fusion and karyotype results.
* **Ph** includes both Ph-positive (BCR::ABL1) and Ph-like cases; expression alone
  cannot tell them apart.

Each sample's folder, `$COG/results/<CENTER>/<sample>/`, also holds the alignment and
QC numbers and the gene counts. [docs/DETAILS.md](docs/DETAILS.md#results-layout)
lists every file. The BAM file is deleted after counting, unless you add `--keep-bam`.

---

## Step 9 — Send results to the shared website

COG gives you the address of the shared results folder (the *hub*). Put it in
`site.conf` once, with `nano site.conf`, for example:

```ini
HUB=yourname@hub.example.org:/srv/cog-ball/results
```

Then, after each batch:

```bash
cd $COG/cog-ball-mdall
bin/sync_results.sh --dry-run      # shows what would be copied; changes nothing
bin/sync_results.sh                # copies
```

* Only results, QC and provenance files are sent — never FASTQ or BAM files.
* The hub keeps an exact copy of your results folder. To remove or correct a sample,
  delete it (`rm -rf $COG/results/<CENTER>/<sample>`) or run it again, then sync.
  After deleting your center's last sample, preview with
  `bin/sync_results.sh --allow-empty --dry-run`, then run
  `bin/sync_results.sh --allow-empty` to remove its results from the hub.
* The website shows the changes within a minute.

---

## Words used in this guide

| Word | Meaning |
|---|---|
| **FASTQ** | the raw sequencing reads, files ending in `.fastq.gz` |
| **container** | a package holding a program and everything it needs, so it runs identically everywhere |
| **Apptainer / Singularity** | the program that runs containers on research servers (Apptainer is the newer name) |
| **reference** | the human genome and gene annotation the reads are matched against |
| **STAR index** | a pre-processed version of the genome that makes alignment fast |
| **Slurm** | the job scheduler on many clusters: you submit work with `sbatch` and check it with `squeue` |
| **hub** | the shared server where all centers' results are collected for the website |

---

## Many samples at once with Nextflow (optional)

Nextflow is an alternative to Step 7 for large batches: it runs samples in parallel,
submits Slurm jobs for you and resumes after failures. It uses the same containers and
gives the same results. Steps 1–6 are the same.

```bash
# install Nextflow once (needs Java 17 or newer: java -version)
curl -s https://get.nextflow.io | bash && mkdir -p ~/bin && mv nextflow ~/bin/
echo 'export NXF_VER=25.10.8' >> ~/.bashrc && source ~/.bashrc

cd $COG/cog-ball-mdall
# FASTQ -> counts. samples.csv as in Step 7; for several lanes repeat the sample id on
# one line per lane. Leave out ",slurm" to run on this machine.
nextflow run pipelines/01-counts   -profile singularity,slurm --input $COG/samples.csv
# counts -> MD-ALL calls for everything above
nextflow run pipelines/02-classify -profile singularity,slurm
```

* Add `-resume` to continue after a failure or to add samples; finished samples are
  reused.
* Slurm settings if your cluster needs them: `--slurm_queue NAME` and
  `--slurm_options "--account=XYZ"`.
* Keep BAM files with `--save_bam`. Run reports go to `OUTDIR/CENTER/pipeline_info/`.
* The reference can also be built with `nextflow run pipelines/00-reference -profile singularity`.

---

## Running the results website (hub administrators only)

Centers don't need this; it runs once, on the hub server that holds everyone's
results.

```bash
APPTAINERENV_APP_PASSWORD='choose-a-password' \
apptainer run --cleanenv --bind /srv/cog-ball/results:/data/results:ro \
  $COG/sif/cog-ball-web_0.1.0.sif
```

* It listens on port 3000 (`APPTAINERENV_PORT=3010` to change it). Viewers sign in with
  user `admin` and the password. Put it behind your institution's HTTPS proxy or
  sign-on for wider access.
* To view it from your laptop: `ssh -L 3000:localhost:3000 you@hub-server`, then open
  <http://localhost:3000>.
* With Docker: `RESULTS_ROOT=/srv/cog-ball/results APP_PASSWORD=... docker compose -f web/docker-compose.yml up -d`
* Check it: `test/test_web.sh /srv/cog-ball/results --sif $COG/sif/cog-ball-web_0.1.0.sif`

Pages: all samples (filter, search, export), cohort statistics, and for each sample the
MD-ALL call, QC with gene-body coverage, gene expression against the reference cohort,
and its position on the reference UMAP.

---

## Troubleshooting

| You see | What to do |
|---|---|
| `apptainer: command not found` | Run `module load apptainer` (or `singularity`) first; see [Step 1](#step-1--check-your-server). |
| git asks for a password and refuses yours | Use a personal access token, not your password ([Step 2b](#step-2--make-a-work-folder-and-get-the-code)). |
| `Repository not found` from git | You haven't been given access yet, or haven't accepted GitHub's invitation email. |
| `$COG` is empty (`echo $COG` prints nothing) | Run `source ~/.bashrc`, or repeat [Step 2a](#step-2--make-a-work-folder-and-get-the-code). |
| `center 'X' is not registered in centers.tsv` | Set `CENTER` in `site.conf` to `CHOP`, `NCH` or `CHLA`. |
| `no center given` / `no reference bundle` / `no images` | `site.conf` is missing or incomplete: redo [Step 4](#step-4--fill-in-your-site-settings). |
| `No such file or directory` for a FASTQ | Check the path with `ls`; use full paths starting with `/`. |
| `No space left on device` | The disk is full: free up space or choose a bigger disk. During Step 3, point `APPTAINER_TMPDIR` at a folder with 20 GB free. |
| STAR `Killed`, or exit code 137 | Not enough memory: each sample needs 40 GB (`--mem=40G` on Slurm). |
| Logged out and the run stopped | Start long runs with `nohup … &` or `sbatch` as shown, so they keep running. |
| `reference bundle lacks genes.collapsed.gtf` | Reference made by an older version: `bin/cog-ball-reference.sh --upgrade` (30 seconds). |
| `cannot download SHA256SUMS` | Check `ZENODO_RECORD` and `ZENODO_LINK_TOKEN` in `site.conf`, or ask COG for a new link. |
| `checksum mismatch` while downloading | The transfer was damaged: run the same download command again. |
| The test sample gives a different call | Don't run patient samples; send the log to the contact below. |
| Port 3000 already in use (website) | Start it with `APPTAINERENV_PORT=3010`. |

---

## Getting help

Questions or feature requests: Venkata Yellapantula (y.venkatad@gmail.com).

When something fails, please send:

* the command you ran and the last 30 lines it printed;
* the run log from `$COG/results/<CENTER>/pipeline_info/` (or `$COG/logs/` on Slurm);
* your `site.conf` (it holds no passwords, but remove the `ZENODO_LINK_TOKEN` value).

Research use only. Methods, validation and credits: [docs/DETAILS.md](docs/DETAILS.md).
