# report.sh -- static HTML generation: body helpers for checks, page wrapper, history, dashboard.
# Body fragments may reference attached files as @ATTACH@/<file>, sub-pages as @PAGES@/<name>.html
# and the check directory as @CHECK@ (e.g. @CHECK@reports/<stamp>/x.html);
# the wrapper rewrites both per page.

# ------------------------------------------------------------------ body helpers (append to stdout)
h_badge() { printf '<span class="b b-%s">%s</span>' "$1" "$1"; }

h_section() {  # h_section <title> [status]
  printf '<h2>%s' "$1"
  [ -n "$2" ] && printf ' %s' "$(h_badge "$2")"
  printf '</h2>\n'
}

h_p() { printf '<p>%s</p>\n' "$*"; }

# h_table <tsv-file> <"Col A|Col B|..."> [status-column] [max-rows] [raw-html-columns "1,5"]
# Cells are HTML-escaped (except raw columns); the status column becomes a badge.
h_table() {
  local tsv=$1 header=$2 scol=${3:-0} max=${4:-0} raw=${5:-}
  if [ ! -s "$tsv" ]; then printf '<p class="none">none</p>\n'; return; fi
  awk -F'\t' -v header="$header" -v scol="$scol" -v max="$max" -v raw=",$raw," '
    function esc(s) { gsub(/&/,"\\&amp;",s); gsub(/</,"\\&lt;",s); gsub(/>/,"\\&gt;",s); return s }
    BEGIN {
      print "<div class=\"tw\"><table class=\"sortable\"><thead><tr>"
      n = split(header, h, "|"); for (i = 1; i <= n; i++) printf "<th>%s</th>", esc(h[i])
      print "</tr></thead><tbody>"
    }
    max > 0 && NR > max { more++; next }
    {
      printf "<tr>"
      for (i = 1; i <= NF; i++) {
        if (i == scol) printf "<td><span class=\"b b-%s\">%s</span></td>", $i, $i
        else if (index(raw, "," i ",")) printf "<td>%s</td>", $i
        else printf "<td>%s</td>", esc($i)
      }
      print "</tr>"
    }
    END {
      print "</tbody></table></div>"
      if (more) printf "<p class=\"none\">... %d more rows not shown (see raw data)</p>\n", more
    }' "$tsv"
}

