#!/usr/bin/env bash
# Download MD-ALL's bundled test count files (gu-lab20/MD-ALL @ 3047c05) into
# test/data/, verify their SHA-256, and write test/data/classify_samplesheet.csv
# with absolute paths. Run once on a machine with internet access; the test then
# runs offline (copy test/data along if compute nodes have no internet).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
base=https://raw.githubusercontent.com/gu-lab20/MD-ALL/3047c050f9945acad2c6b413f46f378369c47460/test
mkdir -p "$here/data"
sha() { if command -v sha256sum >/dev/null; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }
echo "sample,counts" > "$here/data/classify_samplesheet.csv"
while read -r sum rel; do
  name=$(basename "$rel"); sample=${name%.DUX4patched.HTSeq}; sample=${sample%.HTSeq}
  dest="$here/data/$name"
  [[ -s $dest ]] || curl -fsSL "$base/$rel" -o "$dest"
  echo "$sum  $dest" | { if command -v sha256sum >/dev/null; then sha256sum -c --quiet -; else shasum -a 256 -c --quiet -; fi; }
  echo "$sample,$dest" >> "$here/data/classify_samplesheet.csv"
done < "$here/mdall_test_files.sha256"
echo "OK: $(($(wc -l < "$here/data/classify_samplesheet.csv") - 1)) test count files in $here/data"
