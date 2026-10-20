#!/usr/bin/env bash
# dst check -- do the calorimeter DSTs exist for every good run of every run group?
#
#  runs       the good runs of every run group (groups from DST_RANGES_FILE) are read from
#             DST_GOODRUN_DIR/<group>.goodruns.txt, made by checks/dst/make_runlists.sh from the run DB
#  coverage   for every good run and expected DST type (DST_TYPES_FILE): present in the FileCatalog?
#             missing -> FAIL; segment gaps / too few events -> WARN; no disk copy, first
#             segment not transferred to disk, several production tags -> INFO
#  tags       production tag of every DST (FileCatalog) with its software build and CDB tag
#             (production_setup via production_status; else read from the tag name)
#  diff       per group, against that group's previous snapshot: DSTs that disappeared or lost
#             segments -> FAIL; appeared, no longer on disk, new production tag, runs (de)selected -> INFO
#
# options (passed through by shirt.sh, repeatable except --runs):
#   --group G      check only this run group
#   --type NAME    check only this DST type (NAME from the types list)
#   --runs FILE    use these runs (within each group's ranges) instead of the good-run lists
# With --type or --runs the per-group snapshot is not stored (it would be incomplete);
# with --runs there is no diff either.
#
# The SQL is in checks/dst/sql/*.sql (fit it to the schema with checks/dst/discover.sh).
# Testing without the FileCatalog: SHIRT_DST_MOCK_DIR with dsts.tsv (dsts.sql output) and
# optionally setups.tsv (setups.sql output).
set -o pipefail
. "$SHIRT_HOME/lib/common.sh"
. "$SHIRT_HOME/lib/report.sh"
. "$SHIRT_HOME/checks/dst/sql.sh"
. "$SHIRT_CONF"
trap on_interrupt INT TERM

W=$SHIRT_WORK
A=$W/attach
B=$W/body.html
SQLD=$SHIRT_HOME/checks/dst/sql
MOCK=$SHIRT_DST_MOCK_DIR
TAB=$(printf '\t')
NOW=$(date +%s)
: > "$B"
: > "$W/root.log"
SQL_LOG=$W/root.log

if [ -n "$SHIRT_VERBOSE" ]; then
  tail -n +1 -f "$W/root.log" >&2 &
  BG_PIDS="$BG_PIDS $!"
fi

finish() {  # finish <summary>
  local status
  if [ -n "$BG_PIDS" ]; then sleep 1; kill $BG_PIDS 2>/dev/null; fi
  status=$(results_worst)
  printf '%s\n%s\n' "$status" "$1" > "$W/summary.txt"
  [ -f "$W/results.tsv" ] && cp "$W/results.tsv" "$A/results.tsv"
  [ -f "$W/root.log" ] && cp "$W/root.log" "$A/root.log"
  exit 0
}
fail_page() {  # fail_page <title> <summary>: stop with the results table as the page
  { h_section "$1" FAIL; h_table "$W/results.tsv" "Section|Item|Status|Message" 3; } >> "$B"
  finish "$2"
}
gsafe() { printf '%s' "$1" | tr -c 'A-Za-z0-9_.-' '_'; }

