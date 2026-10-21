#!/usr/bin/env bash
# draw.sh [-o OUTDIR] FILE|DIR ... -- draw the cdb plots from the CSVs the cdb check writes.
# Needs only ROOT: no CDB access and no rerun of the check.
#
#   cdb_status_<page>.csv[.gz]  (+ cdb_fileid_<page>.csv[.gz] next to it) -> cdb_plots_<page>_<detector>.pdf
#       one per detector of cdb_detectors_<page>.csv[.gz]; without that file: cdb_plots_<page>.pdf
#       cdb_runnames_<page>.csv[.gz] next to it (if any): run names on the run axis
#   cdb_fallback_<tag>.csv[.gz]  (+ cdb_detectors_<tag>.csv[.gz] if any)  -> cdb_fallback_<tag>.pdf
#
# A DIR means every such CSV in it, e.g. a published report:
#   checks/cdb/draw.sh test_www/cdb/reports/2026-10-21_101500
# PDFs go next to each CSV, or to OUTDIR. The macros are in checks/cdb/plots/CdbPlots.C.
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
    -h|--help) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) ARGS+=("$1") ;;
  esac
  shift
done
[ ${#ARGS[@]} -gt 0 ] || die "nothing to draw (see -h)"
if ! command -v root >/dev/null 2>&1; then
  . "${SHIRT_CONF:-$SHIRT_HOME/shirt.conf}"
  sphenix_env || die "ROOT not available"
fi
MACRO=$SHIRT_HOME/checks/cdb/plots/CdbPlots.C
T=$(mktemp -d)

# sibling <dir of $1>/<name>.csv or .csv.gz, empty if neither exists
sibling() { local f; f=$(dirname "$1")/$2.csv; [ -f "$f" ] || f=$f.gz; [ -f "$f" ] && echo "$f"; }
# plain copy of a .csv or .csv.gz in $T
plain() { local b; b=$(basename "${1%.gz}"); case "$1" in *.gz) gzip -dc "$1" > "$T/$b" ;; *) cp "$1" "$T/$b" ;; esac; echo "$T/$b"; }
# "tag_ProdA_2024--run3pp" -> "ProdA_2024 / run3pp"
label() { printf '%s' "$1" | sed -e 's/^tag_//' -e 's#--# / #'; }

files=()
for a in "${ARGS[@]}"; do
  if [ -d "$a" ]; then
    for f in "$a"/cdb_status_*.csv "$a"/cdb_status_*.csv.gz "$a"/cdb_fallback_*.csv "$a"/cdb_fallback_*.csv.gz; do [ -f "$f" ] && files+=("$f"); done
  else
    files+=("$a")
  fi
done
[ ${#files[@]} -gt 0 ] || die "no cdb_status_*.csv / cdb_fallback_*.csv found in: ${ARGS[*]}"

rc=0
for f in "${files[@]}"; do
  [ -f "$f" ] || { log "missing: $f"; rc=1; continue; }
  dir=${OUTDIR:-$(dirname "$f")}
  mkdir -p "$dir"
  b=$(basename "${f%.gz}" .csv)
  case "$b" in
    cdb_status_*)
      pg=${b#cdb_status_}
      fid=$(sibling "$f" "cdb_fileid_$pg")
      [ -n "$fid" ] || { log "missing cdb_fileid_$pg.csv next to $f"; rc=1; continue; }
      det=$(sibling "$f" "cdb_detectors_$pg")
      rn=$(sibling "$f" "cdb_runnames_$pg"); [ -n "$rn" ] && rn=$(plain "$rn")
      if [ -n "$det" ]; then
        rm -f "$dir/cdb_plots_${pg}"_*.pdf
        run_root -e ".L $MACRO" -e "CdbDetectorPlots(\"$(plain "$f")\",\"$(plain "$fid")\",\"$(plain "$det")\",\"$(label "$pg")\",\"$dir/cdb_plots_$pg\",\"$rn\")" || rc=1
        out=$(ls "$dir/cdb_plots_${pg}"_*.pdf 2>/dev/null | head -1)
        msg="$(ls "$dir/cdb_plots_${pg}"_*.pdf 2>/dev/null | wc -l | tr -d ' ') detector PDFs $dir/cdb_plots_${pg}_*.pdf"
      else
        out=$dir/cdb_plots_$pg.pdf; msg=$out
        run_root -e ".L $MACRO" -e "CdbStatusPlots(\"$(plain "$f")\",\"$(plain "$fid")\",\"$(label "$pg")\",\"$out\",\"$rn\")" || rc=1
      fi
      ;;
    cdb_fallback_*)
      tg=${b#cdb_fallback_}
      out=$dir/cdb_fallback_$tg.pdf; msg=$out
      det=$(sibling "$f" "cdb_detectors_$tg"); [ -n "$det" ] && det=$(plain "$det")
      run_root -e ".L $MACRO" -e "CdbFallbackPlot(\"$(plain "$f")\",\"$(label "$tg"): runs without their own payload\",\"$out\",\"$det\")" || rc=1
      ;;
    *) log "not a cdb plot CSV: $f"; rc=1; continue ;;
  esac
  if [ -n "$out" ] && [ -s "$out" ]; then log "wrote $msg"; else rc=1; fi
done
rm -rf "$T"
exit $rc
