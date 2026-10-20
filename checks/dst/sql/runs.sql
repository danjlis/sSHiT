-- run DB (DST_DAQ_DSN): one row per run in [@FIRST@, @LAST@], columns in this order:
--   runnumber  runtype  events  seconds  hosts  marked_invalid
-- seconds: run length, -1 if the run has no end time
-- hosts:   comma list of the DAQ hosts that wrote events in the run ("-" if none);
--          compared with DST_CALO_HOSTS to tell whether the calorimeters were read out
-- marked_invalid: 1 = run marked invalid (rejected), -1/0 = not marked
SELECT r.runnumber,
       r.runtype,
       coalesce(r.eventsinrun, 0),
       coalesce(CAST(extract(epoch FROM (r.ertimestamp - r.brtimestamp)) AS bigint), -1),
       coalesce((SELECT string_agg(DISTINCT e.hostname, ',') FROM event_numbers e
                 WHERE e.runnumber = r.runnumber AND e.nr_events > 0), '-'),
       coalesce(r.marked_invalid, 0)
FROM run r
WHERE r.runnumber BETWEEN @FIRST@ AND @LAST@
ORDER BY r.runnumber