# ------------------------------------------------------------------ options
OPT_GROUPS=; OPT_TYPES=; OPT_RUNS=
while [ $# -gt 0 ]; do
  case "$1" in
    --group) OPT_GROUPS="$OPT_GROUPS $2"; shift ;;
    --type) OPT_TYPES="$OPT_TYPES $2"; shift ;;
    --runs) OPT_RUNS=$2; case "$OPT_RUNS" in /*) ;; *) OPT_RUNS=$PWD/$OPT_RUNS ;; esac; shift ;;
    *) echo "dst: unknown option $1" >&2; exit 1 ;;
  esac
  shift
done
SUBSET=; [ -n "$OPT_GROUPS$OPT_TYPES$OPT_RUNS" ] && SUBSET=1
NOSNAP=; [ -n "$OPT_TYPES$OPT_RUNS" ] && NOSNAP=1

# ------------------------------------------------------------------ config
[ -s "$DST_RANGES_FILE" ] || { result config run_ranges FAIL "missing or empty: $DST_RANGES_FILE"; fail_page Configuration "configuration incomplete: $DST_RANGES_FILE"; }
[ -n "$OPT_RUNS" ] && [ ! -s "$OPT_RUNS" ] && { result config --runs FAIL "missing or empty: $OPT_RUNS"; fail_page Configuration "missing --runs file $OPT_RUNS"; }
# ranges.tsv: group first last minev minmin open   ("-" = default threshold, open = LAST was "+")
read_list "$DST_RANGES_FILE" | awk -v OFS='\t' '
  $2 !~ /^[0-9]+$/ || ($3 !~ /^[0-9]+$/ && $3 != "+") { print "BAD", $0; next }
  { print $1, $2, $3, ($4 == "" ? "-" : $4), ($5 == "" ? "-" : $5), ($3 == "+") }' > "$W/ranges.all"
grep '^BAD' "$W/ranges.all" | cut -f2 | while read -r l; do result config "run_ranges" FAIL "bad line (GROUP FIRST LAST|+): $l"; done
grep -v '^BAD' "$W/ranges.all" > "$W/ranges.tsv"
cut -f1 "$W/ranges.tsv" | awk '!seen[$0]++' > "$W/groups.all"
if [ -n "$OPT_GROUPS" ]; then
  for g in $OPT_GROUPS; do grep -qx "$g" "$W/groups.all" || result config "$g" FAIL "run group not in $DST_RANGES_FILE"; done
  printf '%s\n' $OPT_GROUPS | awk '!seen[$0]++' | grep -Fx -f "$W/groups.all" > "$W/groups.txt"
  awk -F'\t' 'FILENAME == ARGV[1] { g[$1] = 1; next } $1 in g' "$W/groups.txt" "$W/ranges.tsv" > "$W/r.tmp" && mv "$W/r.tmp" "$W/ranges.tsv"
else
  cp "$W/groups.all" "$W/groups.txt"
fi

# types.tsv: group name dsttype-like tag-like min-types   (config/dst/<group>.txt overrides the default list)
TYPEDIR=$(dirname "$DST_TYPES_FILE")
: > "$W/types.tsv"; : > "$W/group_types.tsv"
while read -r g; do
  tf=$DST_TYPES_FILE; [ -s "$TYPEDIR/$g.txt" ] && tf=$TYPEDIR/$g.txt
  if [ ! -s "$tf" ]; then result config "$g" FAIL "DST type list missing or empty: $tf"; continue; fi
  read_list "$tf" | awk -v OFS='\t' -v g="$g" -v only="$OPT_TYPES" '
    BEGIN { n = split(only, o, " "); for (i = 1; i <= n; i++) want[o[i]] = 1 }
    n && !($1 in want) { next }
    { print g, $1, $2, ($3 == "" ? "-" : $3), ($4 ~ /^[0-9]+$/ || $4 == "hosts" ? $4 : 1) }' >> "$W/types.tsv"
  printf '%s\t%s\n' "$g" "$tf" >> "$W/group_types.tsv"
done < "$W/groups.txt"
grep "'" "$W/types.tsv" | while IFS="$TAB" read -r g n p t m; do result config "$g $n" FAIL "quote in a pattern: $p $t"; done
[ -n "$OPT_TYPES" ] && for t in $OPT_TYPES; do cut -f2 "$W/types.tsv" | grep -qx "$t" || result config "$t" FAIL "DST type not in any selected group's list"; done
[ -s "$W/groups.txt" ] && [ -s "$W/types.tsv" ] || result config groups FAIL "nothing to check (no run group / DST type selected)"
awk -F'\t' '$1 == "config"' "$W/results.tsv" 2>/dev/null | grep -q . && fail_page Configuration "configuration problems, see the report"

NGROUPS=$(wc -l < "$W/groups.txt" | tr -d ' ')
log "dst: $NGROUPS run groups ($(tr '\n' ' ' < "$W/groups.txt")), $(cut -f2 "$W/types.tsv" | sort -u | wc -l | tr -d ' ') DST types${SUBSET:+ (subset run)}"
while IFS="$TAB" read -r g tf; do vlog "DST types for $g: $(awk -F'\t' -v g="$g" '$1 == g { printf "%s ", $2 }' "$W/types.tsv")from $tf"; done < "$W/group_types.tsv"

if [ -z "$MOCK" ]; then
  sphenix_env || { result setup root FAIL "ROOT / sPHENIX environment not available"; fail_page Setup "sPHENIX environment not available"; }
else
  log "MOCK mode: using $MOCK"
fi

# query <name> <dsn> <out> [KEY=VALUE...]: run checks/dst/sql/<name>.sql, or take <name>.tsv from the mock dir
query() {
  local name=$1 dsn=$2 out=$3
  shift 3
  if [ -n "$MOCK" ]; then cp "$MOCK/$name.tsv" "$out" 2>/dev/null || : > "$out"; return 0; fi
  sql_run "$dsn" "$SQLD/$name.sql" "$out" 0 "$@"
}

# ------------------------------------------------------------------ good runs
# good.tsv: group run events; lists/<g>.hdr: the list's "#" header (ranges, criteria, counts)
: > "$W/good.tsv"; mkdir -p "$W/good" "$W/lists"
while read -r g; do
  gs=$(gsafe "$g")
  if [ -n "$OPT_RUNS" ]; then
    read_list "$OPT_RUNS" | awk -F'\t' -v OFS='\t' -v g="$g" '
      FILENAME == ARGV[1] { if ($1 == g) { n++; a[n] = $2; b[n] = ($3 == "+" ? 1e12 : $3) } next }
      $1 ~ /^[0-9]+$/ { split($0, f, /[ \t]+/); for (i = 1; i <= n; i++) if (f[1] >= a[i] && f[1] <= b[i]) { print g, f[1], (f[2] ~ /^[0-9]+$/ ? f[2] : 0); break } }' "$W/ranges.tsv" - >> "$W/good.tsv"
    echo "# runs from $OPT_RUNS (--runs)" > "$W/lists/$gs.hdr"
    continue
  fi
  f=$DST_GOODRUN_DIR/$g.goodruns.txt
  if [ ! -f "$f" ]; then
    result config "$g" FAIL "no good-run list $f: run checks/dst/make_runlists.sh --group $g"; continue
  fi
  grep '^#' "$f" > "$W/lists/$gs.hdr"
  read_list "$f" | awk -v OFS='\t' -v g="$g" '$1 ~ /^[0-9]+$/ { print g, $1, ($2 ~ /^[0-9]+$/ ? $2 : 0) }' >> "$W/good.tsv"
done < "$W/groups.txt"
awk -F'\t' '$1 == "config"' "$W/results.tsv" 2>/dev/null | grep -q . && fail_page Configuration "good-run lists missing: run checks/dst/make_runlists.sh"
sort -t"$TAB" -k1,1 -k2,2n -u "$W/good.tsv" -o "$W/good.tsv"
cut -f2 "$W/good.tsv" | sort -n -u > "$W/goodall.txt"
while read -r g; do
  gs=$(gsafe "$g")
  awk -F'\t' -v g="$g" '$1 == g { print $2 }' "$W/good.tsv" > "$W/good/$gs.txt"
  n=$(wc -l < "$W/good/$gs.txt" | tr -d ' ')
  log "$g: $n good runs"
  [ "$n" -eq 0 ] && result selection "$g" WARN "the good-run list is empty"
done < "$W/groups.txt"

# ------------------------------------------------------------------ FileCatalog
# dstraw.tsv: group run dsttype tag nseg maxseg events bytes nseg_disk nseg_hpss seg0_disk
# setups.tsv: dsttype dstname build dbtag hash
: > "$W/dstraw.tsv"; : > "$W/setups.tsv"
while read -r g; do
  gs=$(gsafe "$g")
  [ -s "$W/good/$gs.txt" ] || continue
  first=$(head -1 "$W/good/$gs.txt"); last=$(tail -1 "$W/good/$gs.txt")
  filter=$(awk -F'\t' -v g="$g" '$1 == g { printf "%sd.dsttype LIKE '\''%s'\''", s, $3; s = " OR " }' "$W/types.tsv")
  log "FileCatalog: $g runs $first..$last"
  if query dsts "$DST_FC_DSN" "$W/q.tsv" FIRST="$first" LAST="$last" DSTFILTER="$filter"; then
    awk -F'\t' -v OFS='\t' -v g="$g" -v a="$first" -v b="$last" '$1 >= a && $1 <= b { print g, $0 }' "$W/q.tsv" >> "$W/dstraw.tsv"
  else
    result query "$g $first-$last" FAIL "FileCatalog query failed (see root.log)"
  fi
  if query setups "$DST_FC_DSN" "$W/q.tsv" FIRST="$first" LAST="$last"; then cat "$W/q.tsv" >> "$W/setups.tsv"
  else result query "$g $first-$last setups" INFO "production setup query failed (see root.log); build/CDB tag read from the tag names"; fi
done < "$W/groups.txt"
log "FileCatalog: $(wc -l < "$W/dstraw.tsv" | tr -d ' ') (run, dsttype, tag) rows"

# matched.tsv: group run name dsttype tag nseg maxseg events nseg_disk nseg_hpss seg0_disk   (good runs only)
awk -F'\t' -v OFS='\t' "$LIKE_AWK"'
  FILENAME == ARGV[1] { good[$1 FS $2] = 1; next }
  FILENAME == ARGV[2] { n[$1]++; nm[$1, n[$1]] = $2; dre[$1, n[$1]] = like2re($3); tre[$1, n[$1]] = ($4 == "-" ? "" : like2re($4)); next }
  !(($1 FS $2) in good) { next }
  { for (i = 1; i <= n[$1]; i++) if ($3 ~ dre[$1, i] && (tre[$1, i] == "" || $4 ~ tre[$1, i]))
      print $1, $2, nm[$1, i], $3, $4, $5, $6, $7, $9, $10, $11 + 0 }' "$W/good.tsv" "$W/types.tsv" "$W/dstraw.tsv" > "$W/matched.tsv"
# best.tsv: per (group, run, name, dsttype) the tag with the most segments (tie: last tag), + number of tags
sort -t"$TAB" -k1,1 -k2,2n -k3,3 -k4,4 -k6,6n -k5,5 "$W/matched.tsv" | awk -F'\t' -v OFS='\t' '
  { k = $1 FS $2 FS $3 FS $4 }
  k != pk { if (pk != "") print last, nt; nt = 0; pk = k }
  { nt++; last = $0 }
  END { if (pk != "") print last, nt }' > "$W/best.tsv"
# tagmap.tsv: tag cdbtag build source   (one line per production tag in use)
cut -f4,5 "$W/best.tsv" | sort -u | awk -F'\t' -v OFS='\t' '
  FILENAME == ARGV[1] { n++; sn[n] = $2; sb[n] = $3; sc[n] = $4; next }
  {
    for (i = 1; i <= n; i++) if (index(sn[i], $1) == 1 && index(sn[i], $2) > 0) {
      k = $2; if (!((k, sc[i]) in hc)) { hc[k, sc[i]] = 1; cdb[k] = (k in cdb) ? cdb[k] "/" sc[i] : sc[i] }
      if (!((k, sb[i]) in hb)) { hb[k, sb[i]] = 1; bld[k] = (k in bld) ? bld[k] "/" sb[i] : sb[i] }
    }
    seen[$2] = 1
  }
  END { for (t in seen) { if (t in cdb) print t, cdb[t], bld[t], "production_setup"
      else { split(t, f, "_"); print t, (f[2] == "" ? "-" : f[2]), f[1], "tag name" } } }' "$W/setups.tsv" - | sort > "$W/tagmap.tsv"
vlog "production tags: $(cut -f1 "$W/tagmap.tsv" | tr '\n' ' ')"

# cells.tsv: group run name status text missing gap lowev hpss multi nseg disk seg0 tags
#   seg0: first segment on disk for every matched dsttype; tags: production tag(s) used ("+"-joined)
# MIN_TYPES "hosts": one dsttype ending in each DST_CALO_HOSTS name (others ignored), missing ones named
awk -F'\t' -v OFS='\t' -v frac="${DST_MIN_EVENT_FRAC:-0}" -v hosts="$DST_CALO_HOSTS" '
  function host_of(d,   i) { for (i = 1; i <= nh; i++) if (length(d) >= length(H[i]) && substr(d, length(d) - length(H[i]) + 1) == H[i]) return H[i]; return "" }
  BEGIN { nh = split(hosts, H, " ") }
  FILENAME == ARGV[1] { nn[$1]++; nm[$1, nn[$1]] = $2; mt[$1, $2] = $5; next }
  FILENAME == ARGV[2] { runs[++nr] = $1 FS $2; rg[nr] = $1; rev[$1 FS $2] = $3; next }
  {
    k = $1 FS $2 FS $3
    if (mt[$1, $3] == "hosts") { h = host_of($4); if (h == "") next; hv[k, h] = 1 }
    ty[k]++; seg[k] += $6; ex[k] += $7 + 1; dsk[k] += ($9 > $6 ? $6 : $9); hp[k] += $10
    if (!(k in emin) || $8 + 0 < emin[k]) emin[k] = $8 + 0
    if ($12 > mtag[k]) mtag[k] = $12
    s0[k] += $11
    if (!((k, $5) in ht)) { ht[k, $5] = 1; tg[k] = (k in tg) ? tg[k] "+" $5 : $5 }
  }
  END {
    for (r = 1; r <= nr; r++) {
      g = rg[r]
      for (i = 1; i <= nn[g]; i++) {
        name = nm[g, i]; k = runs[r] FS name; mis = gap = low = hps = mul = 0; first = (k in ty) && s0[k] >= ty[k]
        if (!(k in ty)) { st = "FAIL"; txt = "missing"; mis = 1 }
        else if (mt[g, name] == "hosts" && ty[k] < nh) {
          txt = ""; for (j = 1; j <= nh; j++) if (!((k, H[j]) in hv)) txt = txt " " H[j]
          st = "FAIL"; txt = "missing" txt; mis = 1 }
        else if (mt[g, name] != "hosts" && ty[k] < mt[g, name]) { st = "FAIL"; txt = ty[k] "/" mt[g, name] " types"; mis = 1 }
        else {
          st = "OK"; txt = seg[k] (seg[k] < ex[k] ? "/" ex[k] : "") " seg"
          if (seg[k] < ex[k]) { st = "WARN"; gap = 1; txt = "gap " txt }
          if (frac > 0 && rev[runs[r]] > 0 && emin[k] < frac * rev[runs[r]]) { st = "WARN"; low = 1; txt = txt ", " emin[k] " ev" }
          if (dsk[k] == 0) { hps = 1; txt = txt (hp[k] > 0 ? ", HPSS only" : ", no disk copy"); if (st == "OK") st = "INFO" }
          else if (dsk[k] < seg[k]) txt = txt ", " dsk[k] " on disk"
          else txt = txt ", disk"
          if (mtag[k] > 1) { mul = 1; txt = txt ", " mtag[k] " tags"; if (st == "OK") st = "INFO" }
          if (!first && st == "OK") st = "INFO"
        }
        print runs[r], name, st, txt, mis, gap, low, hps, mul, seg[k] + 0, dsk[k] + 0, first, ((k in tg) ? tg[k] : "-")
      }
    }
  }' "$W/types.tsv" "$W/good.tsv" "$W/best.tsv" > "$W/cells.tsv"

# flags.tsv: group name problem nruns first last ranges
awk -F'\t' -v OFS='\t' '
  $6 { print $2, $1, $3, "missing" } $7 { print $2, $1, $3, "segment gaps" } $8 { print $2, $1, $3, "too few events" }
  $9 { print $2, $1, $3, "not on disk" } $10 { print $2, $1, $3, "several tags" }
  !$6 && !$13 { print $2, $1, $3, "first segment not on disk" }' "$W/cells.tsv" \
  | collapse "$W/goodall.txt" 12 > "$W/flags.tsv"
awk -F'\t' -v OFS='\t' '{
    st = ($3 == "missing") ? "FAIL" : ($3 == "segment gaps" || $3 == "too few events") ? "WARN" : "INFO"
    printf "dst\t%s %s\t%s\t%s: %d runs (%s)\n", $1, $2, st, $3, $4, $7 }' "$W/flags.tsv" >> "$W/results.tsv"
# prodtags.tsv: group name tag cdbtag build source nruns ranges   (runs per production tag)
awk -F'\t' -v OFS='\t' '!$6 { print $2, $1, $3, $14 }' "$W/cells.tsv" | collapse "$W/goodall.txt" 10 \
  | awk -F'\t' -v OFS='\t' 'FILENAME == ARGV[1] { c[$1] = $2; b[$1] = $3; src[$1] = $4; next }
      { n = split($3, t, "+"); cc = bb = ""; for (i = 1; i <= n; i++) { cc = cc (i > 1 ? "+" : "") (t[i] in c ? c[t[i]] : "-"); bb = bb (i > 1 ? "+" : "") (t[i] in b ? b[t[i]] : "-") }
        print $1, $2, $3, cc, bb, (t[1] in src ? src[t[1]] : "-"), $4, $7 }' "$W/tagmap.tsv" - | sort -t"$TAB" -k1,1 -k2,2 -k7,7nr > "$W/prodtags.tsv"
# gstats.tsv: group name pattern good with-dst coverage missing gaps lowev hpss multi seg0-on-disk status
awk -F'\t' -v OFS='\t' '
  FILENAME == ARGV[1] { o[++n] = $1 FS $2; pat[$1 FS $2] = $3 ($4 == "-" ? "" : " tag " $4) ($5 == "hosts" ? " (one per calo host)" : $5 > 1 ? " (" $5 " types)" : ""); next }
  { k = $1 FS $3; c[k]++; if (!$6) w[k]++; m[k] += $6; gp[k] += $7; lo[k] += $8; h[k] += $9; mu[k] += $10; f0[k] += $13 }
  END { for (i = 1; i <= n; i++) { k = o[i]; split(k, f, FS)
      st = m[k] ? "FAIL" : (gp[k] || lo[k]) ? "WARN" : (h[k] || mu[k] || f0[k] < w[k]) ? "INFO" : "OK"
      printf "%s\t%s\t%s\t%d\t%d\t%s\t%d\t%d\t%d\t%d\t%d\t%d\t%s\n", f[1], f[2], pat[k], c[k], w[k], c[k] ? sprintf("%.1f%%", 100 * w[k] / c[k]) : "-", m[k], gp[k], lo[k], h[k], mu[k], f0[k], st } }' \
  "$W/types.tsv" "$W/cells.tsv" > "$W/gstats.tsv"

# ------------------------------------------------------------------ per-group snapshot diff
# snapshot: run name present nseg disk tags; good runs as "run *GOOD* 1 0 0 -"
: > "$W/diff.tsv"; : > "$W/hadprev.txt"
NDIFF=0
while read -r g; do
  gs=$(gsafe "$g"); SD=$SHIRT_STATE/snapshots/$gs
  mkdir -p "$SD"
  { awk -F'\t' -v OFS='\t' -v g="$g" '$1 == g { print $2, $3, ($6 ? 0 : 1), $11, $12, $14 }' "$W/cells.tsv"
    awk -v OFS='\t' '{ print $1, "*GOOD*", 1, 0, 0, "-" }' "$W/good/$gs.txt"; } > "$W/snap_$gs.tsv"
  gzip -c "$W/snap_$gs.tsv" > "$A/snapshot_$gs.tsv.gz"
  prev=$(ls "$SD" 2>/dev/null | grep '\.tsv\.gz$' | sort | tail -1)
  [ -n "$OPT_RUNS" ] && prev=   # a hand-picked run list is not comparable with the real selection
  if [ -n "$prev" ]; then
    echo "$g" >> "$W/hadprev.txt"
    gzip -dc "$SD/$prev" > "$W/prev.tsv"
    awk -F'\t' -v OFS='\t' '
      FILENAME == ARGV[1] { if ($2 == "*GOOD*") og[$1] = 1; else { on[$2] = 1; o[$1 FS $2] = $3 FS $4 FS $5 FS $6 } next }
      { if ($2 == "*GOOD*") ng[$1] = 1; else { nn[$2] = 1; c[$1 FS $2] = $3 FS $4 FS $5 FS $6 } }
      END {
        for (r in og) if (!(r in ng)) print r, "-", "no longer a good run"
        for (r in ng) if (!(r in og)) print r, "-", "newly a good run"
        for (k in c) {
          split(k, f, FS); if (!((f[1] in og) && (f[1] in ng) && (f[2] in on) && (k in o))) continue
          split(o[k], a, FS); split(c[k], b, FS)
          if (a[1] == 1 && b[1] == 0) print f[1], f[2], "DST disappeared"
          else if (a[1] == 0 && b[1] == 1) print f[1], f[2], "DST appeared"
          else if (a[1] == 1 && b[2] < a[2]) print f[1], f[2], "segments lost"
          else if (a[1] == 1 && a[3] > 0 && b[3] == 0) print f[1], f[2], "no longer on disk"
          else if (a[1] == 1 && a[4] != "" && a[4] != b[4]) print f[1], f[2], "new production tag"
        }
      }' "$W/prev.tsv" "$W/snap_$gs.tsv" | collapse "$W/goodall.txt" 10 \
      | awk -F'\t' -v OFS='\t' -v g="$g" -v p="${prev%.tsv.gz}" '{
          st = ($2 == "DST disappeared" || $2 == "segments lost") ? "FAIL" : "INFO"
          print st, g, $1, $2, $3, $6, p }' >> "$W/diff.tsv"
    rm -f "$W/prev.tsv"
  fi
  if [ -z "$NOSNAP" ]; then cp "$A/snapshot_$gs.tsv.gz" "$SD/$SHIRT_STAMP.tsv.gz"; fi
done < "$W/groups.txt"
[ -n "$NOSNAP" ] && log "--type/--runs run: snapshots not stored"
# diff.tsv: status group name kind nruns ranges since
awk -F'\t' '{ printf "diff\t%s %s\t%s\t%s: %d runs (%s) since %s\n", $2, $3, $1, $4, $5, $6, $7 }' "$W/diff.tsv" >> "$W/results.tsv"
NDIFF=$(awk -F'\t' '{ s += $5 } END { print s + 0 }' "$W/diff.tsv")

# ------------------------------------------------------------------ pages + cards
mkdir -p "$W/pages" "$SHIRT_STATE/cards"
hdr() {  # hdr <group> <key>: value of "# key: ..." in the group's good-run list header (html-escaped)
  sed -n "s/^# $2: //p" "$W/lists/$(gsafe "$1").hdr" | head -1 | html_escape
}

while read -r g; do
  gs=$(gsafe "$g"); pn="grp_$gs"; P=$W/gp
  awk -F'\t' -v OFS='\t' -v g="$g" '$1 == g { print $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13 }' "$W/gstats.tsv" > "$P.stats"
  awk -F'\t' -v OFS='\t' -v g="$g" '$1 == g { print $2, $3, $4, $7 }' "$W/flags.tsv" > "$P.flags"
  awk -F'\t' -v OFS='\t' -v g="$g" '$1 == g { print $2, $3, $4, $5, $7, $8 }' "$W/prodtags.tsv" > "$P.tags"
  awk -F'\t' -v OFS='\t' -v g="$g" '$2 == g { print $1, $3, $4, $5, $6, $7 }' "$W/diff.tsv" > "$P.diff"
  if [ -z "$OPT_RUNS" ]; then cp "$DST_GOODRUN_DIR/$g.goodruns.txt" "$A/goodruns_$gs.txt"   # downloadable good-run list
  else cp "$W/good/$gs.txt" "$A/goodruns_$gs.txt"; fi
  # run x DST matrix: status run events cell...
  names=$(awk -F'\t' -v g="$g" '$1 == g { printf "%s ", $2 }' "$W/types.tsv")
  awk -F'\t' -v OFS='\t' -v g="$g" '
    FILENAME == ARGV[1] { if ($1 == g) ev[$2] = $3; next }
    FILENAME == ARGV[2] { if ($1 == g) nm[++n] = $2; next }
    $1 == g { c[$2, $3] = $5; s[$2, $3] = $4; f[$2, $3] = $13; if (!($2 in seen)) { seen[$2] = 1; r[++nr] = $2 } }
    END { for (i = 1; i <= nr; i++) { w = "OK"; line = ""
        for (j = 1; j <= n; j++) { x = s[r[i], nm[j]]
          if (x == "FAIL" || (x == "WARN" && w != "FAIL") || (x == "INFO" && (w == "OK"))) w = x
          line = line "\t" c[r[i], nm[j]] "\t" (f[r[i], nm[j]] ? "\342\234\223" : "\342\234\227") }
        print w, r[i], ev[r[i]] line } }' "$W/good.tsv" "$W/types.tsv" "$W/cells.tsv" > "$A/matrix_$gs.tsv"
  awk -F'\t' '$1 != "OK"' "$A/matrix_$gs.tsv" | sort -t"$TAB" -k2,2n > "$P.mx"

  st=$(worst_status OK $(awk -F'\t' -v g="$g" 'index($2, g " ") == 1 { print $3 }' "$W/results.tsv"))   # dst/diff/query/selection results of this group
  ngood=$(wc -l < "$W/good/$gs.txt" | tr -d ' ')
  gfirst=$(head -1 "$W/good/$gs.txt"); glast=$(tail -1 "$W/good/$gs.txt")
  grng="${gfirst:--}&ndash;${glast:--}"
  rng=$(hdr "$g" ranges); rng=${rng:--}
  cov=$(awk -F'\t' '{ printf "%s%s %s", s, $1, $5; s = ", " }' "$P.stats")
  psum="$g: $ngood good runs ($gfirst-$glast); DSTs present: $cov"
  printf '%s\n%s\n%s\n' "$st" "$psum" "$g" > "$W/pages/$pn.summary"
  {
    h_section "Good runs"
    h_p "<b>$ngood</b> good runs, $grng (run group range $rng). <a href=\"@ATTACH@/goodruns_$gs.txt\">Download the good-run list</a>."
    if [ -n "$OPT_RUNS" ]; then h_p "Runs from <code>$OPT_RUNS</code> (--runs), not the good-run list."
    else
      h_p "Good run: $(hdr "$g" criteria)."
      h_p "$(hdr "$g" counts). List <code>$DST_GOODRUN_DIR/$g.goodruns.txt</code> $(sed -n '1s/.*made by checks\/dst\/make_runlists.sh on \([^;]*\);.*/made \1/p' "$W/lists/$gs.hdr")."
    fi
    h_p "Expected DSTs: <code>$(awk -F'\t' -v g="$g" '$1 == g { print $2 }' "$W/group_types.tsv")</code>. Data: <a href=\"@ATTACH@/matrix_$gs.tsv\">run &times; DST matrix</a> (all good runs)."

    h_section "DST coverage of the good runs" "$(worst_status OK $(cut -f12 "$P.stats"))"
    h_table "$P.stats" "DST|Pattern|Good runs|With DST|Coverage|Missing|Segment gaps|Too few events|Not on disk|Several tags|1st segment on disk|Status" 12

    h_section "Production and CDB tags"
    h_p "Production tag (FileCatalog) used for the good runs, with the CDB tag and software build of that production$(awk -F'\t' -v g="$g" '$1 == g && $6 == "tag name" { f = 1 } END { if (f) printf " (read from the tag name where production_setup had no match)" }' "$W/prodtags.tsv"). A run with several tags uses the one with the most segments."
    h_table "$P.tags" "DST|Production tag|CDB tag|Build|Runs|Run ranges" 0 200

    h_section "Problem runs by DST"
    h_table "$P.flags" "DST|Problem|Runs|Run ranges" 0 300

    h_section "Runs with problems"
    h_p "Every good run with a missing or incomplete DST, not on disk, first segment not transferred, or with several production tags (cells: segments found[/expected], where the files are; 1st: first segment on disk &#10003; / &#10007;)."
    h_table "$P.mx" "Status|Run|Events|$(for n in $names; do printf '%s|1st|' "$n"; done | sed 's/|$//')" 1 500

    h_section "Changes since last report" "$(worst_status OK $(cut -f1 "$P.diff"))"
    if [ -n "$OPT_RUNS" ]; then h_p "Not compared: --runs run."
    elif grep -qx "$g" "$W/hadprev.txt"; then h_table "$P.diff" "Status|DST|Change|Runs|Run ranges|Since" 1 300
    else h_p "First snapshot stored; changes will be shown from the next report on."; fi

  } > "$W/pages/$pn.html"

  # card (kept in the state dir so a --group run only replaces its own)
  eg=$(printf '%s' "$g" | html_escape)
  {
    printf '<a class="card s-%s" href="@CHECK@reports/%s/%s.html">\n' "$st" "$SHIRT_STAMP" "$pn"
    printf '<div class="ct"><span>%s</span>%s</div>\n' "$eg" "$(h_badge "$st")"
    printf '<div class="row">runs %s</div>\n' "$rng"
    printf '<div class="row"><b>%s</b> good runs, %s</div>\n' "$ngood" "$grng"
    awk -F'\t' 'FILENAME == ARGV[1] { if (!($1 in tag)) { tag[$1] = $2; cdb[$1] = $3 } next }   # most-used tag first
      { x = ""; if ($6) x = x ", " $6 " missing"; if ($7) x = x ", " $7 " gaps"; if ($9) x = x ", " $9 " not on disk"
      if ($11 < $4) x = x ", 1st seg on disk " $11 "/" $4
      if (($1 in tag) && tag[$1] != "-") x = x " &middot; " tag[$1] (cdb[$1] != "-" ? " (CDB " cdb[$1] ")" : "")
      printf "<div class=\"row\">%s: <b>%s</b>%s</div>\n", $1, $5, x }' "$P.tags" "$P.stats"
    printf '<div class="row">'
    if awk -F'\t' '$12 == "FAIL" || $12 == "WARN" { f = 1 } END { exit !f }' "$P.stats"; then
      awk -F'\t' '$12 == "FAIL" { printf "<span class=\"chip\">%s</span>", $1 } $12 == "WARN" { printf "<span class=\"chip w\">%s</span>", $1 }' "$P.stats"
    else printf 'all DSTs present'; fi
    printf '</div>\n'
    printf '<div class="row">checked %s</div>\n' "$SHIRT_STAMP"
    printf '</a>\n'
  } > "$SHIRT_STATE/cards/$pn.html"
  vlog "$g: $st, $ngood good runs; $cov"
