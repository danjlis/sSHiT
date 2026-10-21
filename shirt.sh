#!/usr/bin/env bash
# shirt.sh -- sPHENIX calorimeter software health reports.
#
#   ./shirt.sh list                         list available checks
#   ./shirt.sh run <check|all> [options]    run check(s), publish HTML, notify
#
# options:
#   -c FILE      config file (default: shirt.conf next to this script)
#   --test       write to $SHIRT_TEST_WWW / $SHIRT_TEST_STATE, no notification
#   --out DIR    write pages to DIR instead of SHIRT_WWW_ROOT
#   --no-notify  skip the chat notification
#   --keep-work  keep the scratch directory (printed at the end)
#   -v, --verbose  stream the check's log and ROOT output to the terminal
#   any other --option VALUE is passed to the check, e.g. for cdb:
#     ./shirt.sh run cdb --test --tag newcdbtag --payload CEMC_calib [--runs runs.txt]
#
# A check is a directory checks/<name>/ with an executable check.sh. It runs with
# SHIRT_HOME SHIRT_CONF SHIRT_WORK SHIRT_STATE SHIRT_STAMP exported and must write
#   $SHIRT_WORK/results.tsv   section<TAB>item<TAB>status<TAB>message
#   $SHIRT_WORK/body.html     HTML fragment (may reference @ATTACH@/<file>)
#   $SHIRT_WORK/summary.txt   line 1: OK|INFO|WARN|FAIL, line 2: one-line summary
# and may put files in $SHIRT_WORK/attach/ to be published next to the report.
# Sub-pages: $SHIRT_WORK/pages/<name>.html (fragment) + <name>.summary (status, summary, title);
# link to them from body.html as @PAGES@/<name>.html.

set -o pipefail
SHIRT_HOME=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export SHIRT_HOME
. "$SHIRT_HOME/lib/common.sh"
. "$SHIRT_HOME/lib/report.sh"
. "$SHIRT_HOME/lib/notify.sh"

