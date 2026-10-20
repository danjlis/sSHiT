#!/usr/bin/env bash
# make_runlists.sh [-v] [-c conf] [--group G ...] -- good-run lists for the dst (and cdb) check.
#
# For every run group in DST_RANGES_FILE (or only --group G), every run number in its ranges is
# looked up in the run DB (DST_DAQ_DSN) and kept if it is a good run:
#   not marked invalid, run type DST_RUNTYPE, >= DST_MIN_EVENTS events, >= DST_MIN_MINUTES long,
#   events from all DST_CALO_HOSTS (except DST_RUNDB_UNLOGGED, which the run DB does not log)
# Writes DST_GOODRUN_DIR/<group>.goodruns.txt: "run<TAB>events" per line, with the ranges, the
# criteria and the counts in "#" header lines. ./shirt.sh run dst checks the DSTs of these runs;
# the cdb check can use the same files as run lists. Rerun only when the criteria change.
#
# Testing without the run DB: SHIRT_DST_MOCK_DIR with maxrun.txt and runs.tsv (runs.sql output).
set -o pipefail
SHIRT_HOME=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
export SHIRT_HOME
. "$SHIRT_HOME/lib/common.sh"
. "$SHIRT_HOME/checks/dst/sql.sh"
trap 'rm -rf "$T"; on_interrupt' INT TERM

CONF=$SHIRT_HOME/shirt.conf; OPT_GROUPS=
while [ $# -gt 0 ]; do
  case "$1" in
    -v) SHIRT_VERBOSE=1 ;;
    -c) CONF=$2; shift ;;
    --group) OPT_GROUPS="$OPT_GROUPS $2"; shift ;;
    -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option $1 (see -h)" ;;
  esac
  shift
done
. "$CONF"
SQLD=$SHIRT_HOME/checks/dst/sql
MOCK=$SHIRT_DST_MOCK_DIR
TAB=$(printf '\t')
[ -s "$DST_RANGES_FILE" ] || die "missing or empty: $DST_RANGES_FILE"
[ -n "$DST_GOODRUN_DIR" ] || die "DST_GOODRUN_DIR is not set"
T=$(mktemp -d)
SQL_LOG=$T/root.log; : > "$SQL_LOG"
[ -n "$SHIRT_VERBOSE" ] && SQL_LOG=/dev/stderr

# ranges.tsv: group first last minev minmin open   ("-" = default threshold, open = LAST was "+")
read_list "$DST_RANGES_FILE" | awk -v OFS='\t' '
  $2 !~ /^[0-9]+$/ || ($3 !~ /^[0-9]+$/ && $3 != "+") { print "BAD", $0; next }
  { print $1, $2, $3, ($4 == "" ? "-" : $4), ($5 == "" ? "-" : $5), ($3 == "+") }' > "$T/ranges.all"
grep '^BAD' "$T/ranges.all" | cut -f2- | while read -r l; do log "WARNING: bad line in $DST_RANGES_FILE (GROUP FIRST LAST|+): $l"; done
grep -v '^BAD' "$T/ranges.all" > "$T/ranges.tsv"
if [ -n "$OPT_GROUPS" ]; then
  for g in $OPT_GROUPS; do cut -f1 "$T/ranges.tsv" | grep -qx "$g" || die "run group $g not in $DST_RANGES_FILE"; done
  printf '%s\n' $OPT_GROUPS > "$T/want"
  awk -F'\t' 'FILENAME == ARGV[1] { g[$1] = 1; next } $1 in g' "$T/want" "$T/ranges.tsv" > "$T/r" && mv "$T/r" "$T/ranges.tsv"
fi
[ -s "$T/ranges.tsv" ] || die "no run ranges to look up"

if [ -z "$MOCK" ]; then sphenix_env || die "ROOT / sPHENIX env not available"; else log "MOCK mode: using $MOCK"; fi
query() {  # query <name> <out> [KEY=VALUE...]
  local name=$1 out=$2; shift 2
  if [ -n "$MOCK" ]; then cp "$MOCK/$name.tsv" "$out" 2>/dev/null || : > "$out"; return 0; fi
  sql_run "$DST_DAQ_DSN" "$SQLD/$name.sql" "$out" 0 "$@"
}

# open-ended ranges -> newest run of DST_RUNTYPE
if awk -F'\t' '$6 == 1 { f = 1 } END { exit !f }' "$T/ranges.tsv"; then
  if [ -n "$MOCK" ]; then cp "$MOCK/maxrun.txt" "$T/max.tsv"; else query maxrun "$T/max.tsv" RUNTYPE="$DST_RUNTYPE"; fi
  MAXRUN=$(head -1 "$T/max.tsv" 2>/dev/null)
  case "$MAXRUN" in ''|*[!0-9]*) cat "$T/root.log" >&2; die "could not get the newest $DST_RUNTYPE run from $DST_DAQ_DSN" ;; esac
  awk -F'\t' -v OFS='\t' -v m="$MAXRUN" '$6 == 1 { $3 = m } { print }' "$T/ranges.tsv" > "$T/r" && mv "$T/r" "$T/ranges.tsv"
  log "newest $DST_RUNTYPE run in the run DB: $MAXRUN"
fi