done < "$W/groups.txt"
rm -f "$W"/gp.*

# ------------------------------------------------------------------ index
NGOOD=$(wc -l < "$W/good.tsv" | tr -d ' ')
covsum=$(awk -F'\t' '{ w[$2] += $5; c[$2] += $4; m[$2] += $7; if (!($2 in s)) o[++n] = $2; s[$2] = 1 }
  END { for (i = 1; i <= n; i++) { k = o[i]; printf "%s%s %.1f%%%s", sep, k, c[k] ? 100 * w[k] / c[k] : 0, m[k] ? " (" m[k] " missing)" : ""; sep = ", " } }' "$W/gstats.tsv")
NGAP=$(awk -F'\t' '{ s += $8 } END { print s + 0 }' "$W/gstats.tsv")
NHPSS=$(awk -F'\t' '{ s += $10 } END { print s + 0 }' "$W/gstats.tsv")
SUMMARY="$NGROUPS run groups, $NGOOD good runs: $covsum; $NGAP runs with segment gaps, $NHPSS (run, DST) not on disk"
if [ -n "$SUBSET" ]; then
  lbl=; [ -n "$OPT_GROUPS" ] && lbl="group$OPT_GROUPS"
  [ -n "$OPT_TYPES" ] && lbl="${lbl:+$lbl, }type$OPT_TYPES"
  [ -n "$OPT_RUNS" ] && lbl="${lbl:+$lbl, }runs $(basename "$OPT_RUNS")"
  SUMMARY="[subset: $lbl] $SUMMARY"
fi
[ "$NDIFF" -gt 0 ] && SUMMARY="$SUMMARY, $NDIFF changes since the last report"
NQ=$(awk -F'\t' '$1 == "query"' "$W/results.tsv" 2>/dev/null | wc -l | tr -d ' ')
[ "$NQ" -gt 0 ] && SUMMARY="$NQ failed queries, $SUMMARY"

{ cat "$W/groups.txt"; cat "$W/groups.all"; } | awk '!seen[$0]++' > "$W/gorder.txt"
{
  printf '<p>Good runs from <code>%s/&lt;group&gt;.goodruns.txt</code> (checks/dst/make_runlists.sh). Raw data: <a href="@ATTACH@/results.tsv">results.tsv</a>, ' "$DST_GOODRUN_DIR"
  printf '<a href="@ATTACH@/dstraw.tsv.gz">FileCatalog rows</a>, <a href="@ATTACH@/check.log">log</a>, <a href="@ATTACH@/root.log">root.log</a></p>\n'
  h_section "Run groups"
  [ -n "$SUBSET" ] && h_p "This run checked only: $(tr '\n' ' ' < "$W/groups.txt")${OPT_TYPES:+(DST types:$OPT_TYPES)}. Other cards are from their last check."
  printf '<div class="cards">\n'
  while read -r g; do f="$SHIRT_STATE/cards/grp_$(gsafe "$g").html"; [ -f "$f" ] && cat "$f"; done < "$W/gorder.txt"
  printf '</div>\n'
  awk -F'\t' '$1 == "query" || $1 == "selection"' "$W/results.tsv" > "$W/r_q.tsv" 2>/dev/null
  if [ -s "$W/r_q.tsv" ]; then h_section "Query / selection problems" "$(worst_status OK $(cut -f3 "$W/r_q.tsv"))"; h_table "$W/r_q.tsv" "Section|Item|Status|Message" 3; fi
} >> "$B"

gzip -c "$W/dstraw.tsv" > "$A/dstraw.tsv.gz"
finish "$SUMMARY"
