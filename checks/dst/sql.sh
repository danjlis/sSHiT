# sql.sh -- helpers for the dst scripts (sourced after lib/common.sh)

# sql_fill <sqlfile> [KEY=VALUE ...]: print the query with "-- comments" removed and @KEY@ replaced
sql_fill() {
  local f=$1; shift
  awk 'BEGIN { for (i = 2; i < ARGC; i++) { k = ARGV[i]; sub(/=.*/, "", k); v = ARGV[i]; sub(/^[^=]*=/, "", v); val["@" k "@"] = v; ARGV[i] = "" } }
    { sub(/--.*/, "") }
    /^[[:space:]]*$/ { next }
    { for (k in val) while ((i = index($0, k)) > 0) $0 = substr($0, 1, i - 1) val[k] substr($0, i + length(k)); print }' "$f" "$@"
}

# sql_run <dsn> <sqlfile> <out-tsv> [header] [KEY=VALUE ...]: run a read-only query via SqlQuery.C;
# ROOT output goes to $SQL_LOG (default stderr). Returns non-zero on error.
sql_run() {
  local dsn=$1 f=$2 out=$3 hdr=0 q rc
  shift 3
  case "$1" in 0|1) hdr=$1; shift ;; esac
  q=$(mktemp "${TMPDIR:-/tmp}/shirt_sql.XXXXXX")
  sql_fill "$f" "$@" > "$q"
  rm -f "$out"
  vlog "SQL ($dsn): $(tr '\n' ' ' < "$q" | tr -s ' ' | cut -c1-300)"
  run_root "$SHIRT_HOME/checks/dst/macros/SqlQuery.C(\"$dsn\",\"$q\",\"$out\",$hdr)" >> "${SQL_LOG:-/dev/stderr}" 2>&1
  rc=$?
  rm -f "$q"
  [ $rc -eq 0 ] && [ -f "$out" ]
}

# like_to_awk: an awk function turning a SQL LIKE pattern into an anchored regex (for awk programs)
LIKE_AWK='function like2re(p,   r, i, c) { r = "^"; for (i = 1; i <= length(p); i++) { c = substr(p, i, 1)
    if (c == "\\" && i < length(p)) { i++; c = substr(p, i, 1); r = r (index("^$.[]|()*+?{}\\/", c) ? "\\" c : c); continue }
    if (c == "%") r = r ".*"; else if (c == "_") r = r "."; else if (index("^$.[]|()*+?{}\\/", c)) r = r "\\" c; else r = r c }
  return r "$" }'
