#!/usr/bin/env bash
# draw.sh [-o OUTDIR] FILE|DIR ... -- draw the dst plots from the CSVs the dst check writes.
# Needs only ROOT: no FileCatalog access and no rerun of the check.
#
#   dst_runs_<group>.csv[.gz] -> dst_plots_<group>_<dst>.pdf, one per expected DST of the group:
#       first segment on disk per run, and runs per fraction of segments on disk
#
# A DIR means every such CSV in it, e.g. a published report:
#   checks/dst/draw.sh test_www/dst/reports/2026-10-21_101500
# PDFs go next to each CSV, or to OUTDIR. The macro is checks/dst/plots/DstPlots.C.
set -o pipefail
SHIRT_HOME=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
export SHIRT_HOME
. "$SHIRT_HOME/lib/common.sh"
trap 'rm -rf "$T"; on_interrupt' INT TERM

OUTDIR=
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    -o) OUTDIR=$2; shift ;;
    -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) ARGS+=("$1") ;;
  esac
  shift
done
[ ${#ARGS[@]} -gt 0 ] || die "nothing to draw (see -h)"
if ! command -v root >/dev/null 2>&1; then
  . "${SHIRT_CONF:-$SHIRT_HOME/shirt.conf}"
  sphenix_env || die "ROOT not available"
fi
MACRO=$SHIRT_HOME/checks/dst/plots/DstPlots.C
T=$(mktemp -d)

# plain copy of a .csv or .csv.gz in $T
plain() { local b; b=$(basename "${1%.gz}"); case "$1" in *.gz) gzip -dc "$1" > "$T/$b" ;; *) cp "$1" "$T/$b" ;; esac; echo "$T/$b"; }

files=()
for a in "${ARGS[@]}"; do
  if [ -d "$a" ]; then
    for f in "$a"/dst_runs_*.csv "$a"/dst_runs_*.csv.gz; do [ -f "$f" ] && files+=("$f"); done
  else
    files+=("$a")
  fi
done
[ ${#files[@]} -gt 0 ] || die "no dst_runs_*.csv found in: ${ARGS[*]}"

rc=0
for f in "${files[@]}"; do
  [ -f "$f" ] || { log "missing: $f"; rc=1; continue; }
  dir=${OUTDIR:-$(dirname "$f")}
  mkdir -p "$dir"
  b=$(basename "${f%.gz}" .csv)
  case "$b" in
    dst_runs_*) g=${b#dst_runs_} ;;
    *) log "not a dst plot CSV: $f"; rc=1; continue ;;
  esac
  rm -f "$dir/dst_plots_${g}"_*.pdf
  run_root -e ".L $MACRO" -e "DstRunPlots(\"$(plain "$f")\",\"$g\",\"$dir/dst_plots_$g\")" || rc=1
  n=$(ls "$dir/dst_plots_${g}"_*.pdf 2>/dev/null | wc -l | tr -d ' ')
  if [ "$n" -gt 0 ]; then log "wrote $n PDFs $dir/dst_plots_${g}_*.pdf"; else rc=1; fi
done
rm -rf "$T"
exit $rc
