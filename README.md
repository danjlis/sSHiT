# shirt (sSHiT) — sPHENIX calorimeter software health reports

Runs health checks on the calorimeter calibrations (CDB), code (git) and data products (DST),
publishes static HTML to `/sphenix/WWW/dlis/shirt/` and optionally posts to Mattermost/Slack.

```
shirt.sh            driver: ./shirt.sh list | ./shirt.sh run <check|all> [--test] [-c conf] [--out DIR] [--no-notify] [--keep-work]
shirt.conf          shared settings (bash); personal ones in shirt.local.conf (not in git)
lib/                common.sh (helpers), report.sh (HTML), notify.sh (webhook hook)
checks/<name>/      one directory per check; check.sh is the entry point
config/             curated lists: global tags, payloads, run ranges, good-run lists, DST types
tests/              run.sh + fake data: runs every check without any database
condor/             condor_submit wrapper for long runs
```

Output layout (per check): `<www>/<check>/index.html` (latest), `history.html`,
`reports/<stamp>.html` + `reports/<stamp>/` (raw data), and `<www>/index.html` (dashboard).
Snapshots/caches live in `SHIRT_STATE_ROOT` (not web-visible). `--test` writes to `test_www/` and `test_state/`.
Every page footer shows the git commit that made it (`-dirty` = uncommitted changes).

## Getting started

On RCF (`sphnxuser*`), in your own space:

```bash
git clone <repo url> /sphenix/user/$USER/sSHiT && cd /sphenix/user/$USER/sSHiT
tests/run.sh                                  # ~10 s, no database needed; must end "0 failed"
./shirt.sh run dst --test --group run3pp      # real FileCatalog -> test_www/dst/index.html
./shirt.sh run cdb --test --tag MDC2          # real CDB, small tag
```

`--test` writes only into your checkout (`test_www/`, `test_state/`) and never notifies, so try anything.
For personal settings (another sPHENIX build, test output somewhere web-visible, a webhook) copy
`shirt.local.conf.example` to `shirt.local.conf`; it is read at the end of `shirt.conf` and is not in git.

The sPHENIX environment is set up by `SHIRT_SPHENIX_SETUP` when `root` is not already in `PATH`.
`tests/run.sh` needs only bash, awk and coreutils (it also runs on a Mac).

**Production** (no `--test`) writes the shared site `SHIRT_WWW_ROOT` and the shared state `SHIRT_STATE_ROOT`.
The state holds the snapshots the "changes since the last report" sections compare against, so production
runs always use that one site/state pair; it needs write access to both. A per-check lock keeps two
production runs of the same check from overlapping.

## Making changes

1. `git pull`, make a branch: `git switch -c my-change`.
2. Change the code. Mac or RCF both work; the checks are bash 3.2 + POSIX awk compatible (no `case` inside `$( )`,
   no gawk-only functions).
3. `tests/run.sh` — all must pass. A new feature gets a row in `tests/fixtures/` that triggers it and an
   `expect` line in `tests/run.sh`. `tests/run.sh -v` shows the check logs; the reports are in `tests/out/www/`.
4. On RCF: `./shirt.sh run <check> --test` against the real databases and look at `test_www/`.
5. Commit, push, open a pull request.

Data in `config/` is part of the repo: the good-run lists (`config/runs/*.goodruns.txt`) are fixed now that
data taking is over, so everyone's reports use the same runs. Change them only by rerunning
`checks/dst/make_runlists.sh` and commit the result with the reason in the commit message.

## CDB quick start (on RCF)

```bash
checks/cdb/dump_lists.sh          # writes config/{global_tags,payloads}{,.all}.txt from the live CDB
vi config/global_tags.txt config/payloads.txt   # delete what you don't want watched
# put a good-run list at config/goodruns.txt (or set CDB_GOODRUN_LIST)
./shirt.sh run cdb --test         # -> test_www/cdb/index.html, no notification
./shirt.sh run cdb                # -> /sphenix/WWW/dlis/shirt/cdb/
```

