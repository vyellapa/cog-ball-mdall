#!/usr/bin/env bash
# Upload a reference bundle to Zenodo as a DRAFT record, so every center can download it
# with `bin/cog-ball-reference.sh --download --zenodo <record id>` instead of building it.
#
# Usage:
#   bin/publish_reference_zenodo.sh [--refs DIR] [--token-file ~/.zenodo_token]
#
# Options:
#   --refs DIR          bundle to upload [REFS from site.conf]
#   --token-file FILE   file holding a Zenodo personal token with deposit:write and
#                       deposit:actions scopes [~/.zenodo_token] (or ZENODO_TOKEN env)
#   --deposition ID     continue an existing draft, e.g. one started on another machine
#                       (default: the one this script last created, remembered in
#                       <REFS>/../.cog-ball-zenodo-draft)
#   --creator "Last, First"   record creator [Yellapantula, Venkata]
#   --sandbox           use sandbox.zenodo.org (for trying the procedure)
#   --dry-run           list what would be uploaded; contact nothing
#
# The script never publishes: publishing on Zenodo is permanent. It creates (or resumes)
# a draft, uploads every file (skipping ones already uploaded with the same checksum),
# checks Zenodo's MD5 of each upload against the local file, and fills in the metadata
# (restricted access). Review the draft in the browser, then click Publish.
# Zenodo has no folders: star_index/SA is stored as star_index__SA; the download script
# puts files back in place and checks them against SHA256SUMS.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
VERSION=$(cat "$here/../VERSION")
source "$here/_site_conf.sh"; load_site_conf
refs=${SITE_REFS:-} token_file=$HOME/.zenodo_token dep_id="" creator="Yellapantula, Venkata" host=https://zenodo.org dry_run=0
die() { echo "ERROR: $*" >&2; exit 1; }
while [[ $# -gt 0 ]]; do
  case $1 in
    --refs) refs=$2; shift ;; --token-file) token_file=$2; shift ;; --deposition) dep_id=$2; shift ;;
    --creator) creator=$2; shift ;; --sandbox) host=https://sandbox.zenodo.org ;; --dry-run) dry_run=1 ;;
    -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
    *) die "unknown option $1" ;;
  esac
  shift
done
[[ -n $refs && -d $refs ]] || die "give --refs DIR (or REFS in site.conf)"
refs=$(cd "$refs" && pwd)
for f in star_index/genomeParameters.txt star_index/SA genes.gtf genes.collapsed.gtf reference_manifest.json; do
  [[ -s $refs/$f ]] || die "bundle incomplete: $refs/$f missing"
done
command -v curl >/dev/null && command -v python3 >/dev/null || die "needs curl and python3"
sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
md5of() { if command -v md5sum >/dev/null; then md5sum "$1" | cut -d' ' -f1; else md5 -q "$1"; fi; }
json() { python3 -c "import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1]))" "$1"; }

