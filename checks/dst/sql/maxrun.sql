-- newest run of type DST_RUNTYPE in the run DB (DST_DAQ_DSN); used for a run range ending in "+"
-- (the plain max(runnumber) is a junk/test run, e.g. 600002 local_junk)
SELECT max(runnumber) FROM run WHERE runtype = '@RUNTYPE@'
