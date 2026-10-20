# CDB payload availability per running period (2026-10-20)

For every run of each period's run list and every payload type below, the CDB was asked for the run's payload
and for `<payload>_default`. Each run is then one of:

- **run payload**: the run has its own payload (it may still be one file shared by a whole run range);
- **default**: no run payload, so `CDBInterface` falls back to `<payload>_default`;
- **missing**: neither exists, so the reconstruction runs without that calibration.

Global tag `newcdbtag` (`ProdA_2024` returns the same payloads; the two Run 24 periods were looked up with
`ProdA_2024`, and a check on runs of all five periods gave identical answers). sPHENIX build ana.579.

| period | runs | run list |
|---|---|---|
| run24pp   | 1568 | Run 24 p+p calo-jet golden runs (47289-53864) |
| run24auau | 71   | Run 24 Au+Au golden runs (54749-54962) |
| run25auau | 2771 | Run 25 Au+Au golden runs (67597-78954) |
| run25oo   | 134  | Run 25 O+O golden runs (82388-82703) |
| run25pp   | 852  | Run 25 p+p: no golden run list; every run in 79143-82387 with a `pro001_pcdb001_v001` DST_CALOFITTING (79151-81668) |

These are the analysis run lists, not the ones in `config/runs/`. Runs also in the matching
`config/runs/<group>.goodruns.txt`: run24pp 1556 of 1568 (run2pp has 1773), run24auau 59 of 71 (run2auau 182),
run25auau 2756 of 2771 (run3auau 3141), run25oo 134 of 134 (run3oo 135), run25pp 845 of 852 (run3pp 974).

## Files

| file | content |
|---|---|
| `cdb_missing_default.txt` | **the table**: per payload type and period, `default / missing` run counts (`ok` = every run has a run payload) |
| `cdb_missing_default.csv` | the same, machine readable (`<period>_nruns`, `_default`, `_missing`) |
| `cdb_check_all_periods.pdf` | the per-run status grid of every period, one page each |
| `<period>/cdb_check.pdf` | p1 status grid (payload type vs run), p2 fraction of runs per status, p3 which payload file each run gets |
| `<period>/summary.txt` | per payload type: counts, the runs (as ranges) with default only or nothing, and the distinct payload files |
| `<period>/cdb_status.csv` | run x payload type: `R` (run payload), `D` (default), `-` (missing) |

The per-run payload file names (`cdb_payloads.csv`, 9 MB in total) are not included; they are on RCF in
`/sphenix/user/samfred/projects/cdb_check/periods/<period>/`, together with the scripts that made all of this
(`CheckRuns.C`, `Draw_CDBCheck.C`, `make_table.py`; the payload list is `../cdbtools/checkCDB.C`).

## Main findings

- `MBD_T0CORR` has no payload and no default for every Run 25 p+p and O+O run, and for 198 Run 24 p+p
  (48900-49652, 52844), 6 Run 24 Au+Au and 310 Run 25 Au+Au runs.
- Run 25 p+p: `MBD_QFIT`, the HCal calibrations and bad-tower maps and the three centrality payloads are default only
  for every run; 43 runs have only the default CEMC/HCal hot-tower and mean-time maps.
- The HCal bad-tower maps are default only in Run 24 (p+p and Au+Au); the HCal calibrations are default only in
  Run 25 Au+Au.
- The sEPD bad-tower map is missing everywhere; the sEPD event-plane calibration is missing everywhere except
  Run 24 Au+Au (28 of 71 missing) and Run 25 Au+Au (16 of 2771 missing).
- Run 25 p+p runs 79151-79152 get the Au+Au-era MBD `TT_T0`, `TQ_T0` and slewing payloads; from 79153 on they
  get the p+p ones.