# ------------------------------------------------------------------ page wrapper
_css() { cat <<'EOF'
<style>
:root{--bg:#fafafa;--fg:#1d1d1f;--mut:#6b6b70;--card:#fff;--line:#e2e2e6;--ok:#1e7d3a;--okb:#e3f4e8;--info:#1f5fa8;--infob:#e4eefa;--warn:#8a5a00;--warnb:#fdf1d6;--fail:#b3261e;--failb:#fbe3e1;--link:#1f5fa8}
@media (prefers-color-scheme:dark){:root{--bg:#141416;--fg:#e8e8ea;--mut:#9a9aa2;--card:#1d1d20;--line:#333338;--ok:#7fd99a;--okb:#16301e;--info:#8cbcf2;--infob:#152536;--warn:#f0c46a;--warnb:#33280f;--fail:#f29a92;--failb:#3a1714;--link:#8cbcf2}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:14px/1.45 -apple-system,"Segoe UI",Helvetica,Arial,sans-serif}
main{max-width:1200px;margin:0 auto;padding:16px}a{color:var(--link)}
header{display:flex;flex-wrap:wrap;gap:8px 16px;align-items:baseline;border-bottom:1px solid var(--line);padding-bottom:8px}
header h1{margin:0;font-size:22px}nav a{margin-right:12px}.mut{color:var(--mut)}
.summary{background:var(--card);border:1px solid var(--line);border-radius:8px;padding:12px 16px;margin:16px 0}
h2{font-size:17px;margin:28px 0 8px}h3{font-size:15px;margin:18px 0 6px}
.tw{overflow-x:auto;background:var(--card);border:1px solid var(--line);border-radius:8px}
.pdf{display:block;width:100%;height:85vh;border:1px solid var(--line);border-radius:8px;background:#fff}.pdf.short{height:60vh}.pdf.det{height:70vh}h3{font-size:15px;margin:18px 0 6px}
table{border-collapse:collapse;width:100%;font-size:13px}th,td{text-align:left;padding:5px 10px;border-bottom:1px solid var(--line);vertical-align:top}
td{font-family:ui-monospace,Menlo,Consolas,monospace;overflow-wrap:anywhere}th{cursor:pointer;user-select:none;white-space:nowrap;background:var(--card);position:sticky;top:0}
tr:last-child td{border-bottom:0}.none{color:var(--mut);font-style:italic}
.b{display:inline-block;padding:1px 7px;border-radius:9px;font:600 11px/1.6 -apple-system,Helvetica,sans-serif;letter-spacing:.03em}
.b-OK{color:var(--ok);background:var(--okb)}.b-INFO{color:var(--info);background:var(--infob)}.b-WARN{color:var(--warn);background:var(--warnb)}.b-FAIL{color:var(--fail);background:var(--failb)}
.cards{display:grid;grid-template-columns:repeat(auto-fill,minmax(260px,1fr));gap:12px;margin:10px 0}
.card{display:block;text-decoration:none;color:var(--fg);background:var(--card);border:1px solid var(--line);border-left:5px solid var(--mut);border-radius:8px;padding:10px 12px}
.card:hover{border-color:var(--link)}.card.s-OK{border-left-color:var(--ok)}.card.s-INFO{border-left-color:var(--info)}.card.s-WARN{border-left-color:var(--warn)}.card.s-FAIL{border-left-color:var(--fail)}
.card .ct{display:flex;justify-content:space-between;align-items:center;gap:8px;font-weight:600;font-size:15px;overflow-wrap:anywhere}
.card .row{font-size:12px;color:var(--mut);margin-top:5px}.card .row b{color:var(--fg);font-weight:600}
.dot{display:inline-block;width:8px;height:8px;border-radius:50%;margin-right:6px;border:1px solid var(--mut);vertical-align:0}.dot.on{background:var(--info);border-color:var(--info)}
.chip{display:inline-block;font:600 11px/1.6 -apple-system,Helvetica,sans-serif;padding:0 7px;border-radius:9px;margin:0 4px 0 0;color:var(--fail);background:var(--failb)}.chip.w{color:var(--warn);background:var(--warnb)}
.flt{font:600 10px/1.6 -apple-system,Helvetica,sans-serif;color:var(--info);border:1px solid var(--info);border-radius:9px;padding:0 6px;text-transform:uppercase;letter-spacing:.04em}
pre{background:var(--card);border:1px solid var(--line);border-radius:8px;padding:10px;overflow-x:auto;font-size:12px}
</style>
<script>
document.addEventListener('click',function(e){var th=e.target.closest('th');if(!th)return;var t=th.closest('table.sortable');if(!t)return;
var i=[].indexOf.call(th.parentNode.children,th),b=t.tBodies[0],r=[].slice.call(b.rows),d=th.dataset.d=th.dataset.d==='a'?'d':'a';
r.sort(function(x,y){var p=x.cells[i].textContent,q=y.cells[i].textContent,np=parseFloat(p),nq=parseFloat(q);
var c=(!isNaN(np)&&!isNaN(nq))?np-nq:p.localeCompare(q);return d==='a'?c:-c});r.forEach(function(x){b.appendChild(x)})});
</script>
EOF
}

# page_wrap <title> <status> <summary> <body-file> <out-file> <root-prefix> <attach-prefix> <check-prefix> [pages-prefix]
#   root-prefix  : relative path to SHIRT_WWW_ROOT from the page
#   check-prefix : relative path to the check directory from the page
page_wrap() {
  local title=$1 status=$2 summary=$3 body=$4 out=$5 root=$6 attach=$7 chk=$8 pages=${9:-.}
  {
    printf '<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">\n'
    printf '<title>shirt: %s</title>\n' "$title"
    _css
    printf '</head><body><main>\n<header><h1>shirt / %s</h1>%s<span class="mut">%s</span></header>\n' \
      "$title" "$(h_badge "$status")" "$SHIRT_STAMP"
    printf '<nav><a href="%sindex.html">dashboard</a><a href="%sindex.html">latest</a><a href="%shistory.html">history</a></nav>\n' "$root" "$chk" "$chk"
    printf '<div class="summary">%s</div>\n' "$(printf '%s' "$summary" | html_escape)"
    sed -e "s#@ATTACH@#${attach}#g" -e "s#@PAGES@#${pages}#g" -e "s#@CHECK@#${chk}#g" "$body"
    printf '<p class="mut">generated by shirt %s on %s as %s</p>\n</main></body></html>\n' "${SHIRT_VERSION:-$(shirt_version)}" "$(hostname)" "$USER"
  } > "$out"
}

# history_page <check-dir> <check-name>   (reads <check-dir>/history.tsv: stamp status summary)
history_page() {
  local dir=$1 name=$2 tmp
  tmp=$(mktemp)
  awk -F'\t' '{ print "<a href=\"reports/" $1 ".html\">" $1 "</a>\t" $2 "\t" $3 }' "$dir/history.tsv" \
    | sort -r > "$tmp.tsv"
  {
    h_section "Report history"
    h_table "$tmp.tsv" "Report|Status|Summary" 2 0 1
  } > "$tmp"
  local last_status last_summary
  last_status=$(tail -1 "$dir/history.tsv" | cut -f2)
  last_summary=$(tail -1 "$dir/history.tsv" | cut -f3)
  page_wrap "$name history" "$last_status" "$last_summary" "$tmp" "$dir/history.html" "../" "reports" ""
  rm -f "$tmp" "$tmp.tsv"
}

# dashboard <www-root>: one row per check from the last line of each history.tsv
dashboard() {
  local root=$1 tmp d name
  tmp=$(mktemp)
  : > "$tmp.tsv"
  local worst=OK
  for d in "$root"/*/; do
    [ -f "$d/history.tsv" ] || continue
    name=$(basename "$d")
    tail -1 "$d/history.tsv" | awk -F'\t' -v n="$name" \
      '{ print "<a href=\"" n "/index.html\">" n "</a>\t" $2 "\t" $1 "\t" $3 "\t<a href=\"" n "/history.html\">history</a>" }' >> "$tmp.tsv"
    worst=$(worst_status "$worst" "$(tail -1 "$d/history.tsv" | cut -f2)")
  done
  {
    h_section "Checks"
    h_table "$tmp.tsv" "Check|Status|Last run|Summary|" 2 0 1,5
    h_p "Calorimeter software health: calibrations DB (cdb), code (git), data products (dst)."
  } > "$tmp"
  page_wrap "dashboard" "$worst" "Latest status of every shirt check." "$tmp" "$root/index.html" "" "" ""
  rm -f "$tmp" "$tmp.tsv"
}
