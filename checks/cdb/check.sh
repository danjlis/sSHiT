#!/usr/bin/env bash
# cdb check -- calorimeter calibrations in the conditions DB.
#
#  coverage  every good run has a valid payload for every watched (tag, payload type)
#  sanity    every referenced payload file exists, is non-empty, opens in ROOT; duplicates flagged
#  recent    payload files of the floating tag created in the last CDB_RECENT_DAYS days
#            (global tags have no timestamps, so file mtimes are used)
#  diff      (tag, run, payload) -> url/md5 compared with the previous report's snapshot;
#            any change in a frozen tag is a FAIL, in the floating tag it is reported
#  compare   optional tag-vs-tag differences (CDB_COMPARE_PAIRS)
#  catalog   global tags / payload types that appeared in the CDB since the last dump_lists.sh
#
# options (passed through by shirt.sh, all repeatable except --runs):
#   --tag TAG        check only this global tag (instead of CDB_TAGS_FILE)
#   --payload TYPE   check only this payload type, for every tag (instead of the per-tag lists)
#   --runs FILE      use this good-run list for every tag (instead of the per-tag lists)
#
# Per-tag lists: a line in CDB_TAGS_FILE is "TAG [runlist [payloadlist]]", paths relative to
# the tags file's directory (or absolute); "-" or a missing column means the default
# (CDB_GOODRUN_LIST / CDB_PAYLOADS_FILE), e.g.
#   ProdA_2024  runs/prodA.txt  payloads/prodA.txt
#   MDC2        -               payloads/mdc2.txt
# Run groups: "TAG:GROUP" checks TAG with that group's own lists; the tag gets one page/card
# summarizing its groups, each group its own page/card. --tag TAG selects all its groups,
# --tag TAG:GROUP just one. The CDB is queried once per tag (union of its groups' runs).
#   ProdA_2024:run2pp    runs/run2pp.txt    payloads/prodA.txt
#   ProdA_2024:run3auau  runs/run3auau.txt  payloads/prodA.txt
# A run with --tag/--payload is a subset run: it is diffed against the last snapshot
# but does not store its own, so full runs always compare against a full snapshot.
#
# Testing without ROOT/CDB: set SHIRT_CDB_MOCK_DIR to a directory with scan.tsv (CdbScan.C output)
# and optionally listing.txt (ListCdb.C output).
set -o pipefail
. "$SHIRT_HOME/lib/common.sh"
. "$SHIRT_HOME/lib/report.sh"
. "$SHIRT_CONF"
trap on_interrupt INT TERM

W=$SHIRT_WORK
A=$W/attach
B=$W/body.html
MACROS=$SHIRT_HOME/checks/cdb/macros
TAB=$(printf '\t')
NOW=$(date +%s)
: > "$B"
: > "$W/root.log"

# -v: stream ROOT output to the terminal as it is written
if [ -n "$SHIRT_VERBOSE" ]; then
  tail -n +1 -f "$W/root.log" >&2 &
  BG_PIDS="$BG_PIDS $!"
fi

finish() {  # finish <summary>
  local status
  if [ -n "$BG_PIDS" ]; then sleep 1; kill $BG_PIDS 2>/dev/null; fi
  status=$(results_worst)
  printf '%s\n%s\n' "$status" "$1" > "$W/summary.txt"
  cp "$W/results.tsv" "$A/results.tsv"
  exit 0
}

tagsafe() { printf '%s' "$1" | sed 's/:/--/g' | tr -c 'A-Za-z0-9_.-' '_'; }
# entries are "TAG" or "TAG:GROUP" (a run group of TAG); base = the CDB global tag
base_of() { printf '%s' "${1%%:*}"; }


# ------------------------------------------------------------------ inputs
OPT_TAGS=; OPT_PAYLOADS=; OPT_RUNS=
while [ $# -gt 0 ]; do
  case "$1" in
    --tag) OPT_TAGS="$OPT_TAGS $2"; shift ;;
    --payload) OPT_PAYLOADS="$OPT_PAYLOADS $2"; shift ;;
    --runs) OPT_RUNS=$2; case "$OPT_RUNS" in /*) ;; *) OPT_RUNS=$PWD/$OPT_RUNS ;; esac; shift ;;
    *) echo "cdb: unknown option $1" >&2; exit 1 ;;
  esac
  shift
done
SUBSET=
need=
if [ -n "$OPT_TAGS" ]; then SUBSET=1; else need="$need $CDB_TAGS_FILE"; fi
[ -n "$OPT_PAYLOADS" ] && SUBSET=1   # payload lists are resolved per tag below

cfg_ok=1
missing=
for f in $need; do
  if [ ! -s "$f" ]; then
    result config "$(basename "$f")" FAIL "missing or empty: $f"
    missing="$missing $f"
    cfg_ok=
  fi
done
if [ -z "$cfg_ok" ]; then
  { h_section "Configuration" FAIL; h_table "$W/results.tsv" "Section|Item|Status|Message" 3
    h_p "Run <code>checks/cdb/dump_lists.sh</code> to create the tag/payload lists and set <code>CDB_GOODRUN_LIST</code> in shirt.conf."; } >> "$B"
  finish "configuration incomplete, missing or empty:$missing"
fi
# tags file: "TAG [runlist [payloadlist]]" per line
: > "$W/tag_lists.tsv"
[ -s "$CDB_TAGS_FILE" ] && read_list "$CDB_TAGS_FILE" | awk -v OFS='\t' '{ print $1, $2, $3 }' > "$W/tag_lists.tsv"
# --tag X: the entry X if listed, else all run groups X:* , else X alone with the default lists
if [ -n "$OPT_TAGS" ]; then
  for t in $OPT_TAGS; do
    awk -F'\t' -v t="$t" '$1 == t { print; f = 1; exit } END { exit !f }' "$W/tag_lists.tsv" >/dev/null && { echo "$t"; continue; }
    awk -F'\t' -v t="$t" 'index($1, t ":") == 1 { print $1; f = 1 } END { exit !f }' "$W/tag_lists.tsv" || echo "$t"
  done | awk '!seen[$0]++' > "$W/tags.txt"
else cut -f1 "$W/tag_lists.tsv" > "$W/tags.txt"; fi
# entries.tsv: entry base-tag; bases.txt: the global tags to query
awk -v OFS='\t' '{ b = $1; sub(/:.*/, "", b); print $1, b }' "$W/tags.txt" > "$W/entries.tsv"
cut -f2 "$W/entries.tsv" | awk '!seen[$0]++' > "$W/bases.txt"

