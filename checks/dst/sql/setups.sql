-- FileCatalog (DST_FC_DSN): the production setup (software build, CDB tag) behind the DSTs of
-- runs [@FIRST@, @LAST@], columns in this order:
--   dsttype  dstname  build  dbtag  hash
-- Matched to a DST by dstname starting with its dsttype and containing its production tag;
-- if nothing matches, build and CDB tag are read from the tag name (<build>_<cdbtag>_<version>).
SELECT DISTINCT st.dsttype, st.dstname, s.build, s.dbtag, coalesce(s.hash, '-')
FROM production_status st
JOIN production_setup s ON s.id = st.prod_id
WHERE st.run BETWEEN @FIRST@ AND @LAST@