usage() { sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

list_checks() {
  local d
  for d in "$SHIRT_HOME"/checks/*/; do
    [ -x "$d/check.sh" ] && basename "$d"
  done
}

# one run per check at a time (e.g. several condor jobs): <state>/<check>/.lock holds "host pid".
# A lock left by a dead process on this host is removed; otherwise wait up to SHIRT_LOCK_WAIT seconds.
LOCK=
take_lock() {
  local l=$1 waited=0 owner
  while ! mkdir "$l" 2>/dev/null; do
    owner=$(cat "$l/owner" 2>/dev/null)
    if [ "${owner%% *}" = "$(hostname)" ] && ! kill -0 "${owner#* }" 2>/dev/null; then
      log "removing stale lock $l ($owner)"; rm -rf "$l"; continue
    fi
    [ "$waited" -ge "${SHIRT_LOCK_WAIT:-14400}" ] && die "gave up waiting for $l (held by $owner)"
    [ $((waited % 600)) -eq 0 ] && log "waiting for $l (held by ${owner:-?})"
    sleep 30; waited=$((waited + 30))
  done
  echo "$(hostname) $$" > "$l/owner"
  LOCK=$l
}
drop_lock() { [ -n "$LOCK" ] && rm -rf "$LOCK"; LOCK=; }

# run_check <name>: run one check and publish it
run_check() {
  local name=$1
  local dir="$SHIRT_HOME/checks/$name"
  [ -x "$dir/check.sh" ] || die "no such check: $name (have: $(list_checks | tr '\n' ' '))"

  SHIRT_WORK=$(mktemp -d "${TMPDIR:-/tmp}/shirt.$name.XXXXXX")
  SHIRT_STATE="$STATE_ROOT/$name"
  export SHIRT_WORK SHIRT_STATE
  mkdir -p "$SHIRT_STATE" "$SHIRT_WORK/attach"
  : > "$SHIRT_WORK/results.tsv"
  take_lock "$SHIRT_STATE/.lock"
  SHIRT_STAMP=$(date +%Y-%m-%d_%H%M%S); export SHIRT_STAMP   # after the lock: waiting jobs get their own stamp

  log "running check '$name' (work: $SHIRT_WORK)"
  local t0=$SECONDS rc=0
  if [ -n "$SHIRT_VERBOSE" ]; then
    "$dir/check.sh" ${CHECK_ARGS[@]+"${CHECK_ARGS[@]}"} 2>&1 | tee "$SHIRT_WORK/check.log" >&2
    rc=${PIPESTATUS[0]}
  else
    "$dir/check.sh" ${CHECK_ARGS[@]+"${CHECK_ARGS[@]}"} > "$SHIRT_WORK/check.log" 2>&1 || rc=$?
  fi
  log "check '$name' finished rc=$rc in $((SECONDS - t0))s"

  local status summary
  if [ $rc -ne 0 ] || [ ! -s "$SHIRT_WORK/summary.txt" ]; then
    status=FAIL
    summary="check '$name' crashed (rc=$rc); see log"
    { h_section "Check crashed" FAIL; echo "<pre>"; tail -100 "$SHIRT_WORK/check.log" | html_escape; echo "</pre>"; } \
      >> "$SHIRT_WORK/body.html"
  else
    status=$(sed -n 1p "$SHIRT_WORK/summary.txt")
    summary=$(sed -n 2p "$SHIRT_WORK/summary.txt")
  fi
  cp "$SHIRT_WORK/check.log" "$SHIRT_WORK/attach/check.log"

  # publish: reports/<stamp>.html (+ reports/<stamp>/ attachments), index.html, history
  local out="$WWW_ROOT/$name"
  mkdir -p "$out/reports/$SHIRT_STAMP"
  cp -r "$SHIRT_WORK/attach/." "$out/reports/$SHIRT_STAMP/"
  page_wrap "$name" "$status" "$summary" "$SHIRT_WORK/body.html" "$out/reports/$SHIRT_STAMP.html" \
    "../../" "$SHIRT_STAMP" "../" "$SHIRT_STAMP"
  page_wrap "$name" "$status" "$summary" "$SHIRT_WORK/body.html" "$out/index.html" \
    "../" "reports/$SHIRT_STAMP" "" "pages"
  # sub-pages: archived next to the report's attachments, latest copies in <check>/pages/
  mkdir -p "$out/pages"   # not wiped: a partial run only replaces its own pages
  local f pn ptitle
  for f in "$SHIRT_WORK"/pages/*.html; do
    [ -f "$f" ] || continue
    pn=$(basename "$f" .html)
    ptitle="$name / $(sed -n 3p "${f%.html}.summary")"
    page_wrap "$ptitle" "$(sed -n 1p "${f%.html}.summary")" "$(sed -n 2p "${f%.html}.summary")" "$f" \
      "$out/reports/$SHIRT_STAMP/$pn.html" "../../../" "." "../../" "."
    page_wrap "$ptitle" "$(sed -n 1p "${f%.html}.summary")" "$(sed -n 2p "${f%.html}.summary")" "$f" \
      "$out/pages/$pn.html" "../../" "../reports/$SHIRT_STAMP" "../" "."
  done
  printf '%s\t%s\t%s\n' "$SHIRT_STAMP" "$status" "$summary" >> "$out/history.tsv"
  prune_reports "$out"
  history_page "$out" "$name"
  dashboard "$WWW_ROOT"
  log "$name: $status -- $summary"
  log "published $out/index.html"

  local link="$out/index.html"
  [ -n "$SHIRT_WWW_URL" ] && link="${SHIRT_WWW_URL%/}/$name/index.html"
  notify "$name" "$status" "$summary" "$link"

  drop_lock
  if [ -n "$KEEP_WORK" ]; then log "work dir kept: $SHIRT_WORK"; else rm -rf "$SHIRT_WORK"; fi
  OVERALL=$(worst_status "$OVERALL" "$status")
}

# keep the newest SHIRT_KEEP_REPORTS archived reports
prune_reports() {
  local out=$1 keep=${SHIRT_KEEP_REPORTS:-0} old
  [ "$keep" -gt 0 ] || return 0
  for old in $(ls "$out/reports" | grep '\.html$' | sort -r | tail -n +$((keep + 1))); do
    rm -rf "$out/reports/$old" "$out/reports/${old%.html}"
    log "pruned old report $old"
  done
}

# Ctrl-C: the check (same process group) gets SIGINT too and kills its ROOT job;
# here we just stop without publishing anything
interrupted() {
  trap - INT TERM
  log "interrupted -- nothing published"
  drop_lock
  [ -n "$SHIRT_WORK" ] && [ -z "$KEEP_WORK" ] && rm -rf "$SHIRT_WORK"
  exit 130
}
trap interrupted INT TERM

# ------------------------------------------------------------------ main
CMD=${1:-}; shift || true
case "$CMD" in
  list) list_checks; exit 0 ;;
  run) ;;
  -h|--help|help|"") usage 0 ;;
  *) usage 1 ;;
esac

TARGET=${1:-}; shift || true
[ -n "$TARGET" ] || usage 1
SHIRT_CONF="$SHIRT_HOME/shirt.conf"
TEST=; OUT=; KEEP_WORK=; SHIRT_NO_NOTIFY=; SHIRT_VERBOSE=; CHECK_ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    -c) SHIRT_CONF=$2; shift ;;
    --test) TEST=1 ;;
    --out) OUT=$2; shift ;;
    --no-notify) SHIRT_NO_NOTIFY=1 ;;
    --keep-work) KEEP_WORK=1 ;;
    -v|--verbose) SHIRT_VERBOSE=1 ;;
    --*) [ $# -ge 2 ] || usage 1; CHECK_ARGS+=("$1" "$2"); shift ;;
    *) usage 1 ;;
  esac
  shift
done
[ -f "$SHIRT_CONF" ] || die "config not found: $SHIRT_CONF"
SHIRT_CONF=$(cd "$(dirname "$SHIRT_CONF")" && pwd)/$(basename "$SHIRT_CONF")
. "$SHIRT_CONF"

WWW_ROOT=$SHIRT_WWW_ROOT; STATE_ROOT=$SHIRT_STATE_ROOT
if [ -n "$TEST" ]; then WWW_ROOT=$SHIRT_TEST_WWW; STATE_ROOT=$SHIRT_TEST_STATE; SHIRT_NO_NOTIFY=1; fi
[ -n "$OUT" ] && WWW_ROOT=$OUT
mkdir -p "$WWW_ROOT" "$STATE_ROOT" || die "cannot create $WWW_ROOT / $STATE_ROOT"

SHIRT_STAMP=$(date +%Y-%m-%d_%H%M%S)
SHIRT_VERSION=$(shirt_version)
export SHIRT_CONF SHIRT_STAMP SHIRT_NO_NOTIFY SHIRT_VERBOSE SHIRT_VERSION
vlog "shirt $SHIRT_VERSION, config $SHIRT_CONF, www $WWW_ROOT, state $STATE_ROOT${CHECK_ARGS[0]+, check args: ${CHECK_ARGS[*]}}"
OVERALL=OK

if [ "$TARGET" = all ]; then
  for c in $(list_checks); do run_check "$c"; done
else
  run_check "$TARGET"
fi
log "overall: $OVERALL"
[ "$OVERALL" = FAIL ] && exit 2
exit 0
