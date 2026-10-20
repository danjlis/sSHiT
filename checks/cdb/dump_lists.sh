#!/usr/bin/env bash
# dump_lists.sh [-v] [conf] -- write every CDB global tag and payload type to config/.
#
#   config/global_tags.all.txt, config/payloads.all.txt   always (re)written: full CDB listing
#   config/global_tags.txt,     config/payloads.txt       created only if missing: copy of the full
#                                                         listing for you to trim to what you want watched
# The cdb check compares the live CDB against the *.all.txt files and reports new tags/payload types.
set -o pipefail
SHIRT_HOME=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
. "$SHIRT_HOME/lib/common.sh"
trap 'rm -f "$raw"; on_interrupt' INT TERM
[ "$1" = -v ] && { SHIRT_VERBOSE=1; shift; }
. "${1:-$SHIRT_HOME/shirt.conf}"
CONF=$(dirname "$CDB_TAGS_FILE")    # lists live next to the curated tag list
mkdir -p "$CONF"
sphenix_env || die "ROOT / sPHENIX env not available"

raw=$(mktemp)
log "querying the CDB"
run_root "$SHIRT_HOME/checks/cdb/macros/ListCdb.C" > "$raw" 2>&1 || { cat "$raw"; die "ListCdb.C failed"; }
[ -n "$SHIRT_VERBOSE" ] && cat "$raw" >&2
sed -n 's/^global tag: //p'   "$raw" | sort -u > "$CONF/global_tags.all.txt"
sed -n 's/^payload type: //p' "$raw" | sort -u > "$CONF/payloads.all.txt"
rm -f "$raw"
[ -s "$CONF/global_tags.all.txt" ] || die "no global tags found -- CDB unreachable?"

for f in global_tags payloads; do
  log "$(wc -l < "$CONF/$f.all.txt" | tr -d ' ') entries -> config/$f.all.txt"
  if [ ! -f "$CONF/$f.txt" ]; then
    { echo "# shirt: delete the lines you do NOT want watched ('#' comments out)"; cat "$CONF/$f.all.txt"; } > "$CONF/$f.txt"
    log "created config/$f.txt -- trim it to the entries you want watched"
  else
    log "config/$f.txt exists, left untouched"
  fi
done
