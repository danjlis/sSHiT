#!/usr/bin/env bash
# tag_payloads.sh [-v] [-l] <global tag> <run|runlist-file> [run ...]
#
# Lists the payload types a global tag provides at the given runs, with how many of
# those runs each type is valid for. A tag has no flat payload list -- the CDB only
# answers "what is valid at run N" -- so give runs spread over your data, e.g.
#   checks/cdb/tag_payloads.sh ProdA_2024 config/goodruns.txt
#   checks/cdb/tag_payloads.sh ProdA_2024 47000 50000 53000
#   -l   also print every (run, payload type, IOV, file) line
#   -v   show ROOT output
# Runs from a file are sampled down to ~20 evenly spaced runs.
set -o pipefail
SHIRT_HOME=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
. "$SHIRT_HOME/lib/common.sh"
trap 'rm -f "$runs" "$raw"; on_interrupt' INT TERM
. "$SHIRT_HOME/shirt.conf"

LONG=
while [ $# -gt 0 ]; do
  case "$1" in
    -v) SHIRT_VERBOSE=1 ;;
    -l) LONG=1 ;;
    *) break ;;
  esac
  shift
done
[ $# -ge 2 ] || { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
tag=$1; shift

runs=$(mktemp); raw=$(mktemp)
if [ -f "$1" ]; then
  read_list "$1" | awk '$1 ~ /^[0-9]+$/ { print $1 }' | sort -n -u > "$runs.all"
  n=$(wc -l < "$runs.all" | tr -d ' ')
  awk -v n="$n" 'BEGIN { s = n > 20 ? n / 20 : 1 } (NR - 1) % int(s) == 0 || NR == n' "$runs.all" > "$runs"
  rm -f "$runs.all"
  log "$tag: sampling $(wc -l < "$runs" | tr -d ' ') of $n runs from $1"
else
  for r in "$@"; do
    case "$r" in
      ''|*[!0-9]*) rm -f "$runs" "$raw"; die "'$r' is neither an existing run-list file nor a run number (cwd: $PWD)" ;;
    esac
  done
  printf '%s\n' "$@" > "$runs"
fi
[ -s "$runs" ] || { rm -f "$runs" "$raw"; die "no run numbers found in $1 (first column must be the run number)"; }
NR=$(wc -l < "$runs" | tr -d ' ')

sphenix_env || die "ROOT / sPHENIX env not available"
run_root "$SHIRT_HOME/checks/cdb/macros/TagPayloads.C(\"$tag\",\"$runs\")" > "$raw" 2>&1 || { cat "$raw"; die "TagPayloads.C failed"; }
[ -n "$SHIRT_VERBOSE" ] && grep -v '^TP ' "$raw" >&2
grep -q '^TP_ERROR' "$raw" && die "$(sed -n 's/^TP_ERROR //p' "$raw" | head -1)"
empty=$(grep -c '^TP_EMPTY' "$raw")
[ "$empty" -gt 0 ] && log "WARNING: no payloads at all at $empty of $NR runs ($(grep '^TP_EMPTY' "$raw" | cut -d' ' -f2 | tr '\n' ' '))"

if [ -n "$LONG" ]; then
  printf '%-10s %-40s %-12s %-20s %s\n' RUN PAYLOAD_TYPE IOV_START IOV_END FILE
  grep '^TP ' "$raw" | awk '{ printf "%-10s %-40s %-12s %-20s %s\n", $2, $3, $4, $5, $6 }'
  echo
fi
echo "payload types in $tag at $NR runs ($(head -1 "$runs") .. $(tail -1 "$runs")):"
printf '  %-40s %s\n' PAYLOAD_TYPE "VALID_AT_RUNS"
grep '^TP ' "$raw" | awk -v nr="$NR" '{ c[$3]++ } END { for (p in c) printf "  %-40s %d/%d\n", p, c[p], nr }' | sort
rm -f "$runs" "$raw"