# Files to upload: bundle files (run logs excluded: they hold local paths) + SHA256SUMS,
# README.md and LICENSE written to a small side folder.
side=$(dirname "$refs")/.cog-ball-zenodo-side
mkdir -p "$side"
rels=(reference_manifest.json genes.gtf genes.collapsed.gtf)
for f in "$refs"/star_index/*; do rels+=("star_index/$(basename "$f")"); done
if [[ ! -s $side/SHA256SUMS || $side/SHA256SUMS -ot $refs/reference_manifest.json ]]; then
  echo "== checksumming the bundle"
  for r in "${rels[@]}"; do printf '%s  %s\n' "$(sha256 "$refs/$r")" "$r"; done > "$side/SHA256SUMS"
fi
sed "s|__VERSION__|$VERSION|g" "$here/../docs/zenodo/README.md" > "$side/README.md"
cp "$here/../docs/huggingface/LICENSE" "$side/LICENSE"
src_of() { case $1 in SHA256SUMS|README.md|LICENSE) echo "$side/$1" ;; *) echo "$refs/$1" ;; esac; }
uploads=(SHA256SUMS README.md LICENSE "${rels[@]}")
total=0; for r in "${uploads[@]}"; do total=$(( total + $(wc -c < "$(src_of "$r")") )); done
echo "== ${#uploads[@]} files, $(( total / 1024 / 1024 / 1024 )) GB, to $host"
if [[ $dry_run == 1 ]]; then
  for r in "${uploads[@]}"; do printf '   %-40s -> %s\n' "$r" "${r//\//__}"; done
  exit 0
fi

token=${ZENODO_TOKEN:-}
[[ -n $token ]] || { [[ -s $token_file ]] && token=$(tr -d ' \n\r' < "$token_file"); }
[[ -n $token ]] || die "no Zenodo token: create one at $host/account/settings/applications/tokens/new (scopes deposit:write, deposit:actions) and save it to $token_file (chmod 600)"
auth=(-H "Authorization: Bearer $token")
api=$host/api/deposit/depositions

state=$(dirname "$refs")/.cog-ball-zenodo-draft
[[ -z $dep_id && -s $state && $(cut -d' ' -f1 "$state") == "$host" ]] && dep_id=$(cut -d' ' -f2 "$state")
if [[ -n $dep_id ]]; then
  dep=$(curl -fsS "${auth[@]}" "$api/$dep_id") || die "cannot open draft $dep_id (deleted or published?); rerun with --deposition of a draft, or remove $state"
  echo "== continuing draft $dep_id"
else
  dep=$(curl -fsS "${auth[@]}" -H "Content-Type: application/json" -d '{}' "$api") || die "Zenodo refused the token (check scopes deposit:write, deposit:actions)"
  dep_id=$(json 'd["id"]' <<< "$dep"); echo "$host $dep_id" > "$state"
  echo "== created draft $dep_id"
fi
bucket=$(json 'd["links"]["bucket"]' <<< "$dep")
existing=$(json '"\n".join(f["filename"]+" "+f["checksum"] for f in d.get("files", []))' <<< "$dep")

for r in "${uploads[@]}"; do
  name=${r//\//__}; src=$(src_of "$r"); want=$(md5of "$src")
  if grep -qx "$name $want" <<< "$existing"; then echo "   ok (already uploaded)  $name"; continue; fi
  echo "   uploading  $name  ($(( $(wc -c < "$src") / 1024 / 1024 )) MB)"
  # A dropped connection restarts the file (Zenodo has no resumable uploads); a stall
  # (<10 kB/s for 10 min) counts as a drop. Three tries, then give up (rerun continues).
  out=""
  for try in 1 2 3; do
    out=$(curl -fS --speed-limit 10240 --speed-time 600 "${auth[@]}" --upload-file "$src" "$bucket/$name") && break
    out=""; echo "   upload of $name interrupted (try $try of 3)"; sleep 30
  done
  [[ -n $out ]] || die "upload of $name failed; rerun the script to continue"
  got=$(json 'd["checksum"].replace("md5:", "")' <<< "$out")
  [[ $got == "$want" ]] || die "Zenodo's checksum for $name ($got) differs from the local file ($want); rerun to upload it again"
done

echo "== setting metadata"
python3 - "$creator" "$VERSION" > "$side/metadata.json" <<'PY'
import json, sys
creator, version = sys.argv[1], sys.argv[2]
desc = (
 "<p>Ready-made reference bundle for the COG B-ALL MD-ALL classification pipeline, so every "
 "center aligns and counts RNA-seq against byte-identical files.</p>"
 "<ul><li><b>star_index__*</b>: STAR 2.7.11b index (sjdbOverhang 100) of the GRCh38 no-alt analysis set "
 "+ hs38d1 (NCBI GCA_000001405.15)</li>"
 "<li><b>genes.gtf</b>: Ensembl 102, chr1-22/X/Y/MT only (60,616 genes, as in MD-ALL's reference)</li>"
 "<li><b>genes.collapsed.gtf</b>: one transcript per gene (GTEx collapse_annotation.py), for RNA-SeQC QC</li>"
 "<li><b>reference_manifest.json</b>, <b>SHA256SUMS</b>: sources, build parameters and checksums</li></ul>"
 "<p>Download and install with the pipeline: <code>bin/cog-ball-reference.sh --download --zenodo &lt;record id&gt;</code>. "
 "Zenodo stores files without folders; star_index/X is stored as star_index__X.</p>"
 "<p>Derived only from public reference data (NCBI GRCh38, Ensembl 102). No patient data. Research use only.</p>")
print(json.dumps({"metadata": {
  "upload_type": "dataset",
  "title": f"ball_cog_reference v{version}: COG B-ALL MD-ALL reference bundle (GRCh38 analysis set, Ensembl 102, STAR 2.7.11b)",
  "creators": [{"name": creator}],
  "description": desc,
  "version": version,
  "access_right": "restricted",
  "access_conditions": "For the COG B-ALL working group. Please state your name, center and intended use when requesting access.",
  "keywords": ["B-ALL", "MD-ALL", "RNA-seq", "STAR", "GRCh38", "Ensembl 102", "reference genome", "COG"],
}}))
PY
curl -fsS -X PUT "${auth[@]}" -H "Content-Type: application/json" --data @"$side/metadata.json" "$api/$dep_id" > /dev/null \
  || die "metadata update failed (files are uploaded; rerun to retry)"

cat <<MSG

Draft ready (not published): $host/uploads/$dep_id
  1. Open it, check title, creators and description, then click Publish.
     Publishing is permanent; later fixes become a new version of the record.
  2. Give the COG team access: on the published record, Share > Links > create a
     "View" link and send its token to the centers (or approve access requests).
  3. Centers download with:
       bin/cog-ball-reference.sh --download --zenodo $dep_id --zenodo-link-token <token>
     or set ZENODO_RECORD=$dep_id (and ZENODO_LINK_TOKEN) in site.conf.
MSG