# tag_col <tag> <column>: path from the tags file ("-"/empty -> nothing), made absolute
TAGDIR=$(dirname "$CDB_TAGS_FILE")
tag_col() {
  local v
  v=$(awk -F'\t' -v t="$1" -v c="$2" '$1 == t { print $c; exit }' "$W/tag_lists.tsv")
  [ "$v" = - ] && v=
  [ -n "$v" ] && case "$v" in /*) ;; *) v=$TAGDIR/$v ;; esac
  echo "$v"
}

# per-tag lists. runs: --runs > column 2 > CDB_GOODRUN_LIST; payloads: --payload > column 3 > CDB_PAYLOADS_FILE
#   runs/<tag>.txt  tagruns.tsv (tag run)      tag_runlist.tsv (tag file nruns)  runs.txt (union)
#   pl/<tag>.txt    tagpl.tsv (tag payload)    tag_pllist.tsv  (tag file npl)    payloads.txt (union)
mkdir -p "$W/runs" "$W/pl"
: > "$W/tagruns.tsv"; : > "$W/tag_runlist.tsv"; : > "$W/tagpl.tsv"; : > "$W/tag_pllist.tsv"
while read -r tag; do
  rl=$OPT_RUNS
  [ -z "$rl" ] && rl=$(tag_col "$tag" 2)
  [ -z "$rl" ] && rl=$CDB_GOODRUN_LIST
  pll=$(tag_col "$tag" 3)
  [ -z "$pll" ] && pll=$CDB_PAYLOADS_FILE
  [ -n "$OPT_PAYLOADS" ] && pll="--payload"
  bad=
  if [ ! -s "$rl" ]; then result config "$tag" FAIL "run list missing or empty: $rl"; missing="$missing $rl"; bad=1; fi
  if [ -z "$OPT_PAYLOADS" ] && [ ! -s "$pll" ]; then
    result config "$tag" FAIL "payload list missing or empty: $pll"; missing="$missing $pll"; bad=1
  fi
  if [ -n "$bad" ]; then cfg_ok=; continue; fi

  f="$W/runs/$(tagsafe "$tag").txt"
  read_list "$rl" | awk '$1 ~ /^[0-9]+$/ { print $1 }' | sort -n -u > "$f"
  awk -v OFS='\t' -v t="$tag" '{ print t, $1 }' "$f" >> "$W/tagruns.tsv"
  printf '%s\t%s\t%s\n' "$tag" "$rl" "$(wc -l < "$f" | tr -d ' ')" >> "$W/tag_runlist.tsv"

  f="$W/pl/$(tagsafe "$tag").txt"
  if [ -n "$OPT_PAYLOADS" ]; then printf '%s\n' $OPT_PAYLOADS; else read_list "$pll" | awk '{ print $1 }'; fi | awk '!seen[$0]++' > "$f"
  awk -v OFS='\t' -v t="$tag" '{ print t, $1 }' "$f" >> "$W/tagpl.tsv"
  printf '%s\t%s\t%s\n' "$tag" "$pll" "$(wc -l < "$f" | tr -d ' ')" >> "$W/tag_pllist.tsv"
done < "$W/tags.txt"
if [ -z "$cfg_ok" ]; then
  { h_section "Configuration" FAIL; h_table "$W/results.tsv" "Section|Item|Status|Message" 3; } >> "$B"
  finish "configuration incomplete, missing or empty:$missing"
fi
cut -f2 "$W/tagruns.tsv" | sort -n -u > "$W/runs.txt"
cut -f2 "$W/tagpl.tsv" | sort -u > "$W/payloads.txt"
NTAGS=$(wc -l < "$W/tags.txt" | tr -d ' ')
NBASE=$(wc -l < "$W/bases.txt" | tr -d ' ')
NPL=$(wc -l < "$W/payloads.txt" | tr -d ' ')
NRUNS=$(wc -l < "$W/runs.txt" | tr -d ' ')
FLOAT=$CDB_FLOATING_TAG
log "cdb: $NBASE tags ($NTAGS tag/run-group entries), $NPL payload types, $NRUNS runs, floating tag $FLOAT${SUBSET:+ (subset run)}"
vlog "tags: $(tr '\n' ' ' < "$W/tags.txt")"
while IFS="$TAB" read -r t pll n; do vlog "payload types for $t: $n from $pll"; done < "$W/tag_pllist.tsv"
while IFS="$TAB" read -r t rl n; do vlog "runs for $t: $n from $rl"; done < "$W/tag_runlist.tsv"
vlog "state: $SHIRT_STATE, recent window ${CDB_RECENT_DAYS}d, ROOT file check ${CDB_ROOT_CHECK:-1}"

# ------------------------------------------------------------------ scan the CDB
: > "$W/scan.raw"
if [ -n "$SHIRT_CDB_MOCK_DIR" ]; then
  log "MOCK mode: using $SHIRT_CDB_MOCK_DIR"
  cp "$SHIRT_CDB_MOCK_DIR/scan.tsv" "$W/scan.raw"
  [ -f "$SHIRT_CDB_MOCK_DIR/listing.txt" ] && cp "$SHIRT_CDB_MOCK_DIR/listing.txt" "$W/listing.txt"
  ROOT_OK=
  command -v root >/dev/null 2>&1 && ROOT_OK=1
else
  sphenix_env || { result setup root FAIL "ROOT / sPHENIX environment not available"
                   h_section "Setup" FAIL >> "$B"; h_table "$W/results.tsv" "Section|Item|Status|Message" 3 >> "$B"
                   finish "sPHENIX environment not available"; }
  ROOT_OK=1
  # one query per global tag: union of the runs / payload types of its entries (run groups)
  mkdir -p "$W/bq"
  while read -r tag; do
    trf="$W/bq/$(tagsafe "$tag").runs"; tpf="$W/bq/$(tagsafe "$tag").pl"
    awk -F'\t' -v b="$tag" '$2 == b { print $1 }' "$W/entries.tsv" | while read -r e; do cat "$W/runs/$(tagsafe "$e").txt"; done | sort -n -u > "$trf"
    awk -F'\t' -v b="$tag" '$2 == b { print $1 }' "$W/entries.tsv" | while read -r e; do cat "$W/pl/$(tagsafe "$e").txt"; done | awk '!seen[$0]++' > "$tpf"
    log "scanning tag $tag ($(wc -l < "$trf" | tr -d ' ') runs, $(wc -l < "$tpf" | tr -d ' ') payload types)"
    t0=$SECONDS; n0=$(wc -l < "$W/scan.raw")
    run_root "$MACROS/CdbScan.C(\"$tag\",\"$trf\",\"$tpf\",\"$W/scan.raw\")" >> "$W/root.log" 2>&1 \
      || result scan "$tag" FAIL "CdbScan.C failed (see root.log)"
    vlog "tag $tag: $(( $(wc -l < "$W/scan.raw") - n0 )) rows in $((SECONDS - t0))s"
  done < "$W/bases.txt"
  vlog "listing CDB global tags / payload types"
  run_root "$MACROS/ListCdb.C" > "$W/listing.txt" 2>> "$W/root.log" || rm -f "$W/listing.txt"
fi

# global tag -> its entries (run groups get a copy of the tag's rows), then
# only the asked-for entries, each at its own runs (a mock scan may contain more)
awk -F'\t' -v OFS='\t' 'FILENAME == ARGV[1] { n[$2]++; e[$2, n[$2]] = $1; next }
  { b = $1; for (i = 1; i <= n[b]; i++) { $1 = e[b, i]; print } }' "$W/entries.tsv" "$W/scan.raw" > "$W/scan.tmp" \
  && mv "$W/scan.tmp" "$W/scan.raw"
awk -F'\t' 'FILENAME == ARGV[1] { tr[$1 FS $2] = 1; next } FILENAME == ARGV[2] { t[$1] = 1; next }
  ($1 in t) && ($4 == "TAG_NOT_FOUND" || (($1 FS $2) in tr))' "$W/tagruns.tsv" "$W/tags.txt" "$W/scan.raw" > "$W/scan.tmp" \
  && mv "$W/scan.tmp" "$W/scan.raw"
# tags that do not exist
awk -F'\t' '$4 == "TAG_NOT_FOUND" { sub(/:.*/, "", $1); print $1 }' "$W/scan.raw" | sort -u | while read -r t; do
  result tags "$t" FAIL "global tag does not exist in the CDB"
