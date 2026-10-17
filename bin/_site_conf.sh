# Sourced by the bin/ scripts: read site.conf (KEY=VALUE lines) into SITE_* variables
# and check a center code against centers.tsv. Values are read, never executed.
_repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

load_site_conf() {   # load_site_conf [file]; default $COG_BALL_SITE_CONF or <repo>/site.conf
  local f=${1:-${COG_BALL_SITE_CONF:-$_repo/site.conf}} line key val
  SITE_CONF_FILE=""
  [[ -f $f ]] || return 0
  SITE_CONF_FILE=$f
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%%#*}
    [[ $line =~ ^[[:space:]]*([A-Z_]+)=(.*)$ ]] || continue
    key=${BASH_REMATCH[1]}; val=${BASH_REMATCH[2]}
    val="${val#"${val%%[![:space:]]*}"}"; val="${val%"${val##*[![:space:]]}"}"   # trim
    val=${val#\"}; val=${val%\"}; val=${val#\'}; val=${val%\'}
    case $key in CENTER|REFS|SIF_DIR|OUTDIR|THREADS|HUB|HF_REPO|ZENODO_RECORD|ZENODO_LINK_TOKEN) printf -v "SITE_$key" '%s' "$val" ;; esac
  done < "$f"
}

check_center() {     # check_center CODE -> dies unless CODE is in centers.tsv
  local code=$1 reg=$_repo/centers.tsv
  [[ $code == TEST ]] && return 0   # reserved for validation runs
  [[ -f $reg ]] || return 0
  if ! awk -F'\t' -v c="$code" 'NR > 1 && $1 == c { found = 1 } END { exit !found }' "$reg"; then
    echo "ERROR: center '$code' is not registered in centers.tsv." >&2
    echo "       Registered centers: $(awk -F'\t' 'NR > 1 { printf "%s%s", sep, $1; sep = ", " }' "$reg")." >&2
    echo "       Set CENTER in site.conf to your code, or ask COG to add your center to centers.tsv." >&2
    exit 1
  fi
}