# rundb.tsv: group run runtype events seconds hosts invalid minev minmin
: > "$T/rundb.tsv"
while IFS="$TAB" read -r g first last minev minmin open; do
  log "run DB: $g runs $first..$last"
  query runs "$T/q.tsv" FIRST="$first" LAST="$last" || { cat "$T/root.log" >&2; die "run DB query failed for $g $first..$last"; }
  awk -F'\t' -v OFS='\t' -v g="$g" -v a="$first" -v b="$last" -v e="$minev" -v m="$minmin" \
    '$1 >= a && $1 <= b { print g, $1, $2, $3, $4, $5, ($6 == "" ? 0 : $6), e, m }' "$T/q.tsv" >> "$T/rundb.tsv"
done < "$T/ranges.tsv"
sort -t"$TAB" -k1,1 -k2,2n -u "$T/rundb.tsv" -o "$T/rundb.tsv"

# hosts the run DB must list: DST_CALO_HOSTS minus DST_RUNDB_UNLOGGED
RUNDB_HOSTS=
for h in $DST_CALO_HOSTS; do
  case " $DST_RUNDB_UNLOGGED " in *" $h "*) ;; *) RUNDB_HOSTS="$RUNDB_HOSTS${RUNDB_HOSTS:+ }$h" ;; esac
done
# runsel.tsv: group run events verdict reason
awk -F'\t' -v OFS='\t' -v rt="$DST_RUNTYPE" -v dmin="${DST_MIN_EVENTS:-0}" -v dmm="${DST_MIN_MINUTES:-0}" -v hosts="$RUNDB_HOSTS" '
  function add(w, r) { return w == "" ? r : w "; " r }
  BEGIN { nh = split(hosts, H, " ") }
  {
    minev = ($8 == "-") ? dmin : $8; minm = ($9 == "-") ? dmm : $9; why = ""
    if ($7 == 1) why = add(why, "marked invalid")
    if ($3 != rt) why = add(why, "run type " $3)
    if ($4 + 0 < minev) why = add(why, "fewer than " minev " events")
    if ($5 + 0 < 0) why = add(why, "no end time")
    else if ($5 + 0 < minm * 60) why = add(why, "shorter than " minm " min")
    if (nh) {
      split("", have); n = split($6, hh, ","); for (j = 1; j <= n; j++) have[hh[j]] = 1
      miss = ""; for (j = 1; j <= nh; j++) if (!(H[j] in have)) miss = miss " " H[j]
      if (miss != "") why = add(why, "calo hosts missing:" miss)
    }
    print $1, $2, $4, (why == "" ? "GOOD" : "BAD"), why
  }' "$T/rundb.tsv" > "$T/runsel.tsv"

crit="not marked invalid, run type $DST_RUNTYPE, at least $DST_MIN_EVENTS events, at least $DST_MIN_MINUTES min long"
[ -n "$RUNDB_HOSTS" ] && crit="$crit, events from all of $RUNDB_HOSTS"
[ -n "$DST_RUNDB_UNLOGGED" ] && crit="$crit ($DST_RUNDB_UNLOGGED not logged in the run DB: checked through its TRIGGERED DSTs)"
mkdir -p "$DST_GOODRUN_DIR"
cut -f1 "$T/ranges.tsv" | awk '!seen[$0]++' | while read -r g; do
  rng=$(awk -F'\t' -v g="$g" '$1 == g { printf "%s%s-%s%s", s, $2, $3, ($6 ? " (newest run)" : ""); s = ", " }' "$T/ranges.tsv")
  thr=$(awk -F'\t' -v g="$g" '$1 == g && ($4 != "-" || $5 != "-") { printf "%s%s-%s:%s%s", s, $2, $3, ($4 != "-" ? " at least " $4 " events" : ""), ($5 != "-" ? " at least " $5 " min" : ""); s = "; " }' "$T/ranges.tsv")
  nrange=$(awk -F'\t' -v g="$g" '$1 == g { s += $3 - $2 + 1 } END { print s + 0 }' "$T/ranges.tsv")
  ndb=$(awk -F'\t' -v g="$g" '$1 == g' "$T/runsel.tsv" | wc -l | tr -d ' ')
  ngood=$(awk -F'\t' -v g="$g" '$1 == g && $4 == "GOOD"' "$T/runsel.tsv" | wc -l | tr -d ' ')
  out=$DST_GOODRUN_DIR/$g.goodruns.txt
  {
    echo "# good runs of $g -- made by checks/dst/make_runlists.sh (shirt $(shirt_version)) on $(date '+%Y-%m-%d %H:%M'); rerun it to change, do not edit"
    echo "# ranges: $rng"
    echo "# criteria: $crit${thr:+; per range: $thr}"
    echo "# counts: $nrange run numbers in range, $ndb in the run DB, $ngood good"
    echo "# run	events"
    awk -F'\t' -v OFS='\t' -v g="$g" '$1 == g && $4 == "GOOD" { print $2, $3 }' "$T/runsel.tsv"
  } > "$out"
  log "$g: $ngood good runs of $ndb in the run DB ($rng) -> $out"
  if [ -n "$SHIRT_VERBOSE" ]; then
    awk -F'\t' -v g="$g" '$1 == g && $4 == "BAD" { n[$5]++ } END { for (r in n) printf "    rejected %6d  %s\n", n[r], r }' "$T/runsel.tsv" | sort -k2,2nr >&2
  fi
done
rm -rf "$T"