Each line of `config/global_tags.txt` is `TAG [runlist [payloadlist]]` (paths relative to `config/`
or absolute; `-` or a missing column = the default `CDB_GOODRUN_LIST` / `CDB_PAYLOADS_FILE`):

```
ProdA_2024   runs/prodA_2024.txt   payloads/prodA_calo.txt
MDC2         -                     payloads/mdc2_calo.txt
```

**Run groups.** `TAG:GROUP` checks one global tag with a run group's own lists. The tag's card on the index then
summarizes all its groups and links to a tag page showing each group's card and a header per group. Each header
links to that group's full page. The CDB is queried once per tag, over all its groups' runs:

```
ProdA_2024:run2pp     runs/run2pp.txt     payloads/prodA_calo.txt
ProdA_2024:run2auau   runs/run2auau.txt   payloads/prodA_calo.txt
ProdA_2024:run3auau   runs/run3auau.txt   payloads/prodA_calo.txt
ProdA_2024:run3pp     runs/run3pp.txt     payloads/prodA_calo.txt
ProdA_2024:run3oo     runs/run3oo.txt     payloads/prodA_calo.txt
MDC2                  runs/mdc2.txt       payloads/mdc2_calo.txt
```

`--tag ProdA_2024` checks all its groups and `--tag ProdA_2024:run3oo` checks just one. The other groups keep their last result.

