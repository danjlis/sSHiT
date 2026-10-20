#!/usr/bin/env bash
# tests/run.sh [-v] [cdb|dst ...] -- run the checks on the fake data in tests/fixtures and check
# the results. Needs no run DB, FileCatalog, CDB or ROOT, so it works on a laptop and on RCF.
# Run it before every push. Reports go to tests/out/www (open tests/out/www/index.html);
# -v prints the check logs.
#
# fixtures/cdb  CdbScan.C output (scan.tsv, @FILES@ = fixtures/cdb/files), ListCdb.C output
#               (listing.txt), and tag / payload / run lists (cfg/)
# fixtures/dst  runs.sql / dsts.sql / setups.sql / maxrun.sql output and the run ranges and
#               DST types (cfg/)
# A new feature gets a fixture row that exercises it and an expect line below.
set -o pipefail
SHIRT_HOME=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
FIX=$SHIRT_HOME/tests/fixtures
OUT=$SHIRT_HOME/tests/out
VERBOSE=
[ "$1" = -v ] && { VERBOSE=1; shift; }
WANT=${*:-cdb dst}
NPASS=0; NFAIL=0

pass() { NPASS=$((NPASS + 1)); echo "  ok    $*"; }
fail() { NFAIL=$((NFAIL + 1)); echo "  FAIL  $*"; }
# expect <description> <command...>: the command must succeed
expect() { local d=$1; shift; if "$@" >/dev/null 2>&1; then pass "$d"; else fail "$d"; fi; }
# has <file> <regex>: a line of file matches
has() { grep -Eq -- "$2" "$1"; }
not_has() { ! grep -Eq -- "$2" "$1"; }
# result <check> <section> <item regex> <status>: a line of the newest results.tsv of check
result() { awk -F'\t' -v s="$2" -v i="^($3)\$" -v st="$4" '$1 == s && $2 ~ i && $3 == st { f = 1 } END { exit !f }' "$(latest "$1")/results.tsv"; }
latest() { ls -d "$OUT/www/$1/reports/"*/ 2>/dev/null | tail -1; }
summary() { sed -n 's/.*<div class="summary">\(.*\)<\/div>.*/\1/p' "$OUT/www/$1/index.html"; }
# shirt <log> <args...>: run shirt.sh, keep its log, return its exit code
shirt() {
  local log=$1; shift
  "$SHIRT_HOME/shirt.sh" "$@" > "$OUT/$log.log" 2>&1; local rc=$?
  [ -n "$VERBOSE" ] && cat "$OUT/$log.log"
  return $rc
}

rm -rf "$OUT"; mkdir -p "$OUT"
cat > "$OUT/test.conf" <<EOF
. "\$SHIRT_HOME/shirt.conf"
SHIRT_WWW_ROOT=$OUT/www-production-must-stay-empty
SHIRT_STATE_ROOT=$OUT/state-production-must-stay-empty
SHIRT_TEST_WWW=$OUT/www
SHIRT_TEST_STATE=$OUT/state
SHIRT_WEBHOOK_URL=""
EOF

# ------------------------------------------------------------------ cdb
if [[ " $WANT " == *" cdb "* ]]; then
  echo "cdb check (fixtures/cdb)"
  C=$OUT/cdb; mkdir -p "$C"
  cp -R "$FIX/cdb/." "$C/"
  sed "s#@FILES@#$C/files#g" "$FIX/cdb/scan.tsv" > "$C/scan.tsv"
  # file mtimes decide "recent": a/a_copy/empty/zdc are old, b/c/hcal are new
  touch -t 202001010000 "$C/files/cemc_a.root" "$C/files/cemc_a_copy.root" "$C/files/empty.root" "$C/files/zdc.txt" "$C/files/hcal_default.txt"
  touch "$C/files/cemc_b.root" "$C/files/cemc_c.root" "$C/files/hcal.root"
  cat > "$OUT/cdb.conf" <<EOF