done
# watched payload types that do not exist in the CDB (usually a typo in the list)
if [ -s "$W/listing.txt" ]; then
  sed -n 's/^payload type: //p' "$W/listing.txt" | sort -u > "$W/live_pl.txt"
  sort -u "$W/payloads.txt" | comm -23 - "$W/live_pl.txt" | while read -r p; do
    result tags "$p" FAIL "payload type does not exist in the CDB (check the name in config/payloads.all.txt)"
    vlog "unknown payload type: $p"
  done
fi
# tags for which the CDB returned no payload at all: query error or runs outside the tag
awk -F'\t' '$4 != "TAG_NOT_FOUND" { n[$1]++; if ($4 != "-") ok[$1]++ }
  END { for (t in n) if (!(t in ok)) print t }' "$W/scan.raw" | while read -r t; do
  result tags "$t" FAIL "no valid payload of any watched type for any run: CDB query error (see root.log) or runs outside this tag"
done
# keep only watched tags/payloads; strip file:// from urls
awk -F'\t' -v OFS='\t' '
  FILENAME == ARGV[1] { tp[$1 FS $2] = 1; next }
  (($1 FS $3) in tp) && $4 != "TAG_NOT_FOUND" { sub(/^file:\/\//, "", $4); print }' \
  "$W/tagpl.tsv" "$W/scan.raw" > "$W/scan.tsv"
log "scan: $(wc -l < "$W/scan.tsv" | tr -d ' ') (tag, run, payload) rows"

# ------------------------------------------------------------------ payload files: stat, md5, ROOT
# cache keyed on (path, size, mtime): path size mtime md5 rstat nkeys rmsg
CACHE=$SHIRT_STATE/filecache.tsv
touch "$CACHE"
cut -f4 "$W/scan.tsv" | grep -v '^-$' | sort -u > "$W/urls.txt"
while IFS= read -r p; do
  sm=$(file_size_mtime "$p")
  if [ -n "$sm" ]; then printf '%s\t1\t%s\t%s\n' "$p" "${sm% *}" "${sm#* }"
  else printf '%s\t0\t0\t0\n' "$p"; fi
done < "$W/urls.txt" > "$W/stat.tsv"

merge_cache() {  # -> files.tsv: path exists size mtime md5 rstat nkeys rmsg   ("?" = unknown)
  awk -F'\t' -v OFS='\t' '
    FILENAME == ARGV[1] { c[$1 FS $2 FS $3] = $4 FS $5 FS $6 FS $7; next }
    {
      k = $1 FS $3 FS $4
      if ($2 == 1 && (k in c)) print $0, c[k]
      else if ($2 == 1) print $0, "?", "?", "", ""
      else print $0, "-", "-", "", ""
    }' "$CACHE" "$W/stat.tsv" > "$W/files.tsv"
}
merge_cache

# md5 for new/changed files
awk -F'\t' '$5 == "?" { print $1 }' "$W/files.tsv" > "$W/need_md5.txt"
log "md5: $(wc -l < "$W/need_md5.txt" | tr -d ' ') files to hash ($(wc -l < "$W/urls.txt" | tr -d ' ') referenced)"
NMD5=$(wc -l < "$W/need_md5.txt" | tr -d ' ')
i=0
while IFS= read -r p; do
  i=$((i + 1))
  vlog "md5 [$i/$NMD5] $p"
  printf '%s\t%s\n' "$p" "$(file_md5 "$p")"
done < "$W/need_md5.txt" > "$W/new_md5.tsv"

# ROOT validation for new/changed .root files (non-root payloads: n/a)
awk -F'\t' '$2 == 1 && $3 > 0 && $6 == "?" && $1 ~ /\.root$/ { print $1 }' "$W/files.tsv" > "$W/need_root.txt"
: > "$W/new_root.tsv"
if [ -s "$W/need_root.txt" ] && [ "${CDB_ROOT_CHECK:-1}" = 1 ] && [ -n "$ROOT_OK" ]; then
  log "ROOT: validating $(wc -l < "$W/need_root.txt" | tr -d ' ') files"
  run_root "$MACROS/PayloadCheck.C(\"$W/need_root.txt\",\"$W/new_root.tsv\")" >> "$W/root.log" 2>&1 \
    || result sanity PayloadCheck.C WARN "ROOT validation failed to run (see root.log)"
fi

# fold new results into files.tsv and the cache
awk -F'\t' -v OFS='\t' '
  FILENAME == ARGV[1] { m[$1] = $2; next }
  FILENAME == ARGV[2] { rs[$1] = $2; rk[$1] = $3; rm[$1] = $4; next }
  {
    if ($1 in m) $5 = m[$1]
    if ($1 in rs) { $6 = rs[$1]; $7 = rk[$1]; $8 = rm[$1] }
    else if ($6 == "?" && $2 == 1 && ($3 == 0 || $1 !~ /\.root$/)) { $6 = "n/a"; $7 = "" }
    print
  }' "$W/new_md5.tsv" "$W/new_root.tsv" "$W/files.tsv" > "$W/files.tmp" && mv "$W/files.tmp" "$W/files.tsv"
# cache only fully-known existing files ("?" stays unknown so it is retried next time)
awk -F'\t' -v OFS='\t' '
  FILENAME == ARGV[1] { if ($2 == 1 && $5 != "?") { print $1, $3, $4, $5, $6, $7, $8; seen[$1] = 1 } next }
  !($1 in seen)' "$W/files.tsv" "$CACHE" > "$CACHE.tmp" && mv "$CACHE.tmp" "$CACHE"

# url index: url -> payload types, tags, nruns, min run, max run
awk -F'\t' -v OFS='\t' '$4 != "-" {
    u = $4; n[u]++
    if (!((u, $3) in sp)) { sp[u, $3] = 1; pls[u] = (pls[u] == "" ? $3 : pls[u] "," $3); npl[u]++ }
    if (!((u, $1) in st)) { st[u, $1] = 1; tgs[u] = (tgs[u] == "" ? $1 : tgs[u] "," $1) }
    if (!(u in lo) || $2 + 0 < lo[u]) lo[u] = $2 + 0
    if (!(u in hi) || $2 + 0 > hi[u]) hi[u] = $2 + 0
  }
  END { for (u in n) print u, pls[u], npl[u], tgs[u], n[u], lo[u], hi[u] }' "$W/scan.tsv" | sort > "$W/uidx.tsv"

# ------------------------------------------------------------------ coverage
# per (tag, payload): covered runs / total, missing runs collapsed into ranges
awk -F'\t' -v OFS='\t' '$4 == "-" { print $2, $1, $3 }' "$W/scan.tsv" | collapse "$W/runs.txt" 12 > "$W/gaps.tsv"
# covered = runs that actually returned a payload (a run with no scan row counts as missing)
awk -F'\t' -v OFS='\t' '
  FILENAME == ARGV[1] { rng[$1 FS $2] = $6; next }
  FILENAME == ARGV[2] { if ($4 != "-") ok[$1 FS $3]++; next }
  FILENAME == ARGV[3] { ntr[$1] = $3; next }
  FILENAME == ARGV[4] { tg[++n] = $1; pl[n] = $2; next }
  END {
    for (i = 1; i <= n; i++) {
      k = tg[i] FS pl[i]; c = ok[k] + 0; nruns = ntr[tg[i]] + 0
      st = (c >= nruns) ? "OK" : "FAIL"
      miss = rng[k]; if (c == 0 && miss == "") miss = "all runs (no CDB answer)"
      printf "%s\t%s\t%d/%d\t%.1f%%\t%s\t%s\n", tg[i], pl[i], c, nruns, nruns ? 100 * c / nruns : 0, st, miss
    }
  }' "$W/gaps.tsv" "$W/scan.tsv" "$W/tag_runlist.tsv" "$W/tagpl.tsv" > "$W/coverage.tsv"
# tags that do not exist have no rows in the scan -> drop them from coverage (already FAILed above)
awk -F'\t' '$4 == "TAG_NOT_FOUND" { print $1 }' "$W/scan.raw" > "$W/badtags.txt"
if [ -s "$W/badtags.txt" ]; then
  awk -F'\t' 'FILENAME == ARGV[1] { b[$1] = 1; next } !($1 in b)' "$W/badtags.txt" "$W/coverage.tsv" > "$W/cov.tmp" && mv "$W/cov.tmp" "$W/coverage.tsv"
fi
awk -F'\t' '$5 == "FAIL" { split($3, c, "/"); printf "coverage\t%s %s\tFAIL\t%d of %d runs missing: %s\n", $1, $2, c[2] - c[1], c[2], $6 }' "$W/coverage.tsv" >> "$W/results.tsv"
NGAPS=$(awk -F'\t' '$5 == "FAIL"' "$W/coverage.tsv" | wc -l | tr -d ' ')
# absent = no payload at any checked run (often just not used in this run period);
# partial = some runs covered, some not (the suspicious case)
NABSENT=$(awk -F'\t' '$5 == "FAIL" && $3 ~ /^0\//' "$W/coverage.tsv" | wc -l | tr -d ' ')
NPARTIAL=$((NGAPS - NABSENT))
# show problems first: partial gaps, then absent, then OK
sort -t"$TAB" -k5,5 -k4,4nr "$W/coverage.tsv" > "$W/cov.tmp" && mv "$W/cov.tmp" "$W/coverage.tsv"
vlog "coverage: $NGAPS of $(wc -l < "$W/coverage.tsv" | tr -d ' ') (tag, payload) pairs have gaps"

# ------------------------------------------------------------------ sanity
# bad files: missing, empty, unreadable
awk -F'\t' -v OFS='\t' '
  FILENAME == ARGV[1] { pls[$1] = $2; tgs[$1] = $4; nr[$1] = $5; next }
  {
    st = ""; why = ""
    if ($2 == 0) { st = "FAIL"; why = "file does not exist" }
    else if ($3 == 0) { st = "FAIL"; why = "file is empty" }
    else if ($6 == "ZOMBIE" || $6 == "NOOPEN" || $6 == "NOKEYS") { st = "FAIL"; why = $8 }
    else if ($6 == "RECOVERED") { st = "WARN"; why = $8 }
    if (st != "") print st, $1, pls[$1], tgs[$1], nr[$1], why
  }' "$W/uidx.tsv" "$W/files.tsv" > "$W/badfiles.tsv"
awk -F'\t' '{ printf "sanity\t%s\t%s\t%s (used by %s in %s)\n", $2, $1, $6, $3, $4 }' "$W/badfiles.tsv" >> "$W/results.tsv"
# one file serving several payload types
awk -F'\t' -v OFS='\t' '$3 > 1 { print "WARN", $1, $2, $4, $5 }' "$W/uidx.tsv" > "$W/shared.tsv"
awk -F'\t' '{ printf "sanity\t%s\tWARN\tsame file used by several payload types: %s\n", $2, $3 }' "$W/shared.tsv" >> "$W/results.tsv"
# identical content under different file names
awk -F'\t' '$5 != "-" && $5 != "?" && $5 != "" { print $5 "\t" $1 }' "$W/files.tsv" | sort \
  | awk -F'\t' -v OFS='\t' '
      $1 == pm { list = list " " $2; n++; next }
      { if (n > 1) print pm, n, list; pm = $1; list = $2; n = 1 }
      END { if (n > 1) print pm, n, list }' > "$W/dupes.tsv"
awk -F'\t' '{ printf "sanity\tmd5 %s\tINFO\t%d files with identical content\n", $1, $2 }' "$W/dupes.tsv" >> "$W/results.tsv"
NBAD=$(wc -l < "$W/badfiles.tsv" | tr -d ' ')
vlog "sanity: $NBAD bad files, $(wc -l < "$W/shared.tsv" | tr -d ' ') shared, $(wc -l < "$W/dupes.tsv" | tr -d ' ') duplicate md5 groups"

# ------------------------------------------------------------------ recent updates (all tags; results for the floating tag)
CUT=$((NOW - ${CDB_RECENT_DAYS:-14} * 86400))
# tag_urls.tsv: tag payload url count first last ranges
awk -F'\t' -v OFS='\t' '$4 != "-" { print $2, $1, $3, $4 }' "$W/scan.tsv" | collapse "$W/runs.txt" 6 > "$W/tag_urls.tsv"
# recent_all.tsv: date tag payload url count ranges   (newest first)
awk -F'\t' -v OFS='\t' -v cut="$CUT" '
  FILENAME == ARGV[1] { mt[$1] = $4; next }
  ($3 in mt) && mt[$3] >= cut { print mt[$3], $1, $2, $3, $4, $7 }' "$W/files.tsv" "$W/tag_urls.tsv" \
  | sort -t"$TAB" -k1,1nr > "$W/recent.raw"
: > "$W/recent_all.tsv"
while IFS="$TAB" read -r mt tag pl url cnt rng; do
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(fmt_epoch "$mt")" "$tag" "$pl" "$url" "$cnt" "$rng" >> "$W/recent_all.tsv"
  [ "$(base_of "$tag")" = "$FLOAT" ] && result recent "$tag $pl" INFO "new payload file $(fmt_epoch "$mt"): $url ($cnt runs)"
done < "$W/recent.raw"
NRECENT=$(awk -F'\t' -v ft="$FLOAT" '{ b = $2; sub(/:.*/, "", b) } b == ft { print $4 }' "$W/recent_all.tsv" | sort -u | wc -l | tr -d ' ')
vlog "recent: $NRECENT files in $FLOAT newer than $(fmt_epoch "$CUT") ($(wc -l < "$W/recent_all.tsv" | tr -d ' ') over all tags)"
# ages_all.tsv: tag payload distinct-files newest-date age-days newest-file
awk -F'\t' -v OFS='\t' '
  FILENAME == ARGV[1] { mt[$1] = $4; next }
  { k = $1 FS $2; nf[k]++; if (($3 in mt) && mt[$3] > best[k]) { best[k] = mt[$3]; bu[k] = $3 } }
  END { for (k in nf) print k, nf[k], best[k] + 0, bu[k] }' "$W/files.tsv" "$W/tag_urls.tsv" | sort > "$W/ages.raw"
: > "$W/ages_all.tsv"
while IFS="$TAB" read -r tag pl nfiles mt url; do
  if [ "$mt" -gt 0 ]; then d=$(fmt_epoch "$mt"); age=$(( (NOW - mt) / 86400 )); else d="-"; age="-"; fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$tag" "$pl" "$nfiles" "$d" "$age" "$url" >> "$W/ages_all.tsv"
done < "$W/ages.raw"
# tag_last.tsv: tag newest-file-mtime
awk -F'\t' -v OFS='\t' '
  FILENAME == ARGV[1] { mt[$1] = $4; next }
  ($3 in mt) && mt[$3] > last[$1] { last[$1] = mt[$3] }
  END { for (t in last) print t, last[t] }' "$W/files.tsv" "$W/tag_urls.tsv" > "$W/tag_last.tsv"

# ------------------------------------------------------------------ snapshot diff
SNAPDIR=$SHIRT_STATE/snapshots
mkdir -p "$SNAPDIR"
PREV=$(ls "$SNAPDIR" 2>/dev/null | grep '\.tsv\.gz$' | sort | tail -1)
awk -F'\t' -v OFS='\t' '
  FILENAME == ARGV[1] { m[$1] = $5; next }
  { print $1, $2, $3, $4, ($4 in m) ? m[$4] : "-" }' "$W/files.tsv" "$W/scan.tsv" > "$W/snapshot.tsv"
: > "$W/diff.tsv"
NDIFF=0
if [ -n "$PREV" ]; then
  log "diffing against snapshot $PREV"
  gzip -dc "$SNAPDIR/$PREV" > "$W/prev.tsv"
  # compare only (tag, run, payload) where tag, run and payload exist in both snapshots,
  # so editing the good-run list or the watched lists is not reported as a CDB change
  awk -F'\t' -v OFS='\t' '
    FILENAME == ARGV[1] { ot[$1] = 1; orun[$1 FS $2] = 1; opl[$1 FS $3] = 1; ou[$1 FS $2 FS $3] = $4; om[$1 FS $2 FS $3] = $5; next }
    FILENAME == ARGV[2] { nt[$1] = 1; nrun[$1 FS $2] = 1; npl[$1 FS $3] = 1; nu[$1 FS $2 FS $3] = $4; nm[$1 FS $2 FS $3] = $5; next }
    END {
      for (k in nu) {
        split(k, f, FS); if (!((f[1] in ot) && ((f[1] FS f[2]) in orun) && ((f[1] FS f[3]) in opl))) continue
        if (!(k in ou)) continue
        if (ou[k] == "-" && nu[k] != "-") kind = "added"
        else if (ou[k] != "-" && nu[k] == "-") kind = "removed"
        else if (ou[k] != nu[k]) kind = "url changed"
        else if (om[k] != nm[k] && om[k] != "-" && nm[k] != "-") kind = "file overwritten"
        else continue
        print f[2], f[1], f[3], kind, ou[k], nu[k]
      }
      for (k in ou) if (!(k in nu)) {
        split(k, f, FS); if (!((f[1] in nt) && ((f[1] FS f[2]) in nrun) && ((f[1] FS f[3]) in npl))) continue
        if (ou[k] != "-") print f[2], f[1], f[3], "removed", ou[k], "-"
      }
    }' "$W/prev.tsv" "$W/snapshot.tsv" | collapse "$W/runs.txt" 10 \
    | awk -F'\t' -v OFS='\t' -v ft="$FLOAT" '{
        b = $1; sub(/:.*/, "", b)
        st = (b == ft) ? (($3 == "file overwritten") ? "WARN" : "INFO") : "FAIL"
        print st, $1, $2, $3, $4, $5, $6, $9 }' | sort -t"$TAB" -k2,2 -k3,3 > "$W/diff.tsv"
  # diff.tsv: status tag payload kind old new nruns ranges
  awk -F'\t' '{ printf "diff\t%s %s\t%s\t%s for %s runs (%s): %s -> %s\n", $2, $3, $1, $4, $7, $8, $5, $6 }' "$W/diff.tsv" >> "$W/results.tsv"
  NDIFF=$(awk -F'\t' '{ s += $7 } END { print s + 0 }' "$W/diff.tsv")
  vlog "diff: $NDIFF changed (tag, run, payload) in $(wc -l < "$W/diff.tsv" | tr -d ' ') groups"
  rm -f "$W/prev.tsv"
fi
gzip -c "$W/snapshot.tsv" > "$A/snapshot.tsv.gz"
if [ -z "$SUBSET" ]; then cp "$A/snapshot.tsv.gz" "$SNAPDIR/$SHIRT_STAMP.tsv.gz"
else log "subset run: snapshot not stored"; fi

# ------------------------------------------------------------------ tag-vs-tag comparison
: > "$W/compare.tsv"
for pair in ${CDB_COMPARE_PAIRS[@]+"${CDB_COMPARE_PAIRS[@]}"}; do
  ta=${pair%%:*}; tb=${pair#*:}
  awk -F'\t' -v OFS='\t' -v a="$ta" -v b="$tb" '
    { t = $1; sub(/:.*/, "", t) }
    t == a { ua[$2 FS $3] = $4 }
    t == b { ub[$2 FS $3] = $4 }
    END { for (k in ua) if ((k in ub) && ua[k] != ub[k]) { split(k, f, FS); print f[1], f[2], ua[k], ub[k] } }' "$W/scan.tsv" \
    | collapse "$W/runs.txt" 10 \
    | awk -F'\t' -v OFS='\t' -v p="$ta vs $tb" '{ print p, $1, $4, $2, $3, $7 }' >> "$W/compare.tsv"
done
# compare.tsv: pair payload nruns url_a url_b ranges
awk -F'\t' '{ printf "compare\t%s %s\tINFO\t%s runs differ (%s)\n", $1, $2, $3, $6 }' "$W/compare.tsv" >> "$W/results.tsv"

# ------------------------------------------------------------------ catalog: new tags / payload types
: > "$W/catalog.tsv"
CATDIR=$(dirname "$CDB_TAGS_FILE")
if [ ! -f "$CATDIR/global_tags.all.txt" ]; then
  result catalog "dump_lists.sh" INFO "no $CATDIR/*.all.txt yet; run checks/cdb/dump_lists.sh to track new tags/payload types"
elif [ -s "$W/listing.txt" ]; then
  for kind in "global tag:global_tags" "payload type:payloads"; do
    label=${kind%%:*}; f=${kind#*:}
    sed -n "s/^$label: //p" "$W/listing.txt" | sort -u > "$W/live.txt"
    if [ -f "$CATDIR/$f.all.txt" ]; then
      read_list "$CATDIR/$f.all.txt" | sort -u > "$W/known.txt"
      comm -23 "$W/live.txt" "$W/known.txt" | while read -r x; do
        printf '%s\t%s\tnew since last dump_lists.sh\n' "$label" "$x" >> "$W/catalog.tsv"
        result catalog "$x" INFO "new $label in the CDB"
      done
      comm -13 "$W/live.txt" "$W/known.txt" | while read -r x; do
        printf '%s\t%s\tgone from the CDB\n' "$label" "$x" >> "$W/catalog.tsv"
        result catalog "$x" WARN "$label no longer in the CDB"
      done
    fi
  done
fi

# ------------------------------------------------------------------ HTML
OVERALL=$(results_worst)
NFILES=$(wc -l < "$W/urls.txt" | tr -d ' ')
TAGLBL="$NBASE tags"
[ "$NTAGS" != "$NBASE" ] && TAGLBL="$NBASE tags ($NTAGS tags/run groups)"
SUMMARY="$TAGLBL x $NPL payload types x $NRUNS runs, $NFILES payload files: $NGAPS coverage gaps ($NPARTIAL partial, $NABSENT absent at all runs), $NBAD bad files, $NRECENT new files in $FLOAT (last ${CDB_RECENT_DAYS}d)"
NTAGERR=$(awk -F'\t' '$1 == "tags"' "$W/results.tsv" | wc -l | tr -d ' ')
[ "$NTAGERR" -gt 0 ] && SUMMARY="$NTAGERR tag/payload-type problems ($(awk -F'\t' '$1 == "tags" { printf "%s%s", sep, $2; sep = ", " }' "$W/results.tsv")), $SUMMARY"
# subset label: what was selected on the command line (long lists shortened)
short_list() { set -- $1; if [ $# -le 4 ]; then echo "$*"; else echo "$1 $2 $3 +$(($# - 3)) more"; fi; }
if [ -n "$SUBSET" ]; then
  lbl=
  [ -n "$OPT_TAGS" ] && lbl="tag $(short_list "$OPT_TAGS")"
  [ -n "$OPT_PAYLOADS" ] && lbl="${lbl:+$lbl, }payload $(short_list "$OPT_PAYLOADS")"
  SUMMARY="[subset: $lbl] $SUMMARY"
fi
if [ -n "$PREV" ]; then SUMMARY="$SUMMARY, $NDIFF changed (tag,run,payload) since ${PREV%.tsv.gz}"
else SUMMARY="$SUMMARY, first snapshot (no diff yet)"; fi

sec_status() { awk -F'\t' -v s="$1" '$1 == s { print $3 }' "$W/results.tsv" | sort -u | tr '\n' ' '; }
sec_worst() { local x; x=$(sec_status "$1"); worst_status OK $x; }
col_worst() { local x; x=$(cut -f"$1" "$2" 2>/dev/null | sort -u); worst_status OK $x; }   # col_worst <col> <tsv>

# ---- one page per global tag (pages/<name>.html + pages/<name>.summary), one card each
mkdir -p "$W/pages"
: > "$W/cards.html"
awk -F'\t' -v ft="$FLOAT" '$2 == ft { print $1 }' "$W/entries.tsv" > "$W/tag_order.txt"
awk -F'\t' -v ft="$FLOAT" '$2 != ft { print $1 }' "$W/entries.tsv" >> "$W/tag_order.txt"
DAYS=${CDB_RECENT_DAYS:-14}
while read -r tag; do
  pn="tag_$(tagsafe "$tag")"
  btag=$(base_of "$tag"); grp=; [ "$btag" != "$tag" ] && grp=${tag#*:}
  trl=$(awk -F'\t' -v t="$tag" '$1 == t { print $2 }' "$W/tag_runlist.tsv")
  tnr=$(awk -F'\t' -v t="$tag" '$1 == t { print $3 }' "$W/tag_runlist.tsv")
  tpl=$(awk -F'\t' -v t="$tag" '$1 == t { print $2 }' "$W/tag_pllist.tsv")
  P=$W/pt
  awk -F'\t' -v t="$tag" '$1 == t' "$W/coverage.tsv" | cut -f2- > "$P.cov"                  # payload covered pct status missing
  awk -F'\t' -v t="$tag" 'index("," $4 ",", "," t ",")' "$W/badfiles.tsv" > "$P.bad"
  awk -F'\t' -v t="$tag" 'index("," $4 ",", "," t ",")' "$W/shared.tsv" > "$P.shared"
  awk -F'\t' -v OFS='\t' -v t="$tag" '$2 == t { print $1, $3, $4, $5, $6 }' "$W/recent_all.tsv" > "$P.recent"
  awk -F'\t' -v t="$tag" '$1 == t' "$W/ages_all.tsv" | cut -f2- > "$P.ages"
  awk -F'\t' -v OFS='\t' -v t="$tag" '$2 == t { print $1, $3, $4, $5, $6, $7, $8 }' "$W/diff.tsv" > "$P.diff"
  awk -F'\t' -v t="$tag" '{ split($1, ab, " vs "); if (ab[1] == t || ab[2] == t) print }' "$W/compare.tsv" > "$P.cmp"

  # per-test status
  s_exist=OK; grep -qx "$tag" "$W/badtags.txt" && s_exist=FAIL
  s_cov=$(col_worst 4 "$P.cov")
  s_files=$(worst_status "$(col_worst 1 "$P.bad")" "$(col_worst 1 "$P.shared")")
  s_diff=$(col_worst 1 "$P.diff")
  st=$(worst_status "$s_exist" "$s_cov" "$s_files" "$s_diff")
  failed=; warned=
  for t in "exists:$s_exist" "coverage:$s_cov" "files:$s_files" "changes:$s_diff"; do
    case "${t#*:}" in FAIL) failed="$failed ${t%%:*}" ;; WARN) warned="$warned ${t%%:*}" ;; esac
  done

  # numbers for the card
  npl=$(wc -l < "$P.cov" | tr -d ' ')
  covab=$(awk -F'\t' '{ split($2, c, "/"); a += c[1]; b += c[2] } END { print a + 0, b + 0 }' "$P.cov")
  covpct=$(echo "$covab" | awk '{ if ($2) printf "%.1f", 100 * $1 / $2; else print "-" }')
  nfiles=$(awk -F'\t' -v t="$tag" '$1 == t { print $3 }' "$W/tag_urls.tsv" | sort -u | wc -l | tr -d ' ')
  nrecent=$(wc -l < "$P.recent" | tr -d ' ')
  last=$(awk -F'\t' -v t="$tag" '$1 == t { print $2 }' "$W/tag_last.tsv")
  if [ -n "$last" ]; then lastd=$(fmt_epoch "$last"); lastage=$(( (NOW - last) / 86400 )); else lastd="never"; lastage=; fi
  ngaps=$(awk -F'\t' '$4 == "FAIL"' "$P.cov" | wc -l | tr -d ' ')

  # page
  psum="$tag: coverage ${covpct}% over $npl payload types x $tnr runs, $nfiles files, last updated $lastd"
  [ -n "$failed" ] && psum="$psum; FAILED:$failed"
  [ -n "$warned" ] && psum="$psum; WARN:$warned"
  printf '%s\n%s\n%s\n' "$st" "$psum" "$tag" > "$W/pages/$pn.summary"
  {
    [ -n "$grp" ] && h_p "Run group <b>$grp</b> of global tag <a href=\"@PAGES@/tag_$(tagsafe "$btag").html\"><b>$btag</b></a> (all run groups)."
    [ "$s_exist" = FAIL ] && { h_section "Global tag" FAIL; h_p "<b>$btag</b> does not exist in the CDB."; }
    [ "$btag" = "$FLOAT" ] && h_p "<b>$btag</b> is the floating tag: its changes are reported as INFO, a file overwritten in place as WARN."
    [ "$btag" != "$FLOAT" ] && h_p "<b>$btag</b> is treated as frozen: any change since the last report is a FAIL."
    h_p "Payload list: <code>$tpl</code>. Run list: <code>$trl</code> ($tnr runs, $(head -1 "$W/runs/$(tagsafe "$tag").txt") .. $(tail -1 "$W/runs/$(tagsafe "$tag").txt"))."

    h_section "Run coverage" "$s_cov"
    h_p "$ngaps of $npl payload types have runs without a valid payload (partial gaps first; 0/N = type not present for any checked run)."
    h_table "$P.cov" "Payload type|Runs covered|Coverage|Status|Missing runs" 4

    h_section "Payload files" "$s_files"
    h_p "Problem files (missing, empty, unreadable by ROOT):"
    h_table "$P.bad" "Status|File|Payload types|Tags|Runs|Problem" 1 200
    h_p "Files shared by several payload types:"
    h_table "$P.shared" "Status|File|Payload types|Tags|Runs" 1 100

    h_section "Updates in the last $DAYS days" "$([ "$nrecent" -gt 0 ] && echo INFO || echo OK)"
    h_p "Payload files created in the last $DAYS days (file mtime; global tags carry no timestamps)."
    h_table "$P.recent" "File date|Payload type|File|Runs|Run ranges" 0 200
    h_p "Newest payload file per payload type:"
    h_table "$P.ages" "Payload type|Distinct files|Newest file date|Age (days)|Newest file" 0

    h_section "Changes since last report" "$s_diff"
    if [ -z "$PREV" ]; then h_p "First snapshot stored; changes will be shown from the next report on."
    else h_table "$P.diff" "Status|Payload type|Change|Old|New|Runs|Run ranges" 1 300; fi

    if [ -s "$P.cmp" ]; then
      h_section "Tag comparison" INFO
      h_table "$P.cmp" "Tags|Payload type|Runs differing|First tag file|Second tag file|Run ranges" 0 300
    fi
  } > "$W/pages/$pn.html"

  # card
  # the card is kept in the state dir, so a --tag run only replaces its own card;
  # it links to this report's archived tag page (@CHECK@ = path to the check directory)
  etag=$(printf '%s' "$tag" | html_escape)
  mkdir -p "$SHIRT_STATE/cards"
  {
    printf '<a class="card s-%s" href="@CHECK@reports/%s/%s.html">\n' "$st" "$SHIRT_STAMP" "$pn"
    printf '<div class="ct"><span>%s</span>%s</div>\n' "$etag" "$(h_badge "$st")"
    [ -z "$grp" ] && [ "$tag" = "$FLOAT" ] && printf '<div class="row"><span class="flt">floating</span></div>\n'
    [ -n "$grp" ] && printf '<div class="row"><span class="flt">run group of %s</span></div>\n' "$(printf '%s' "$btag" | html_escape)"
    if [ "$nrecent" -gt 0 ]; then
      printf '<div class="row"><span class="dot on"></span>updated in the last %s days (%s files)</div>\n' "$DAYS" "$nrecent"
    else
      printf '<div class="row"><span class="dot"></span>no updates in the last %s days</div>\n' "$DAYS"
    fi
    printf '<div class="row">last updated: <b>%s</b>%s</div>\n' "$lastd" "${lastage:+ ($lastage d ago)}"
    if [ -n "$failed$warned" ]; then
      printf '<div class="row">'
      for t in $failed; do printf '<span class="chip">%s</span>' "$t"; done
      for t in $warned; do printf '<span class="chip w">%s</span>' "$t"; done
      printf '</div>\n'
    else
      printf '<div class="row">all tests passed</div>\n'
    fi
    if [ "$s_exist" = FAIL ]; then printf '<div class="row">global tag not found in the CDB</div>\n'
    else printf '<div class="row">%s%% coverage &middot; %s payload types &middot; %s files</div>\n' "$covpct" "$npl" "$nfiles"; fi
    printf '<div class="row">checked %s: %s runs (%s), %s payload types (%s)</div>\n' "$SHIRT_STAMP" "$tnr" "$(basename "$trl")" "$npl" "$(basename -- "$tpl")"
    printf '</a>\n'
  } > "$SHIRT_STATE/cards/$pn.html"
  # numbers for the global tag's run-group summary, "-" = empty (stamp st failed warned nrecent last cov_a cov_b npl nfiles nruns runlist summary)
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$SHIRT_STAMP" "$st" "$(f=$(echo $failed); echo "${f:--}")" "$(f=$(echo $warned); echo "${f:--}")" "$nrecent" \
    "${last:-0}" "${covab% *}" "${covab#* }" "$npl" "$nfiles" "$tnr" "$(basename "$trl")" "$psum" > "$SHIRT_STATE/cards/$pn.tsv"
  vlog "tag $tag: $st (coverage $covpct%, last updated $lastd${failed:+, failed:$failed}${warned:+, warn:$warned})"
done < "$W/tag_order.txt"
rm -f "$W"/pt.*

# ---- global tags with run groups: one page + card summarizing the latest result of each group
# (groups from the tags file plus any checked in this run; a --tag TAG:GROUP run only refreshes one)
{ cut -f1 "$W/tag_lists.tsv"; cat "$W/tag_order.txt"; } | awk '!seen[$0]++' | grep ':' > "$W/groups.txt"
cut -d: -f1 "$W/groups.txt" | awk '!seen[$0]++' > "$W/grouped.txt"
while read -r btag; do
  awk -F'\t' -v b="$btag" '$2 == b' "$W/entries.tsv" | grep -q . || continue   # not checked in this run
  pn="tag_$(tagsafe "$btag")"
  eb=$(printf '%s' "$btag" | html_escape)
  G=$W/grp.tsv   # group stamp st failed warned nrecent last cov_a cov_b npl nfiles nruns runlist summary
  : > "$G"
  awk -v b="$btag:" 'index($0, b) == 1' "$W/groups.txt" | while read -r e; do
    f="$SHIRT_STATE/cards/tag_$(tagsafe "$e").tsv"
    if [ -f "$f" ]; then printf '%s\t' "${e#*:}"; cat "$f"; else printf '%s\t-\tFAIL\tnot-checked\t-\t0\t0\t0\t0\t0\t0\t0\t-\tnot checked yet\n' "${e#*:}"; fi
  done > "$G"
  st=$(worst_status OK $(cut -f3 "$G"))
  last=$(awk -F'\t' '$7 > m { m = $7 } END { print m + 0 }' "$G")
  if [ "$last" -gt 0 ]; then lastd=$(fmt_epoch "$last"); lastage=$(( (NOW - last) / 86400 )); else lastd="never"; lastage=; fi
  covpct=$(awk -F'\t' '{ a += $8; b += $9 } END { if (b) printf "%.1f", 100 * a / b; else print "-" }' "$G")
  upd=$(awk -F'\t' '$6 > 0 { printf "%s%s", s, $1; s = ", " }' "$G")
  ngrp=$(wc -l < "$G" | tr -d ' ')
  nbadg=$(awk -F'\t' '$3 == "FAIL" || $3 == "WARN"' "$G" | wc -l | tr -d ' ')

  psum="$btag: $ngrp run groups, coverage ${covpct}%, last updated $lastd"
  [ "$nbadg" -gt 0 ] && psum="$psum; problems in $(awk -F'\t' '$3 == "FAIL" || $3 == "WARN" { printf "%s%s", s, $1; s = " " }' "$G")"
  printf '%s\n%s\n%s\n' "$st" "$psum" "$btag" > "$W/pages/$pn.summary"
  {
    [ "$btag" = "$FLOAT" ] && h_p "<b>$eb</b> is the floating tag: its changes are reported as INFO, a file overwritten in place as WARN."
    [ "$btag" != "$FLOAT" ] && h_p "<b>$eb</b> is treated as frozen: any change since the last report is a FAIL."
    h_p "Checked separately for each run group (own run list and payload list). Each group shows its latest check; open a group for its full report."
    printf '<div class="cards">\n'
    awk -v b="$btag:" 'index($0, b) == 1' "$W/groups.txt" | while read -r e; do f="$SHIRT_STATE/cards/tag_$(tagsafe "$e").html"; [ -f "$f" ] && cat "$f"; done
    printf '</div>\n'
    while IFS="$TAB" read -r g gstamp gst gfail gwarn gnrec glast ga gb gnpl gnf gnr grl gsum; do
      gpn="tag_$(tagsafe "$btag:$g")"
      [ "$gfail" = - ] && gfail=; [ "$gwarn" = - ] && gwarn=
      if [ "$gstamp" = - ]; then
        h_section "$g" FAIL; h_p "Not checked yet: <code>./shirt.sh run cdb --tag $btag:$g</code>"; continue
      fi
      h_section "<a href=\"@CHECK@reports/$gstamp/$gpn.html\">$g</a>" "$gst"
      if [ "$glast" -gt 0 ]; then gl="$(fmt_epoch "$glast") ($(( (NOW - glast) / 86400 )) d ago)"; else gl=never; fi
      h_p "$(printf '%s' "$gsum" | html_escape)"
      h_p "Runs: $gnr ($grl) &middot; payload types: $gnpl &middot; files: $gnf &middot; last updated: <b>$gl</b> &middot; new files in the last $DAYS days: $gnrec &middot; checked $gstamp${gfail:+ &middot; <b>failed:</b> $gfail}${gwarn:+ &middot; warn: $gwarn}"
    done < "$G"
  } > "$W/pages/$pn.html"

  {
    printf '<a class="card s-%s" href="@CHECK@reports/%s/%s.html">\n' "$st" "$SHIRT_STAMP" "$pn"
    printf '<div class="ct"><span>%s</span>%s</div>\n' "$eb" "$(h_badge "$st")"
    printf '<div class="row">'
    [ "$btag" = "$FLOAT" ] && printf '<span class="flt">floating</span> '
    printf '%s run groups</div>\n' "$ngrp"
    if [ -n "$upd" ]; then printf '<div class="row"><span class="dot on"></span>updated in the last %s days (%s)</div>\n' "$DAYS" "$upd"
    else printf '<div class="row"><span class="dot"></span>no updates in the last %s days</div>\n' "$DAYS"; fi
    printf '<div class="row">last updated: <b>%s</b>%s</div>\n' "$lastd" "${lastage:+ ($lastage d ago)}"
    printf '<div class="row">'
    if [ "$nbadg" -gt 0 ]; then
      awk -F'\t' '{ n = split($4, f, " "); for (i = 1; i <= n; i++) if (f[i] != "-") printf "<span class=\"chip\">%s: %s</span>", $1, f[i]
                    n = split($5, w, " "); for (i = 1; i <= n; i++) if (w[i] != "-") printf "<span class=\"chip w\">%s: %s</span>", $1, w[i] }' "$G"
    else printf 'all tests passed in all run groups'; fi
    printf '</div>\n'
    printf '<div class="row">%s%% coverage over all run groups</div>\n' "$covpct"
    printf '<div class="row">groups: %s</div>\n' "$(cut -f1 "$G" | tr '\n' ' ')"
    printf '</a>\n'
  } > "$SHIRT_STATE/cards/$pn.html"
  vlog "tag $btag: $st over $ngrp run groups (coverage $covpct%, last updated $lastd)"
done < "$W/grouped.txt"
rm -f "$W/grp.tsv"

# gallery: latest card of every global tag -- floating tag, the watched list, then anything checked in this run
# (a tag with run groups shows its summary card; the group cards are on its page)
{
  echo "$FLOAT"
  cut -f1 "$W/tag_lists.tsv"
  cat "$W/tag_order.txt"
} | cut -d: -f1 | awk '!seen[$0]++' | while read -r tag; do
  f="$SHIRT_STATE/cards/tag_$(tagsafe "$tag").html"
  [ -f "$f" ] && cat "$f"
done > "$W/cards.html"

# ---- index page: cards + checks that are not about a single tag
{
  printf '<p>Floating tag: <b>%s</b>. %s runs over all tags (run list per tag on its card). Raw data: ' "$FLOAT" "$NRUNS"
  printf '<a href="@ATTACH@/results.tsv">results.tsv</a>, <a href="@ATTACH@/scan.tsv.gz">scan.tsv.gz</a>, '
  printf '<a href="@ATTACH@/files.tsv">files.tsv</a>, <a href="@ATTACH@/snapshot.tsv.gz">snapshot.tsv.gz</a>, '
  printf '<a href="@ATTACH@/check.log">log</a>, <a href="@ATTACH@/root.log">root.log</a></p>\n'

  h_section "Global tags"
  [ -n "$SUBSET" ] && h_p "This run checked only: $(tr '\n' ' ' < "$W/tag_order.txt")${OPT_PAYLOADS:+(payload types: $OPT_PAYLOADS)}. Other cards are from their last check."
  printf '<div class="cards">\n'; cat "$W/cards.html"; printf '</div>\n'

  awk -F'\t' '$1 == "tags"' "$W/results.tsv" > "$W/r_tags.tsv"
  if [ -s "$W/r_tags.tsv" ]; then h_section "Global tag / payload type problems" FAIL; h_table "$W/r_tags.tsv" "Section|Name|Status|Message" 3; fi

  if [ -s "$W/dupes.tsv" ]; then
    h_section "Identical payload files" INFO
    h_p "Same content (md5) under different file names:"
    h_table "$W/dupes.tsv" "md5|Files|Paths" 0 100
  fi

  if [ -s "$W/compare.tsv" ]; then
    h_section "Tag comparison" INFO
    h_table "$W/compare.tsv" "Tags|Payload type|Runs differing|First tag file|Second tag file|Run ranges" 0 300
  fi

  if [ -s "$W/catalog.tsv" ]; then
    h_section "CDB catalog changes" "$(sec_worst catalog)"
    h_p "Compared with <code>config/*.all.txt</code> from the last <code>dump_lists.sh</code>; add wanted entries to the curated lists and rerun the dump to acknowledge."
    h_table "$W/catalog.tsv" "Kind|Name|Note" 0
  fi
} >> "$B"

gzip -c "$W/scan.tsv" > "$A/scan.tsv.gz"
cp "$W/files.tsv" "$A/files.tsv"
[ -f "$W/root.log" ] && cp "$W/root.log" "$A/root.log"
finish "$SUMMARY"
