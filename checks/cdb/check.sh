#!/usr/bin/env bash
# cdb check -- calorimeter calibrations in the conditions DB.
#
#  coverage  every good run has its own payload for every watched (tag, payload type); a run without
#            one falls back to <type>_default (as CDBInterface does) -> "default only" (WARN), and
#            a run with neither -> "nothing" (WARN). <type>_default is scanned for every watched
#            type; listed itself next to <type> it is folded into <type>'s row.
#  plots     per tag / run group: status grid, status fractions and payload-file map (cdb_plots_*.pdf),
#            drawn by checks/cdb/draw.sh from the CSVs this check writes (cdb_status_*.csv,
#            cdb_fileid_*.csv, cdb_files_*.csv, cdb_fallback_*.csv); needs ROOT, CDB_PLOTS=0 = off
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
#   newcdbtag  runs/prodA.txt  payloads/prodA.txt
#   MDC2        -               payloads/mdc2.txt
# Run groups: "TAG:GROUP" checks TAG with that group's own lists; the tag gets one page/card
# summarizing its groups, each group its own page/card. --tag TAG selects all its groups,
# --tag TAG:GROUP just one. The CDB is queried once per tag (union of its groups' runs).
#   newcdbtag:run2pp    runs/run2pp.txt    payloads/prodA.txt
#   newcdbtag:run3auau  runs/run3auau.txt  payloads/prodA.txt
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

