-- FileCatalog (DST_FC_DSN): one row per (run, dsttype, tag) in [@FIRST@, @LAST@] for the
-- watched DST types (@DSTFILTER@ = "d.dsttype LIKE '...' OR ..."), columns in this order:
--   runnumber  dsttype  tag  nseg  maxseg  events  bytes  nseg_disk  nseg_hpss  seg0_disk
-- nseg_disk / nseg_hpss: segments with a copy on disk (lustre, gpfs) / on HPSS
-- seg0_disk: 1 if the first segment (0) has a copy on disk, i.e. has been transferred
-- datasets.dsttype has no run-period suffix (DST_CALOFITTING, DST_TRIGGERED_EVENT_seb00, ...)
SELECT d.runnumber,
       d.dsttype,
       coalesce(d.tag, '-'),
       count(DISTINCT d.segment),
       max(d.segment),
       coalesce(sum(d.events), 0),
       coalesce(sum(d.size), 0),
       sum(CASE WHEN EXISTS (SELECT 1 FROM files f WHERE f.lfn = d.filename AND f.full_host_name <> 'hpss') THEN 1 ELSE 0 END),
       sum(CASE WHEN EXISTS (SELECT 1 FROM files f WHERE f.lfn = d.filename AND f.full_host_name = 'hpss') THEN 1 ELSE 0 END),
       max(CASE WHEN d.segment = 0 AND EXISTS (SELECT 1 FROM files f WHERE f.lfn = d.filename AND f.full_host_name <> 'hpss') THEN 1 ELSE 0 END)
FROM datasets d
WHERE d.runnumber BETWEEN @FIRST@ AND @LAST@
  AND (@DSTFILTER@)
GROUP BY d.runnumber, d.dsttype, d.tag
ORDER BY d.runnumber
