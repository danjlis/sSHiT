#!/usr/bin/env bash
# discover.sh [-v] [conf] -- read-only look at the run DB and the FileCatalog for the dst check.
#
# Writes config/dst_schema.txt: the ODBC data sources, every table/column of DST_DAQ_DSN and
# DST_FC_DSN, a few sample rows, the run types and DAQ hosts of recent runs, the dsttypes at the
# start of every run range, and a trial run of the dst check's own queries (checks/dst/sql/*.sql)
# on the newest runs. Send the file back so the queries can be fitted to the real schema.
# Every query is a SELECT; a failing query is recorded in the file and the rest still run.
set -o pipefail
SHIRT_HOME=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
. "$SHIRT_HOME/lib/common.sh"
. "$SHIRT_HOME/checks/dst/sql.sh"
trap 'rm -rf "$T"; on_interrupt' INT TERM
[ "$1" = -v ] && { SHIRT_VERBOSE=1; shift; }
. "${1:-$SHIRT_HOME/shirt.conf}"
OUT=$SHIRT_HOME/config/dst_schema.txt
SQLD=$SHIRT_HOME/checks/dst/sql
sphenix_env || die "ROOT / sPHENIX env not available"

T=$(mktemp -d)
SQL_LOG=$T/root.log
: > "$OUT"
section() { printf '\n==================== %s\n' "$*" >> "$OUT"; }

# q <title> <dsn> <sql text>: run an ad-hoc query, append the result (with column names) to OUT
q() {
  local title=$1 dsn=$2
  printf '%s\n' "$3" > "$T/q.sql"
  section "$title  [$dsn]"
  log "$title ($dsn)"
  if sql_run "$dsn" "$T/q.sql" "$T/q.tsv" 1; then
    column -t -s "$(printf '\t')" "$T/q.tsv" 2>/dev/null >> "$OUT" || cat "$T/q.tsv" >> "$OUT"
  else
    { echo "QUERY FAILED: $3"; grep -E 'SQL_ERROR|rror' "$SQL_LOG" | tail -3; } >> "$OUT"
  fi
  : > "$SQL_LOG"
}

section "ODBC data sources"
for f in "$ODBCINI" "$HOME/.odbc.ini" /etc/odbc.ini; do
  [ -n "$f" ] && [ -f "$f" ] && { echo "# $f"; grep '^\[' "$f"; } >> "$OUT"
done
echo "# using DST_DAQ_DSN=$DST_DAQ_DSN DST_FC_DSN=$DST_FC_DSN" >> "$OUT"

for dsn in "$DST_DAQ_DSN" "$DST_FC_DSN"; do
  q "tables and columns" "$dsn" "SELECT table_name, column_name, data_type FROM information_schema.columns
    WHERE table_schema NOT IN ('pg_catalog', 'information_schema') ORDER BY table_name, ordinal_position"
done

# ---- run DB
q "newest runs" "$DST_DAQ_DSN" "SELECT * FROM run ORDER BY runnumber DESC LIMIT 3"
q "run types since run 40000" "$DST_DAQ_DSN" "SELECT runtype, count(*), min(runnumber), max(runnumber) FROM run
    WHERE runnumber >= 40000 GROUP BY runtype ORDER BY runtype"
q "event_numbers sample" "$DST_DAQ_DSN" "SELECT * FROM event_numbers ORDER BY runnumber DESC LIMIT 5"
q "DAQ hosts in the newest 200 $DST_RUNTYPE runs" "$DST_DAQ_DSN" "SELECT hostname, count(DISTINCT runnumber) FROM event_numbers
    WHERE nr_events > 0 AND runnumber IN (SELECT runnumber FROM run WHERE runtype = '$DST_RUNTYPE' ORDER BY runnumber DESC LIMIT 200)
    GROUP BY hostname ORDER BY hostname"

# ---- FileCatalog
q "datasets sample" "$DST_FC_DSN" "SELECT * FROM datasets ORDER BY runnumber DESC LIMIT 3"
q "files sample" "$DST_FC_DSN" "SELECT * FROM files LIMIT 3"
q "production_setup sample" "$DST_FC_DSN" "SELECT * FROM production_setup ORDER BY id DESC LIMIT 10"
q "production_status sample" "$DST_FC_DSN" "SELECT id, dsttype, dstname, dstfile, run, segment, prod_id, status FROM production_status ORDER BY id DESC LIMIT 5"
q "file hosts (first 200k files)" "$DST_FC_DSN" "SELECT full_host_name, count(*) FROM (SELECT full_host_name FROM files LIMIT 200000) x
    GROUP BY full_host_name ORDER BY 2 DESC"
if [ -s "$DST_RANGES_FILE" ]; then
  read_list "$DST_RANGES_FILE" | while read -r g first last rest; do
    case "$first" in ''|*[!0-9]*) continue ;; esac
    q "dsttypes / tags in $g, runs $first..$((first + 300))" "$DST_FC_DSN" "SELECT dsttype, tag, count(*), min(runnumber), max(runnumber)
      FROM datasets WHERE runnumber BETWEEN $first AND $((first + 300)) GROUP BY dsttype, tag ORDER BY dsttype, tag"
  done
fi

# ---- the dst check's own queries on the newest runs
if sql_run "$DST_DAQ_DSN" "$SQLD/maxrun.sql" "$T/max.tsv" 0 RUNTYPE="$DST_RUNTYPE"; then
  max=$(head -1 "$T/max.tsv")
  case "$max" in ''|*[!0-9]*) max= ;; esac
fi
if [ -n "$max" ]; then
  lo=$((max - 20))
  filter=$(read_list "$DST_TYPES_FILE" 2>/dev/null | awk '{ printf "%sd.dsttype LIKE '\''%s'\''", s, $2; s = " OR " }')
  for f in runs dsts setups; do
    dsn=$DST_DAQ_DSN; [ $f != runs ] && dsn=$DST_FC_DSN
    section "checks/dst/sql/$f.sql on runs $lo..$max  [$dsn]"
    log "trial $f.sql"
    if sql_run "$dsn" "$SQLD/$f.sql" "$T/t.tsv" 0 FIRST=$lo LAST=$max "DSTFILTER=${filter:-TRUE}"; then
      cat "$T/t.tsv" >> "$OUT"
    else
      { echo "QUERY FAILED"; grep -E 'SQL_ERROR|rror' "$SQL_LOG" | tail -3; } >> "$OUT"
    fi
    : > "$SQL_LOG"
  done
else
  section "maxrun.sql failed -- skipped the trial of runs.sql / dsts.sql"
fi

rm -rf "$T"
log "wrote $OUT ($(grep -c 'QUERY FAILED' "$OUT") failed queries) -- please send it back"