. "$OUT/test.conf"
CDB_TAGS_FILE=$C/cfg/global_tags.txt
CDB_PAYLOADS_FILE=$C/cfg/payloads.txt
CDB_GOODRUN_LIST=$C/cfg/goodruns.txt
CDB_COMPARE_PAIRS=("ProdA_2024:Frozen_v1")
CDB_DETECTORS_FILE=$C/cfg/detectors.txt
CDB_ROOT_CHECK=0
EOF
  SHIRT_CDB_MOCK_DIR=$C shirt cdb1 run cdb --test -c "$OUT/cdb.conf"; rc=$?
  [ -n "$VERBOSE" ] && echo "    exit $rc: $(summary cdb)"
  expect "first run exits 2 (FAIL)"                      test $rc = 2
  expect "summary counts"                                has "$OUT/www/cdb/index.html" '3 tags \(4 tags/run groups\) x 3 payload types x 10 runs, 7 payload files: 1 \(tag, payload type\) with default-only runs, 4 with runs that have nothing'
  expect "run2pp HCALIN: nothing at 1004 (WARN)"         has "$(latest cdb)/results.tsv" 'run2pp HCALIN_calib.WARN.nothing \(no payload, no default\): 1 of 5 runs: 1004$'
  expect "run3auau HCALIN: default only at 1007-1008"    has "$(latest cdb)/results.tsv" 'run3auau HCALIN_calib.WARN.default only: 2 of 5 runs: 1007-1008$'
  expect "MDC2: nothing at all runs (WARN)"              result cdb coverage 'MDC2 (CEMC|HCALIN|ZDC)_calib' WARN
  expect "coverage never FAILs"                          not_has "$(latest cdb)/results.tsv" '^coverage.*FAIL'
  expect "listed X_default is folded into X"             not_has "$(latest cdb)/results.tsv" 'HCALIN_calib_default'
  expect "status csv: types in list order, no _default"  sh -c "gzip -dc '$(latest cdb)/cdb_status_tag_ProdA_2024--run3auau.csv.gz' | head -1 | grep -qx 'run,CEMC_calib,HCALIN_calib,ZDC_calib'"
  expect "status csv: 1007 own / default"                sh -c "gzip -dc '$(latest cdb)/cdb_status_tag_ProdA_2024--run3auau.csv.gz' | grep -qx '1007,R,D,R'"
  expect "status csv: 1004 own / nothing"                sh -c "gzip -dc '$(latest cdb)/cdb_status_tag_ProdA_2024--run2pp.csv.gz' | grep -qx '1004,R,-'"
  expect "detector limited to run3auau: not in run2pp"   sh -c "gzip -dc '$(latest cdb)/cdb_status_tag_ProdA_2024--run2pp.csv.gz' | head -1 | grep -qx 'run,CEMC_calib,HCALIN_calib'"
  expect "  ... and the run2pp page says so"            has "$OUT/www/cdb/pages/tag_ProdA_2024--run2pp.html" 'Not watched in this run group: 1 payload types of Global'
  expect "detectors csv: type -> detector"               sh -c "gzip -dc '$(latest cdb)/cdb_detectors_tag_ProdA_2024--run3auau.csv.gz' | tr '\\n' ' ' | grep -qx 'payload,detector CEMC_calib,EMCAL HCALIN_calib,HCALIN ZDC_calib,Global '"
  expect "coverage table has the detector"               has "$OUT/www/cdb/pages/tag_ProdA_2024--run3auau.html" '<td>HCALIN</td><td>HCALIN_calib</td>'
  expect "fileid csv: file numbers per type (0 = none)"  sh -c "gzip -dc '$(latest cdb)/cdb_fileid_tag_ProdA_2024--run2pp.csv.gz' | grep -qx '1004,[0-9]*,0'"
  expect "files csv: the default file and its runs"      sh -c "gzip -dc '$(latest cdb)/cdb_files_tag_ProdA_2024--run3auau.csv.gz' | grep -q '^HCALIN_calib,[0-9]*,D,2,1007,1008,.*hcal_default.txt$'"
  expect "fallback csv over the run groups"              sh -c "gzip -dc '$(latest cdb)/cdb_fallback_ProdA_2024.csv.gz' | grep -qx 'HCALIN_calib,5,0,1,5,2,0'" && sh -c "gzip -dc '$(latest cdb)/cdb_fallback_ProdA_2024.csv.gz' | grep -qx 'ZDC_calib,,,,5,0,0'"
  expect "tag page: default / nothing table"             has "$OUT/www/cdb/pages/tag_ProdA_2024.html" '<td>HCALIN</td><td>HCALIN_calib</td><td>0 / 1</td><td>2 / 0</td>'
  if command -v root >/dev/null 2>&1; then
    expect "plots drawn per detector (ROOT found)"       test -s "$(latest cdb)/cdb_plots_tag_ProdA_2024--run3auau_HCALIN.pdf" -a -s "$(latest cdb)/cdb_plots_tag_ProdA_2024--run3auau_Global.pdf" -a -s "$(latest cdb)/cdb_fallback_ProdA_2024.pdf"
    expect "  ... no Global plot for run2pp"             test ! -e "$(latest cdb)/cdb_plots_tag_ProdA_2024--run2pp_Global.pdf" -a -s "$(latest cdb)/cdb_plots_tag_ProdA_2024--run2pp_EMCAL.pdf"
    expect "group page embeds one PDF per detector"      test "$(grep -c '<object class="pdf det" data="../reports/[^"]*/cdb_plots_tag_ProdA_2024--run3auau_' "$OUT/www/cdb/pages/tag_ProdA_2024--run3auau.html")" -eq 3
    expect "tag page embeds the fallback PDF"            has "$OUT/www/cdb/pages/tag_ProdA_2024.html" 'cdb_fallback_ProdA_2024.pdf'
    expect "no drawing errors"                           not_has "$(latest cdb)/results.tsv" '^plots'
    expect "draw.sh redraws from a published report"     "$SHIRT_HOME/checks/cdb/draw.sh" -o "$OUT/redraw" "$(latest cdb)"
    expect "  ... all plots"                             test "$(ls "$OUT/redraw"/*.pdf | wc -l)" -eq "$(ls "$(latest cdb)"/*.pdf | wc -l)"
  else
    echo "  (ROOT not found: plot drawing not tested)"
    expect "page says the plots were not drawn"          has "$OUT/www/cdb/pages/tag_ProdA_2024--run3auau.html" 'Not drawn \(ROOT not available\)'
  fi
  expect "missing payload file"                          has "$(latest cdb)/results.tsv" 'zdc_missing.txt.FAIL.file does not exist'
  expect "duplicate md5 found"                           result cdb sanity 'md5 [0-9a-f]+' INFO
  expect "3 recent files in the floating tag"            has "$OUT/www/cdb/index.html" '3 new files in ProdA_2024'
  expect "old files are not recent"                      not_has "$(latest cdb)/results.tsv" 'recent.*cemc_a'
  expect "first snapshot"                                has "$OUT/www/cdb/index.html" 'first snapshot'
  expect "page per tag and run group"                    test -s "$OUT/www/cdb/pages/tag_ProdA_2024--run3auau.html" -a -s "$OUT/www/cdb/pages/tag_ProdA_2024.html"
  expect "footer shows the shirt version"                has "$OUT/www/cdb/index.html" 'generated by shirt [^ ]+ on'

  # second report: a frozen tag changed (FAIL), the floating tag changed (INFO)
  awk -F'\t' -v OFS='\t' -v d="$C/files" '
    $1 == "Frozen_v1"  && $2 == 1003 && $3 == "ZDC_calib"  { $4 = d "/cemc_a.root" }
    $1 == "ProdA_2024" && $2 == 1003 && $3 == "CEMC_calib" { $4 = d "/cemc_c.root" }
    { print }' "$C/scan.tsv" > "$C/scan.new" && mv "$C/scan.new" "$C/scan.tsv"
  sleep 1
  SHIRT_CDB_MOCK_DIR=$C shirt cdb2 run cdb --test -c "$OUT/cdb.conf"; rc=$?
  expect "frozen tag change is a FAIL"                   result cdb diff 'Frozen_v1 ZDC_calib' FAIL
  expect "floating tag change is INFO"                   result cdb diff 'ProdA_2024:run2pp CEMC_calib' INFO
  expect "history has both reports"                      test "$(ls -d "$OUT/www/cdb/reports/"*/ | wc -l)" -eq 2
  SHIRT_CDB_MOCK_DIR=$C shirt cdb3 run cdb --test -c "$OUT/cdb.conf" --tag MDC2
  expect "--tag MDC2 keeps the other tags' cards"        has "$OUT/www/cdb/index.html" 'ProdA_2024'
  expect "--tag MDC2 is a subset run (no new snapshot)"  test "$(ls "$OUT/state/cdb/snapshots" | wc -l)" -eq 2
fi

# ------------------------------------------------------------------ dst
if [[ " $WANT " == *" dst "* ]]; then
  echo "dst check (fixtures/dst)"
  D=$OUT/dst; mkdir -p "$D"
  cp -R "$FIX/dst/." "$D/"
  cat > "$OUT/dst.conf" <<EOF
. "$OUT/test.conf"
DST_RANGES_FILE=$D/cfg/runs/run_ranges.txt
DST_TYPES_FILE=$D/cfg/dst/dst_types.txt
DST_GOODRUN_DIR=$D/cfg/runs
DST_CALO_HOSTS="seb00 seb01 seb16"
DST_RUNDB_UNLOGGED="seb16"
DST_MIN_EVENT_FRAC=0.5
EOF
  export SHIRT_DST_MOCK_DIR=$D
  shirt dst0 run dst --test -c "$OUT/dst.conf"; rc=$?
  expect "no good-run lists: FAIL telling what to run"   has "$OUT/www/dst/index.html" 'good-run lists missing: run checks/dst/make_runlists.sh'

  "$SHIRT_HOME/checks/dst/make_runlists.sh" -v -c "$OUT/dst.conf" > "$OUT/runlists.log" 2>&1; rc=$?
  [ -n "$VERBOSE" ] && cat "$OUT/runlists.log"
  R=$D/cfg/runs
  expect "make_runlists succeeds"                        test $rc = 0
  expect "run3auau: 24 good of 30"                       has "$R/run3auau.goodruns.txt" '^# counts: 31 run numbers in range, 30 in the run DB, 24 good$'
  expect "run3pp: 18 good of 18"                         has "$R/run3pp.goodruns.txt" '^# counts: 18 run numbers in range, 18 in the run DB, 18 good$'
  expect "run3oo: open range ends at the newest run"     has "$R/run3oo.goodruns.txt" '^# ranges: 82388-82403 \(newest run\)$'
  expect "run3oo: 10 good (own event threshold)"         has "$R/run3oo.goodruns.txt" '^# counts: .* 10 good$'
  expect "rejection reasons are counted"                 has "$OUT/runlists.log" 'rejected .*calo hosts missing'
  expect "invalid runs are rejected"                     has "$OUT/runlists.log" 'rejected .*marked invalid'
  expect "list lines are run<TAB>events"                 awk -F'\t' '!/^#/ && !($1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/) { exit 1 }' "$R/run3pp.goodruns.txt"

  sleep 1
  shirt dst1 run dst --test -c "$OUT/dst.conf"; rc=$?
  [ -n "$VERBOSE" ] && echo "    exit $rc: $(summary dst)"
  expect "first run exits 2 (FAIL)"                      test $rc = 2
  expect "summary counts"                                has "$OUT/www/dst/index.html" '3 run groups, 52 good runs: RAW_SEB 94.2% \(3 missing\), CALOFITTING 90.4% \(5 missing\), CALO 85.7% \(6 missing\)'
  expect "missing TRIGGERED (one host) -> FAIL"          has "$(latest dst)/results.tsv" 'run3auau RAW_SEB.FAIL.missing: 1 runs \(60320\)'
  expect "segment gaps -> WARN"                          has "$(latest dst)/results.tsv" 'run3auau CALOFITTING.WARN.segment gaps: 2 runs \(60315-60316\)'
  expect "too few events -> WARN"                        has "$(latest dst)/results.tsv" 'run3auau CALOFITTING.WARN.too few events: 1 runs \(60318\)'
  expect "not on disk -> INFO"                           has "$(latest dst)/results.tsv" 'run3auau CALOFITTING.INFO.not on disk: 4 runs \(60310-60313\)'
  expect "first segment not on disk -> INFO"             has "$(latest dst)/results.tsv" 'run3auau CALOFITTING.INFO.first segment not on disk: 5 runs \(60310-60314\)'
  expect "several production tags -> INFO"               has "$(latest dst)/results.tsv" 'run3auau CALOFITTING.INFO.several tags: 1 runs \(60322\)'
  expect "per-group DST list (run3oo) is used"           has "$(latest dst)/results.tsv" 'run3oo CALOFITTING.FAIL.missing: 4 runs'
  expect "run3pp is clean"                               not_has "$(latest dst)/results.tsv" 'run3pp.*(FAIL|WARN)'
  expect "group pages"                                   test -s "$OUT/www/dst/pages/grp_run3auau.html" -a -s "$OUT/www/dst/pages/grp_run3oo.html"
  expect "good-run list is downloadable"                 cmp -s "$(latest dst)/goodruns_run3pp.txt" "$R/run3pp.goodruns.txt"
  expect "page shows the criteria"                       has "$OUT/www/dst/pages/grp_run3pp.html" 'at least 100000 events'

  # second report: one CALOFITTING DST is gone
  awk -F'\t' '!($1 == 79150 && $2 == "DST_CALOFITTING")' "$D/dsts.tsv" > "$D/dsts.new" && mv "$D/dsts.new" "$D/dsts.tsv"
  sleep 1
  shirt dst2 run dst --test -c "$OUT/dst.conf"; rc=$?
  expect "a DST that disappeared is a FAIL"              has "$(latest dst)/results.tsv" 'run3pp CALOFITTING.FAIL.DST disappeared: 1 runs \(79150\)'
  shirt dst3 run dst --test -c "$OUT/dst.conf" --group run3pp
  expect "--group run3pp keeps the other groups' cards"  has "$OUT/www/dst/index.html" 'run3auau'
  expect "--group run3pp still reports the missing DST" has "$(latest dst)/results.tsv" 'run3pp CALOFITTING.FAIL.missing: 1 runs \(79150\)'
  unset SHIRT_DST_MOCK_DIR
fi

echo "production paths"
expect "nothing written to the production site/state"  test ! -e "$OUT/www-production-must-stay-empty" -a ! -e "$OUT/state-production-must-stay-empty"

echo
echo "$NPASS passed, $NFAIL failed  (reports: $OUT/www/index.html)"
[ "$NFAIL" = 0 ]
