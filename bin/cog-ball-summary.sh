#!/usr/bin/env bash
# Print one line per sample with its MD-ALL call, for every finished sample in
# OUTDIR/CENTER from site.conf (or in the results folder you give).
#
# Usage:
#   bin/cog-ball-summary.sh                     # your center's results (site.conf)
#   bin/cog-ball-summary.sh /path/results/CHOP  # another results folder
#   bin/cog-ball-summary.sh --tsv > calls.tsv   # tab-separated, e.g. for Excel
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$here/_site_conf.sh"; load_site_conf
tsv=0 dir=""
for a in "$@"; do
  case $a in
    --tsv) tsv=1 ;;
    -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
    *) dir=$a ;;
  esac
done
if [[ -z $dir && -n ${SITE_OUTDIR:-} && -n ${SITE_CENTER:-} ]]; then dir=$SITE_OUTDIR/$SITE_CENTER; fi
[[ -n $dir && -d $dir ]] || { echo "ERROR: no results folder: give one, or set OUTDIR and CENTER in site.conf" >&2; exit 1; }

shopt -s nullglob
files=("$dir"/*/mdall/*.mdall.tsv)
(( ${#files[@]} )) || { echo "No MD-ALL results in $dir yet." >&2; exit 0; }

out=$(awk -F'\t' -v OFS='\t' '
  FNR == 1 { split("", c); for (i = 1; i <= NF; i++) c[$i] = i
             if (NR == 1) print "sample", "MD-ALL call", "agreement", "PhenoGraph", "score", "SVM", "score"
             next }
  { print $c["sample_id"], ($c["gep_call"] == "" ? "needs review" : $c["gep_call"]), $c["agreement"],
          $c["phenoGraph_pred"], sprintf("%.2f", $c["phenoGraph_predScore"]),
          $c["svm_pred"], sprintf("%.2f", $c["svm_predScore"]) }' "${files[@]}")
command -v column >/dev/null || tsv=1   # no `column`: plain tab-separated
if [[ $tsv == 1 ]]; then printf '%s\n' "$out"; else printf '%s\n' "$out" | column -t -s $'\t'; fi