Single tag: `./shirt.sh run cdb --tag MDC2` (uses MDC2's own lists; `--runs FILE` / `--payload TYPE` override). A single-tag
run only replaces that tag's card and page; the other cards stay from their last check.

**Default fallback.** A run without its own payload of type `X` falls back to `X_default` (as `CDBInterface` does).
For every watched type the check also looks up `X_default`, and each run is **own payload**, **default only** or
**nothing**. Both "default only" and "nothing" are WARN. An `X_default` listed next to `X` is folded into `X`'s row.

**Plots.** The check writes all the plot data as CSVs into the report, then `checks/cdb/draw.sh` draws them with
ROOT (`checks/cdb/plots/CdbPlots.C`); the PDFs are embedded in the pages:

| CSV (`reports/<stamp>/`, gzipped) | content | plot |
|---|---|---|
| `cdb_status_<page>.csv` | run x type: `R` own / `D` default / `-` nothing | status grid, status fractions |
| `cdb_fileid_<page>.csv` | run x type: number of the file the run gets (0 = nothing) | which file each run gets |
| `cdb_files_<page>.csv` | the numbered files: payload, id, R/D, runs, first, last, url | |
| `cdb_fallback_<tag>.csv` | per type and run group: runs, default only, nothing | tag page table |
| `cdb_detectors_<page or tag>.csv` | payload type -> detector, in detector order | the per-detector split |

**Per detector.** `config/payloads/detectors.txt` maps payload types to detectors (`DETECTOR [@group,...] pattern...`,
first match wins, unmatched types go to "Other"). The coverage tables get a detector column, each run-group page gets
one embedded plot set per detector (`cdb_plots_<page>_<DETECTOR>.pdf`, from `cdb_detectors_<page>.csv`), and the
tag page table and plot are grouped by detector. `@groups` limits a detector to those run groups: `Global`
(ZDC, centrality, event plane) is only watched for run2auau, run3auau and run3oo; the pp groups skip it entirely.

Redraw any report without rerunning the check: `checks/cdb/draw.sh [-o OUTDIR] <report dir or CSVs>`.
`CDB_PLOTS=0` turns drawing off; without ROOT the pages say the plots were not drawn and the CSVs are still there.
A new plot = a new function in `CdbPlots.C` that reads CSVs, and a line in `draw.sh`.

The CDB check is read-only (`CDBUtils::PayloadIOVs`, `listGlobalTags`, `listPayloadTypes`).
`CDB_FLOATING_TAG` (ProdA_2024) is the moving tag: its changes are reported; changes to any other tag FAIL.
File dates come from payload-file mtimes, since global tags have no timestamps.

## DST check (on RCF)

Two steps. The data taking is finished, so step 1 is normally done once:

1. **`checks/dst/make_runlists.sh [-v] [--group G]`** asks the run DB about every run number in each run group's
   ranges (`config/runs/run_ranges.txt`). It writes the good runs to `config/runs/<group>.goodruns.txt` (`run events`;
   the header records the ranges, criteria and counts). A **good run** is:
   - not marked invalid
   - run type `DST_RUNTYPE`
   - at least `DST_MIN_EVENTS` events and `DST_MIN_MINUTES` minutes
   - events from all `DST_CALO_HOSTS` (except `DST_RUNDB_UNLOGGED`, i.e. seb18, which the run DB doesn't log)

   The cdb check can use the same files as run lists.
2. **`./shirt.sh run dst`** reads those lists and asks the FileCatalog, for every good run, whether each DST type in
   `config/dst/dst_types.txt` exists (`config/dst/<group>.txt` overrides that list for a group):
   - **missing** → FAIL
   - **segment gaps** or too few events → WARN
   - **not on disk**, **first segment not transferred to disk** (✓/✗ per run) or **several production tags** → INFO

   Each group page shows:
   - the good-run criteria and stats, with a download link for the list
   - the production tag behind each DST, with its CDB tag and software build (`production_setup`; if no setup
     matches, both are read from the tag name `<build>_<cdbtag>_<version>`)

   Compared with the group's previous report:
   - a DST that disappeared or lost segments → FAIL
   - a new production tag or a changed good-run list → INFO

```bash
checks/dst/discover.sh                    # read-only schema dump -> config/dst_schema.txt
checks/dst/make_runlists.sh -v            # good-run lists (or: condor_submit ARGS="checks/dst/make_runlists.sh -v" condor/shirt.sub)
./shirt.sh run dst --test                 # all run groups
./shirt.sh run dst --test --group run3oo [--type CALOFITTING] [--runs runs.txt]
```

The SQL is in `checks/dst/sql/*.sql` and runs through `checks/dst/macros/SqlQuery.C` (ODBC, SELECT only).
Testing without the databases: see [Testing](#testing). Long runs: `condor/shirt.sub` (see its header).

## Adding a check

Create `checks/<name>/check.sh` (executable). It runs with `SHIRT_HOME SHIRT_CONF SHIRT_WORK SHIRT_STATE SHIRT_STAMP`
exported, can source `lib/common.sh` / `lib/report.sh`, and must write into `$SHIRT_WORK`:

- `results.tsv` — `section<TAB>item<TAB>status<TAB>message` (use `result ...`), status ∈ OK/INFO/WARN/FAIL
- `body.html` — HTML fragment (`h_section`, `h_table`, `h_p`); `@ATTACH@/file` links to files in `attach/`
- `summary.txt` — line 1 overall status, line 2 one-line summary
- optional sub-pages: `pages/<name>.html` (fragment) + `pages/<name>.summary` (status, summary, title);
  link them from `body.html` as `@PAGES@/<name>.html`. Published as `<check>/pages/<name>.html` (latest)
  and `reports/<stamp>/<name>.html` (archive). The cdb check uses this for one page per global tag.

Put its settings in `shirt.conf`; the driver handles archiving, history, dashboard and notification.

## Notifications

Set `SHIRT_WEBHOOK_URL` (Mattermost or Slack incoming webhook) and `SHIRT_NOTIFY_ON` (minimum status).
Empty URL = off. `SHIRT_WWW_URL` makes the message link to the public page.

## Testing

`tests/run.sh [-v] [cdb|dst]` runs the checks on the fake data in `tests/fixtures/` and checks their results
(coverage gaps, bad files, frozen-tag changes, good-run selection, missing DSTs, diffs between reports, ...).
It uses the mock modes of the checks, which you can also use by hand:

- `SHIRT_CDB_MOCK_DIR=<dir>`: the cdb check reads `<dir>/scan.tsv` (CdbScan.C format:
  `tag run payload url iov_start iov_end`) and `<dir>/listing.txt` instead of querying the CDB.
- `SHIRT_DST_MOCK_DIR=<dir>`: `make_runlists.sh` reads `maxrun.txt` and `runs.tsv`, the dst check
  `dsts.tsv` and `setups.tsv` (the outputs of `checks/dst/sql/*.sql`) instead of the databases.
