# common.sh -- shared helpers for shirt.sh and the checks (bash 3.2+ compatible)

export LC_ALL=C   # stable sort/comm order

log()  { echo "[shirt $(date +%H:%M:%S)] $*" >&2; }
vlog() { [ -n "$SHIRT_VERBOSE" ] && log "$@"; return 0; }   # only with -v
die()  { log "ERROR: $*"; exit 1; }
# git version of the checkout ("a1b2c3d", "-dirty" = uncommitted changes), shown in report footers
shirt_version() { git -C "$SHIRT_HOME" describe --always --dirty 2>/dev/null || echo unknown; }

# ---- status handling: OK < INFO < WARN < FAIL
status_rank() {
  case "$1" in
    OK) echo 0 ;; INFO) echo 1 ;; WARN) echo 2 ;; FAIL) echo 3 ;; *) echo 3 ;;
  esac
}
worst_status() {  # worst_status S1 S2 ...
  local w=OK s
  for s in "$@"; do
    [ "$(status_rank "$s")" -gt "$(status_rank "$w")" ] && w=$s
  done
  echo "$w"
}

# results.tsv writer for checks: result <section> <item> <status> <message>
result() {
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$SHIRT_WORK/results.tsv"
}
# worst status present in results.tsv
results_worst() {
  [ -s "$SHIRT_WORK/results.tsv" ] || { echo OK; return; }
  worst_status $(cut -f3 "$SHIRT_WORK/results.tsv" | sort -u)
}

# read a list file: strip comments, whitespace, blank lines
read_list() { sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$1" | grep -v '^$'; }

# ---- portable file info (GNU coreutils on RCF, BSD on macOS)
if stat -c '%s' / >/dev/null 2>&1; then
  file_size_mtime() { stat -L -c '%s %Y' "$1" 2>/dev/null; }
  fmt_epoch() { date -d "@$1" '+%Y-%m-%d %H:%M'; }
else
  file_size_mtime() { stat -L -f '%z %m' "$1" 2>/dev/null; }
  fmt_epoch() { date -r "$1" '+%Y-%m-%d %H:%M'; }
fi
if command -v md5sum >/dev/null 2>&1; then
  file_md5() { md5sum "$1" 2>/dev/null | cut -d' ' -f1; }
else
  file_md5() { md5 -q "$1" 2>/dev/null; }
fi

# collapse <runs-file> <max-ranges>: stdin "run<TAB>key..." -> "key...<TAB>count<TAB>first<TAB>last<TAB>ranges"
# Runs adjacent in the good-run list (or numerically) are merged into one range.
collapse() {
  sort -t"$(printf '\t')" -k2 -k1,1n | awk -F'\t' -v OFS='\t' -v runsfile="$1" -v maxr="${2:-15}" '
    function adj(p, r) { return (r == p + 1) || ((p in idx) && (r in idx) && idx[r] == idx[p] + 1) }
    function seg(  s) { s = (rs == rp) ? rs : rs "-" rp; nr++; if (nr <= maxr) txt = (txt == "" ? s : txt ", " s) }
    function emit() { if (nr > maxr) txt = txt ", ... (+" nr - maxr " ranges)"; print key, cnt, first, last, txt }
    FILENAME == runsfile { idx[$1] = FNR; next }
    {
      r = $1; k = $0; sub(/^[^\t]*\t/, "", k)
      if (k != key) { if (started) { seg(); emit() } started = 1; key = k; cnt = 0; nr = 0; txt = ""; rs = r; rp = r; first = r }
      else if (adj(rp, r)) rp = r
      else { seg(); rs = r; rp = r }
      cnt++; last = r
    }
    END { if (started) { seg(); emit() } }' "$1" -
}

html_escape() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'; }

# ROOT installs its own SIGINT handler and exits normally after Ctrl-C, so the calling
# script would carry on. Run root in the background (async jobs ignore SIGINT) and let
# on_interrupt (trap it with: trap on_interrupt INT TERM) kill it.
ROOT_PID=
BG_PIDS=      # other helpers (e.g. verbose log followers) to kill on interrupt
run_root() {  # run_root <root args...>   (always -l -b -q)
  root -l -b -q "$@" &
  ROOT_PID=$!
  wait "$ROOT_PID"
  local rc=$?
  ROOT_PID=
  return $rc
}
on_interrupt() {
  trap - INT TERM
  log "interrupted"
  if [ -n "$ROOT_PID" ]; then
    kill -TERM "$ROOT_PID" 2>/dev/null
    sleep 1
    kill -KILL "$ROOT_PID" 2>/dev/null
  fi
  [ -n "$BG_PIDS" ] && kill $BG_PIDS 2>/dev/null
  exit 130
}

# make sure ROOT + sPHENIX libs are available
sphenix_env() {
  if ! command -v root >/dev/null 2>&1; then
    [ -n "$SHIRT_SPHENIX_SETUP" ] || return 1
    log "setting up sPHENIX env: $SHIRT_SPHENIX_SETUP"
  if [ -n "$SHIRT_VERBOSE" ]; then eval "$SHIRT_SPHENIX_SETUP" >&2; else eval "$SHIRT_SPHENIX_SETUP" >/dev/null 2>&1; fi
    command -v root >/dev/null 2>&1 || return 1
  fi
  # headers needed by sphenixnpc/SphenixClient.h (nopayloadclient, nlohmann/json)
  local d
  for d in "$OFFLINE_MAIN/include" "$OPT_SPHENIX/include"; do
    [ -d "$d" ] && case ":$ROOT_INCLUDE_PATH:" in *":$d:"*) ;; *) ROOT_INCLUDE_PATH=${ROOT_INCLUDE_PATH:+$ROOT_INCLUDE_PATH:}$d ;; esac
  done
  export ROOT_INCLUDE_PATH
  vlog "root: $(command -v root), OFFLINE_MAIN=$OFFLINE_MAIN"
  vlog "ROOT_INCLUDE_PATH=$ROOT_INCLUDE_PATH"
  return 0
}