# det_map <run group> : stdin payload types -> "type<TAB>detector<TAB>order<TAB>watched(1/0)"
# from CDB_DETECTORS_FILE ("DETECTOR [@group,...] pattern..."; first match wins, else Other;
# no file = everything in one "All"). watched=0: the detector is limited to other run groups.
det_map() {
  awk -F'\t' -v OFS='\t' -v grp="$1" -v df="${CDB_DETECTORS_FILE:-}" '
    BEGIN {
      nd = 0
      if (df != "") while ((getline line < df) > 0) {
        sub(/#.*/, "", line); gsub(/^[ \t]+|[ \t]+$/, "", line); if (line == "") continue
        n = split(line, f, /[ \t]+/); nd++; name[nd] = f[1]; i = 2; gl[nd] = ""
        if (f[2] ~ /^@/) { gl[nd] = substr(f[2], 2); i = 3 }
        re[nd] = ""
        for (; i <= n; i++) { r = f[i]; gsub(/\./, "[.]", r); gsub(/\*/, ".*", r); gsub(/\?/, ".", r); re[nd] = re[nd] (re[nd] == "" ? "" : "|") "^(" r ")$" }
      }
    }
    {
      x = $1; d = (nd ? "Other" : "All"); o = nd + 1; w = 1
      for (k = 1; k <= nd; k++) if (x ~ re[k]) {
        d = name[k]; o = k
        if (gl[k] != "" && grp != "" && index("," gl[k] ",", "," grp ",") == 0) w = 0
        break
      }
      print x, d, o, w
    }'
}


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
#   scanpl/<tag>.txt  tagscan.tsv (tag payload): the watched types plus <type>_default of each
mkdir -p "$W/runs" "$W/pl" "$W/scanpl"
: > "$W/tagruns.tsv"; : > "$W/tag_runlist.tsv"; : > "$W/tagpl.tsv"; : > "$W/tag_pllist.tsv"; : > "$W/tagscan.tsv"; : > "$W/dropped.tsv"
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
  # X_default listed next to X is X's fallback, not a row of its own
  if [ -n "$OPT_PAYLOADS" ]; then printf '%s\n' $OPT_PAYLOADS; else read_list "$pll" | awk '{ print $1 }'; fi | awk '!seen[$0]++' \
    | awk '{ w[NR] = $1; have[$1] = 1 }
      END { for (i = 1; i <= NR; i++) { x = w[i]; if (x ~ /_default$/ && (substr(x, 1, length(x) - 8) in have)) continue; print x } }' > "$f"
  # detectors (det/<tag>.tsv: type detector order) and run-group limits (dropped types go to dropped.tsv)
  grp=; case "$tag" in *:*) grp=${tag#*:} ;; esac
  det_map "$grp" < "$f" > "$W/dm.tsv"
  awk -F'\t' -v OFS='\t' -v t="$tag" '$4 == 0 { print t, $1, $2 }' "$W/dm.tsv" >> "$W/dropped.tsv"
  awk -F'\t' '$4 == 1 { print $1 }' "$W/dm.tsv" > "$f"
  mkdir -p "$W/det"
  awk -F'\t' -v OFS='\t' '$4 == 1 { print $1, $2, $3 }' "$W/dm.tsv" > "$W/det/$(tagsafe "$tag").tsv"
  awk -v OFS='\t' -v t="$tag" '{ print t, $1 }' "$f" >> "$W/tagpl.tsv"
  sf="$W/scanpl/$(tagsafe "$tag").txt"
  awk '{ print } !/_default$/ { print $1 "_default" }' "$f" | awk '!seen[$0]++' > "$sf"
  awk -v OFS='\t' -v t="$tag" '{ print t, $1 }' "$sf" >> "$W/tagscan.tsv"
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
awk -F'\t' '{ n[$1 " (" $3 ")"]++ } END { for (k in n) print k, n[k] }' "$W/dropped.tsv" | while read -r l; do vlog "skipped, detector limited to other run groups: $l types"; done
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
    awk -F'\t' -v b="$tag" '$2 == b { print $1 }' "$W/entries.tsv" | while read -r e; do cat "$W/scanpl/$(tagsafe "$e").txt"; done | awk '!seen[$0]++' > "$tpf"
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
# keep only watched tags/payloads (and their defaults); strip file:// from urls
awk -F'\t' -v OFS='\t' '
  FILENAME == ARGV[1] { tp[$1 FS $2] = 1; next }
  (($1 FS $3) in tp) && $4 != "TAG_NOT_FOUND" { sub(/^file:\/\//, "", $4); print }' \
  "$W/tagscan.tsv" "$W/scan.raw" > "$W/scan.tsv"
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
# Every (tag, run, watched type) is R (own payload), D (only <type>_default) or - (nothing).
# One pass writes, per tag, the CSVs the plots are drawn from (csv/, also published):
#   cdb_status_<page>.csv  run x type: R / D / -
#   cdb_fileid_<page>.csv  run x type: the file the run gets, numbered per type in run order (0 = nothing)
#   cdb_files_<page>.csv   payload,id,source,nruns,first_run,last_run,url  (the numbered files)
# and covcount.tsv (tag type nR nD nN) + the non-R cells on stdout (run tag type status) for the ranges.
awk -F'\t' '$4 == "TAG_NOT_FOUND" { print $1 }' "$W/scan.raw" > "$W/badtags.txt"
mkdir -p "$W/csv"
while read -r t; do printf '%s\t%s\n' "$t" "tag_$(tagsafe "$t")"; done < "$W/tags.txt" > "$W/tagpage.tsv"
awk -F'\t' -v OFS='\t' -v dir="$W/csv" -v cc="$W/covcount.tsv" '
  FILENAME == ARGV[1] { bad[$1] = 1; next }
  FILENAME == ARGV[2] { pg[$1] = $2; next }
  FILENAME == ARGV[3] { u[$1 FS $2 FS $3] = $4; next }
  FILENAME == ARGV[4] { nr[$1]++; R[$1, nr[$1]] = $2; next }
  { if ($1 in bad) next; if (!($1 in np)) tl[++nt] = $1; np[$1]++; P[$1, np[$1]] = $2 }
  END {
    printf "" > cc
    for (ti = 1; ti <= nt; ti++) {
      t = tl[ti]
      fs = dir "/cdb_status_" pg[t] ".csv"; fi = dir "/cdb_fileid_" pg[t] ".csv"; ff = dir "/cdb_files_" pg[t] ".csv"
      h = "run"; for (j = 1; j <= np[t]; j++) h = h "," P[t, j]
      print h > fs; print h > fi
      split("", cnt); split("", id); split("", nid); split("", src); split("", fn); split("", f1); split("", f2); split("", ford)
      for (i = 1; i <= nr[t]; i++) {
        r = R[t, i]; ls = r; li = r
        for (j = 1; j <= np[t]; j++) {
          x = P[t, j]; k = t FS r FS x; kd = k "_default"
          if ((k in u) && u[k] != "-") { st = "R"; url = u[k] }
          else if ((kd in u) && u[kd] != "-") { st = "D"; url = u[kd] }
          else { st = "-"; url = "" }
          cnt[x, st]++
          if (st == "-") { ls = ls ",-"; li = li ",0" }
          else {
            fk = x SUBSEP url
            if (!(fk in id)) { id[fk] = ++nid[x]; src[fk] = st; f1[fk] = r; ford[x, nid[x]] = url }
            fn[fk]++; f2[fk] = r
            ls = ls "," st; li = li "," id[fk]
          }
          if (st != "R") print r, t, x, st
        }
        print ls > fs; print li > fi
      }
      print "payload,id,source,nruns,first_run,last_run,url" > ff
      for (j = 1; j <= np[t]; j++) {
        x = P[t, j]
        print t, x, cnt[x, "R"] + 0, cnt[x, "D"] + 0, cnt[x, "-"] + 0 >> cc
        for (m = 1; m <= nid[x]; m++) { fk = x SUBSEP ford[x, m]; print x "," m "," src[fk] "," fn[fk] "," f1[fk] "," f2[fk] "," ford[x, m] > ff }
      }
      close(fs); close(fi); close(ff)
    }
  }' "$W/badtags.txt" "$W/tagpage.tsv" "$W/scan.tsv" "$W/tagruns.tsv" "$W/tagpl.tsv" | collapse "$W/runs.txt" 12 > "$W/gaps.tsv"
# cdb_detectors_<page>.csv: payload,detector in detector order (the plots are drawn per detector)
while IFS="$TAB" read -r t pg; do
  [ -f "$W/det/${pg#tag_}.tsv" ] || continue
  grep -qx "$t" "$W/badtags.txt" && continue
  { echo "payload,detector"; awk -F'\t' -v OFS=',' '{ print $3, NR, $1, $2 }' "$W/det/${pg#tag_}.tsv" | sort -t, -k1,1n -k2,2n | cut -d, -f3,4; } > "$W/csv/cdb_detectors_$pg.csv"
done < "$W/tagpage.tsv"
# run names (CDB_RUN_NAMES_FILE: "RUN name..."): cdb_runnames_<page>.csv (run,name) for tags with named runs
: > "$W/runnames.tsv"
[ -n "$CDB_RUN_NAMES_FILE" ] && [ -s "$CDB_RUN_NAMES_FILE" ] \
  && read_list "$CDB_RUN_NAMES_FILE" | awk -v OFS='\t' '$1 ~ /^[0-9]+$/ { r = $1; sub(/^[0-9]+[ \t]+/, ""); print r, $0 }' > "$W/runnames.tsv"
if [ -s "$W/runnames.tsv" ]; then
  while IFS="$TAB" read -r t pg; do
    [ -f "$W/csv/cdb_status_$pg.csv" ] || continue
    awk -F'\t' -v t="$t" 'FILENAME == ARGV[1] { nm[$1] = $2; next } $1 == t && ($2 in nm) { n++; out = out $2 "," nm[$2] "\n" }
      END { if (n) printf "run,name\n%s", out }' "$W/runnames.tsv" "$W/tagruns.tsv" > "$W/csv/cdb_runnames_$pg.csv"
    [ -s "$W/csv/cdb_runnames_$pg.csv" ] || rm -f "$W/csv/cdb_runnames_$pg.csv"
  done < "$W/tagpage.tsv"
fi
# gaps.tsv: tag type status count first last ranges
# coverage.tsv: tag type own default nothing own% status default-runs nothing-runs
awk -F'\t' -v OFS='\t' '
  FILENAME == ARGV[1] { rng[$1 FS $2 FS $3] = $7; next }
  {
    n = $3 + $4 + $5; st = ($4 + $5 > 0) ? "WARN" : "OK"
    print $1, $2, $3, $4, $5, sprintf("%.1f%%", n ? 100 * $3 / n : 0), st, rng[$1 FS $2 FS "D"], rng[$1 FS $2 FS "-"]
  }' "$W/gaps.tsv" "$W/covcount.tsv" > "$W/coverage.tsv"
# named runs: "16-18, 21" -> "16 cosmics, 17 single particle, 18 single particle, 21 p+p ..." (runs of that tag only)
if [ -s "$W/runnames.tsv" ]; then
  awk -F'\t' -v OFS='\t' '
    function named(t, txt,   n, tok, i, ab, a, b, k, r, out) {
      n = split(txt, tok, /, /); out = ""
      for (i = 1; i <= n; i++) {
        if (tok[i] ~ /^[0-9]+(-[0-9]+)?$/ && split(tok[i], ab, "-") && (ab[1] in nm)) {
          a = ab[1]; b = (ab[2] == "" ? ab[1] : ab[2])
          for (k = 1; k <= nr[t]; k++) { r = R[t, k]; if (r + 0 >= a + 0 && r + 0 <= b + 0) out = out (out == "" ? "" : ", ") r ((r in nm) ? " " nm[r] : "") }
        } else out = out (out == "" ? "" : ", ") tok[i]
      }
      return out
    }
    FILENAME == ARGV[1] { nm[$1] = $2; next }
    FILENAME == ARGV[2] { nr[$1]++; R[$1, nr[$1]] = $2; next }
    { $8 = named($1, $8); $9 = named($1, $9); print }' "$W/runnames.tsv" "$W/tagruns.tsv" "$W/coverage.tsv" > "$W/cov.tmp" && mv "$W/cov.tmp" "$W/coverage.tsv"
fi
awk -F'\t' '{ n = $3 + $4 + $5
    if ($4 > 0) printf "coverage\t%s %s\tWARN\tdefault only: %d of %d runs: %s\n", $1, $2, $4, n, $8
    if ($5 > 0) printf "coverage\t%s %s\tWARN\tnothing (no payload, no default): %d of %d runs: %s\n", $1, $2, $5, n, $9 }' "$W/coverage.tsv" >> "$W/results.tsv"
NDEF=$(awk -F'\t' '$4 > 0' "$W/coverage.tsv" | wc -l | tr -d ' ')
NNOTH=$(awk -F'\t' '$5 > 0' "$W/coverage.tsv" | wc -l | tr -d ' ')
# problems first: most runs with nothing, then most default-only
sort -t"$TAB" -k7,7r -k5,5nr -k4,4nr "$W/coverage.tsv" > "$W/cov.tmp" && mv "$W/cov.tmp" "$W/coverage.tsv"
vlog "coverage: $NDEF (tag, payload) pairs with default-only runs, $NNOTH with runs that have nothing"

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
SUMMARY="$TAGLBL x $NPL payload types x $NRUNS runs, $NFILES payload files: $NDEF (tag, payload type) with default-only runs, $NNOTH with runs that have nothing, $NBAD bad files, $NRECENT new files in $FLOAT (last ${CDB_RECENT_DAYS}d)"
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

# ---- plots: drawn by checks/cdb/draw.sh from the CSVs (ROOT only, no sPHENIX libraries)
PLOT_WHY=
if [ "${CDB_PLOTS:-1}" != 1 ]; then PLOT_WHY="CDB_PLOTS=0"
elif ! command -v root >/dev/null 2>&1; then PLOT_WHY="ROOT not available"; fi
mkdir -p "$W/plots"
draw_plots() {  # draw_plots <csv...> -> $W/plots/*.pdf
  [ -z "$PLOT_WHY" ] || return 0
  "$SHIRT_HOME/checks/cdb/draw.sh" -o "$W/plots" "$@" >> "$W/root.log" 2>&1 \
    || result plots draw.sh WARN "drawing failed for some plots (see root.log)"
}
if [ -z "$PLOT_WHY" ]; then
  log "plots: drawing $(ls "$W/csv"/cdb_status_*.csv 2>/dev/null | wc -l | tr -d ' ') status plots"
  draw_plots "$W/csv"/cdb_status_*.csv
else vlog "plots: not drawn ($PLOT_WHY)"; fi

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
  awk -F'\t' -v t="$tag" '$1 == t' "$W/coverage.tsv" | cut -f2- > "$P.cov"                  # payload own default nothing own% status default-runs nothing-runs
  # the same with the detector in front, in detector order (problems first within a detector)
  DT="$W/det/$(tagsafe "$tag").tsv"
  awk -F'\t' -v OFS='\t' 'FILENAME == ARGV[1] { d[$1] = $2; o[$1] = $3; next } { print o[$1], NR, d[$1], $0 }' "$DT" "$P.cov" \
    | sort -t"$TAB" -k1,1n -k2,2n | cut -f3- > "$P.covd"
  ndrop=$(awk -F'\t' -v t="$tag" '$1 == t' "$W/dropped.tsv" | wc -l | tr -d ' ')
  dropdet=$(awk -F'\t' -v t="$tag" '$1 == t && !s[$3]++ { printf "%s%s", c, $3; c = ", " }' "$W/dropped.tsv")
  awk -F'\t' -v t="$tag" 'index("," $4 ",", "," t ",")' "$W/badfiles.tsv" > "$P.bad"
  awk -F'\t' -v t="$tag" 'index("," $4 ",", "," t ",")' "$W/shared.tsv" > "$P.shared"
  awk -F'\t' -v OFS='\t' -v t="$tag" '$2 == t { print $1, $3, $4, $5, $6 }' "$W/recent_all.tsv" > "$P.recent"
  awk -F'\t' -v t="$tag" '$1 == t' "$W/ages_all.tsv" | cut -f2- > "$P.ages"
  awk -F'\t' -v OFS='\t' -v t="$tag" '$2 == t { print $1, $3, $4, $5, $6, $7, $8 }' "$W/diff.tsv" > "$P.diff"
  awk -F'\t' -v t="$tag" '{ split($1, ab, " vs "); if (ab[1] == t || ab[2] == t) print }' "$W/compare.tsv" > "$P.cmp"

  # per-test status
  s_exist=OK; grep -qx "$tag" "$W/badtags.txt" && s_exist=FAIL
  s_cov=$(col_worst 6 "$P.cov")
  s_files=$(worst_status "$(col_worst 1 "$P.bad")" "$(col_worst 1 "$P.shared")")
  s_diff=$(col_worst 1 "$P.diff")
  st=$(worst_status "$s_exist" "$s_cov" "$s_files" "$s_diff")
  failed=; warned=
  for t in "exists:$s_exist" "coverage:$s_cov" "files:$s_files" "changes:$s_diff"; do
    case "${t#*:}" in FAIL) failed="$failed ${t%%:*}" ;; WARN) warned="$warned ${t%%:*}" ;; esac
  done

  # numbers for the card
  npl=$(wc -l < "$P.cov" | tr -d ' ')
  # cells (run x type): own payload a of b; default-only cd; nothing cn
  covab=$(awk -F'\t' '{ a += $2; b += $2 + $3 + $4 } END { print a + 0, b + 0 }' "$P.cov")
  covpct=$(echo "$covab" | awk '{ if ($2) printf "%.1f", 100 * $1 / $2; else print "-" }')
  cd=$(awk -F'\t' '{ s += $3 } END { print s + 0 }' "$P.cov"); cn=$(awk -F'\t' '{ s += $4 } END { print s + 0 }' "$P.cov")
  cdpct=$(echo "$cd ${covab#* }" | awk '{ if ($2) printf "%.1f", 100 * $1 / $2; else print "-" }')
  cnpct=$(echo "$cn ${covab#* }" | awk '{ if ($2) printf "%.1f", 100 * $1 / $2; else print "-" }')
  nfiles=$(awk -F'\t' -v t="$tag" '$1 == t { print $3 }' "$W/tag_urls.tsv" | sort -u | wc -l | tr -d ' ')
  nrecent=$(wc -l < "$P.recent" | tr -d ' ')
  last=$(awk -F'\t' -v t="$tag" '$1 == t { print $2 }' "$W/tag_last.tsv")
  if [ -n "$last" ]; then lastd=$(fmt_epoch "$last"); lastage=$(( (NOW - last) / 86400 )); else lastd="never"; lastage=; fi
  ndefp=$(awk -F'\t' '$3 > 0' "$P.cov" | wc -l | tr -d ' '); nnothp=$(awk -F'\t' '$4 > 0' "$P.cov" | wc -l | tr -d ' ')

  # page
  psum="$tag: own payload ${covpct}%, default only ${cdpct}%, nothing ${cnpct}% over $npl payload types x $tnr runs, $nfiles files, last updated $lastd"
  [ -n "$failed" ] && psum="$psum; FAILED:$failed"
  [ -n "$warned" ] && psum="$psum; WARN:$warned"
  printf '%s\n%s\n%s\n' "$st" "$psum" "$tag" > "$W/pages/$pn.summary"
  {
    [ -n "$grp" ] && h_p "Run group <b>$grp</b> of global tag <a href=\"@PAGES@/tag_$(tagsafe "$btag").html\"><b>$btag</b></a> (all run groups)."
    [ "$s_exist" = FAIL ] && { h_section "Global tag" FAIL; h_p "<b>$btag</b> does not exist in the CDB."; }
    [ "$btag" = "$FLOAT" ] && h_p "<b>$btag</b> is the floating tag: its changes are reported as INFO, a file overwritten in place as WARN."
    [ "$btag" != "$FLOAT" ] && h_p "<b>$btag</b> is treated as frozen: any change since the last report is a FAIL."
    h_p "Payload list: <code>$tpl</code>. Run list: <code>$trl</code> ($tnr runs, $(head -1 "$W/runs/$(tagsafe "$tag").txt") .. $(tail -1 "$W/runs/$(tagsafe "$tag").txt"))."
    if [ -s "$W/csv/cdb_runnames_$pn.csv" ]; then
      tail -n +2 "$W/csv/cdb_runnames_$pn.csv" | sed 's/,/\t/' > "$P.names"
      h_details "Run names <span class=\"mut\">($(wc -l < "$P.names" | tr -d ' ') of $tnr runs, from <code>$(basename "$CDB_RUN_NAMES_FILE")</code>)</span>"
      h_table "$P.names" "Run|Name" 0
      h_details_end
    fi

    h_section "Changes since last report" "$s_diff"
    if [ -z "$PREV" ]; then h_p "First snapshot stored; changes will be shown from the next report on."
    else h_table "$P.diff" "Status|Payload type|Change|Old|New|Runs|Run ranges" 1 300; fi

    h_section "Changes in the last $DAYS days" "$([ "$nrecent" -gt 0 ] && echo INFO || echo OK)"
    h_p "Payload files created in the last $DAYS days (file mtime; global tags carry no timestamps)."
    h_table "$P.recent" "File date|Payload type|File|Runs|Run ranges" 0 200

    h_details "Newest payload file per payload type <span class=\"mut\">($(wc -l < "$P.ages" | tr -d ' ') types)</span>"
    h_table "$P.ages" "Payload type|Distinct files|Newest file date|Age (days)|Newest file" 0
    h_details_end

    h_section "Coverage plots" "$s_cov"
    if ls "$W/plots/cdb_plots_${pn}"*.pdf >/dev/null 2>&1; then
      h_p "One set per detector: page 1 status per run, page 2 fraction of runs per status, page 3 which payload file each run gets."
      cut -f2 "$DT" | awk '!s[$0]++' | while read -r det; do
        pdf="cdb_plots_${pn}_$det.pdf"; [ -s "$W/plots/$pdf" ] || pdf="cdb_plots_$pn.pdf"
        [ -s "$W/plots/$pdf" ] || continue
        dst=$(awk -F'\t' -v d="$det" 'FILENAME == ARGV[1] { if ($2 == d) in_d[$1] = 1; next } ($1 in in_d) { print $6 }' "$DT" "$P.cov" | sort -u | tr '\n' ' ')
        h_details "$det <span class=\"mut\">($(awk -F'\t' -v d="$det" '$2 == d' "$DT" | wc -l | tr -d ' ') types)</span>" "$(worst_status OK $dst)"
        printf '<p><a href="@ATTACH@/%s">%s</a></p>\n' "$pdf" "$pdf"
        printf '<object class="pdf det" data="@ATTACH@/%s" type="application/pdf"><p><a href="@ATTACH@/%s">%s</a></p></object>\n' "$pdf" "$pdf" "$pdf"
        h_details_end
        [ "$pdf" = "cdb_plots_$pn.pdf" ] && break
      done
    else
      h_p "Not drawn${PLOT_WHY:+ ($PLOT_WHY)}. Draw them from this report's CSVs with <code>checks/cdb/draw.sh &lt;report dir&gt;</code>."
    fi
    h_p "Data: <a href=\"@ATTACH@/cdb_status_$pn.csv.gz\">cdb_status_$pn.csv.gz</a> (run x type: R own / D default / - nothing), <a href=\"@ATTACH@/cdb_fileid_$pn.csv.gz\">cdb_fileid_$pn.csv.gz</a> (run x type: file number), <a href=\"@ATTACH@/cdb_files_$pn.csv.gz\">cdb_files_$pn.csv.gz</a> (the numbered files), <a href=\"@ATTACH@/cdb_detectors_$pn.csv.gz\">cdb_detectors_$pn.csv.gz</a> (type -&gt; detector)$([ -s "$W/csv/cdb_runnames_$pn.csv" ] && printf ', <a href="@ATTACH@/cdb_runnames_%s.csv.gz">cdb_runnames_%s.csv.gz</a> (run names)' "$pn" "$pn")."

    h_details "Coverage table <span class=\"mut\">($npl payload types: $ndefp with default-only runs, $nnothp with runs that have nothing)</span>" "$s_cov"
    h_p "Per run and payload type: <b>own</b> payload, <b>default only</b> (no run payload, so CDBInterface falls back to <code>&lt;type&gt;_default</code>) or <b>nothing</b> (neither)."
    [ "$ndrop" -gt 0 ] && h_p "Not watched in this run group: $ndrop payload types of $dropdet (limited to other run groups in <code>$(basename "${CDB_DETECTORS_FILE:-detectors.txt}")</code>)."
    h_table "$P.covd" "Detector|Payload type|Own payload|Default only|Nothing|Own|Status|Default-only runs|Runs with nothing" 7
    h_details_end

    h_section "Payload files" "$s_files"
    h_p "Problem files (missing, empty, unreadable by ROOT):"
    h_table "$P.bad" "Status|File|Payload types|Tags|Runs|Problem" 1 200
    h_p "Files shared by several payload types:"
    h_table "$P.shared" "Status|File|Payload types|Tags|Runs" 1 100

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
    else printf '<div class="row">own payload %s%% &middot; default only %s%% &middot; nothing %s%%</div>\n<div class="row">%s payload types &middot; %s files</div>\n' "$covpct" "$cdpct" "$cnpct" "$npl" "$nfiles"; fi
    printf '<div class="row">checked %s: %s runs (%s), %s payload types (%s)</div>\n' "$SHIRT_STAMP" "$tnr" "$(basename "$trl")" "$npl" "$(basename -- "$tpl")"
    printf '</a>\n'
  } > "$SHIRT_STATE/cards/$pn.html"
  # numbers for the global tag's run-group summary, "-" = empty
  # (stamp st failed warned nrecent last own_cells all_cells npl nfiles nruns runlist summary default_cells nothing_cells)
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$SHIRT_STAMP" "$st" "$(f=$(echo $failed); echo "${f:--}")" "$(f=$(echo $warned); echo "${f:--}")" "$nrecent" \
    "${last:-0}" "${covab% *}" "${covab#* }" "$npl" "$nfiles" "$tnr" "$(basename "$trl")" "$psum" "$cd" "$cn" > "$SHIRT_STATE/cards/$pn.tsv"
  # per type for the global tag's fallback table: type nruns default nothing (list order)
  awk -F'\t' -v OFS='\t' -v t="$tag" '$1 == t { print $2, $3 + $4 + $5, $4, $5 }' "$W/covcount.tsv" > "$SHIRT_STATE/cards/$pn.fallback.tsv"
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
  # fallback table over the groups (as results/cdb_check_*/cdb_missing_default): csv for the plot, tsv for the page
  FB=$W/csv/cdb_fallback_$(tagsafe "$btag").csv
  cut -f1 "$G" | while read -r g; do
    f="$SHIRT_STATE/cards/tag_$(tagsafe "$btag:$g").fallback.tsv"; [ -s "$f" ] && awk -v OFS='\t' -v g="$g" '{ print g, $0 }' "$f"
  done > "$W/fbin.tsv"
  # types in detector order (detector of each type without run-group limits), mapping csv for the plot
  cut -f2 "$W/fbin.tsv" | awk '!s[$0]++' | det_map "" | awk -F'\t' -v OFS='\t' '{ print $3, NR, $1, $2 }' | sort -t"$TAB" -k1,1n -k2,2n | cut -f3,4 > "$W/fbdet.tsv"
  { echo "payload,detector"; tr '\t' ',' < "$W/fbdet.tsv"; } > "$W/csv/cdb_detectors_$(tagsafe "$btag").csv"
  awk -F'\t' -v OFS='\t' -v csv="$FB" -v tsv="$W/fb.tsv" '
    FILENAME == ARGV[1] { pl[++np] = $1; det[$1] = $2; next }
    { if (!($1 in gs)) { gs[$1] = 1; gl[++ng] = $1 } n[$1, $2] = $3; d[$1, $2] = $4; m[$1, $2] = $5 }
    END {
      h = "domain"; for (i = 1; i <= ng; i++) h = h "," gl[i] "_nruns," gl[i] "_default," gl[i] "_missing"; print h > csv
      printf "" > tsv
      for (j = 1; j <= np; j++) {
        c = pl[j]; r = det[pl[j]] "\t" pl[j]
        for (i = 1; i <= ng; i++) {
          k = gl[i] SUBSEP pl[j]
          if (k in n) { c = c "," n[k] "," d[k] "," m[k]; r = r "\t" (d[k] + m[k] == 0 ? "ok" : d[k] " / " m[k]) }
          else { c = c ",,,"; r = r "\t" "" }
        }
        print c > csv; print r > tsv
      }
    }' "$W/fbdet.tsv" "$W/fbin.tsv"
  fbhdr="Detector|Payload type"; for g in $(cut -f1 "$G"); do fbhdr="$fbhdr|$g ($(awk -F'\t' -v g="$g" '$1 == g { print $12 }' "$G") runs)"; done
  draw_plots "$FB"
  fbpdf="cdb_fallback_$(tagsafe "$btag").pdf"
  upd=$(awk -F'\t' '$6 > 0 { printf "%s%s", s, $1; s = ", " }' "$G")
  ngrp=$(wc -l < "$G" | tr -d ' ')
  nbadg=$(awk -F'\t' '$3 == "FAIL" || $3 == "WARN"' "$G" | wc -l | tr -d ' ')

  psum="$btag: $ngrp run groups, own payload ${covpct}%, last updated $lastd"
  [ "$nbadg" -gt 0 ] && psum="$psum; problems in $(awk -F'\t' '$3 == "FAIL" || $3 == "WARN" { printf "%s%s", s, $1; s = " " }' "$G")"
  printf '%s\n%s\n%s\n' "$st" "$psum" "$btag" > "$W/pages/$pn.summary"
  {
    [ "$btag" = "$FLOAT" ] && h_p "<b>$eb</b> is the floating tag: its changes are reported as INFO, a file overwritten in place as WARN."
    [ "$btag" != "$FLOAT" ] && h_p "<b>$eb</b> is treated as frozen: any change since the last report is a FAIL."
    h_p "Checked separately for each run group (own run list and payload list). Each group shows its latest check; open a group for its full report."
    printf '<div class="cards">\n'
    awk -v b="$btag:" 'index($0, b) == 1' "$W/groups.txt" | while read -r e; do f="$SHIRT_STATE/cards/tag_$(tagsafe "$e").html"; [ -f "$f" ] && cat "$f"; done
    printf '</div>\n'
    h_section "Runs without their own payload, per run group"
    h_p "Each cell: <b>default only / nothing</b> (out of the group's runs); <b>ok</b> = every run has its own payload; empty = not watched in that group. From each group's latest check."
    h_table "$W/fb.tsv" "$fbhdr" 0
    if [ -s "$W/plots/$fbpdf" ]; then
      printf '<object class="pdf short" data="@ATTACH@/%s" type="application/pdf"><p><a href="@ATTACH@/%s">%s</a></p></object>\n' "$fbpdf" "$fbpdf" "$fbpdf"
    fi
    h_p "Data: <a href=\"@ATTACH@/$(basename "$FB").gz\">$(basename "$FB").gz</a>"
    while IFS="$TAB" read -r g gstamp gst gfail gwarn gnrec glast ga gb gnpl gnf gnr grl gsum gcd gcn; do
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
    printf '<div class="row">own payload %s%% over all run groups</div>\n' "$covpct"
    printf '<div class="row">groups: %s</div>\n' "$(cut -f1 "$G" | tr '\n' ' ')"
    printf '</a>\n'
  } > "$SHIRT_STATE/cards/$pn.html"
  vlog "tag $btag: $st over $ngrp run groups (coverage $covpct%, last updated $lastd)"
done < "$W/grouped.txt"
rm -f "$W/grp.tsv" "$W/fb.tsv" "$W/fbin.tsv" "$W/fbdet.tsv"

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
for f in "$W/csv"/*.csv; do [ -f "$f" ] && gzip -c "$f" > "$A/$(basename "$f").gz"; done
for f in "$W/plots"/*.pdf; do [ -f "$f" ] && cp "$f" "$A/"; done
cp "$W/files.tsv" "$A/files.tsv"
[ -f "$W/root.log" ] && cp "$W/root.log" "$A/root.log"
finish "$SUMMARY"
