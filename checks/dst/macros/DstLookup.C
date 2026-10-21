// DstLookup.C -- what the FileCatalog knows about one run's DSTs, and whether the disk copies are really there.
//
//   root -l -b -q 'checks/dst/macros/DstLookup.C(47289)'                                   // DST_TRIGGERED_EVENT_seb*
//   root -l -b -q 'checks/dst/macros/DstLookup.C(47289,"DST_CALOFITTING")'
//   root -l -b -q 'checks/dst/macros/DstLookup.C(47289,"DST_TRIGGERED_EVENT_seb00",0)'    // catalog only, no stat
//
//   dsttype  SQL LIKE pattern on datasets.dsttype ('%' = anything; letters, digits, '_' and '%' only)
//   stat     1 = stat every disk copy (lustre/gpfs) and compare its size with the catalog
//   dsn      ODBC data source (same as DST_FC_DSN in shirt.conf)
// One line per segment and copy (datasets LEFT JOIN files). Last column:
//   ok         on disk, file there, size as in the catalog
//   MISSING    catalog has a disk copy, the file does not exist
//   SIZE a!=b  file there, size differs from the catalog
//   tape       HPSS copy (not checked)
//   no copy    in datasets, but no row in files
// Read only: a single SELECT.
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wdeprecated-declarations"
#include <odbc++/connection.h>
#include <odbc++/drivermanager.h>
#include <odbc++/resultset.h>
#include <odbc++/statement.h>
#include <odbc++/types.h>
#pragma GCC diagnostic pop

#include <TSystem.h>

#include <cstdio>
#include <iostream>
#include <map>
#include <memory>
#include <string>

R__LOAD_LIBRARY(libodbc++.so)

void DstLookup(int run, const std::string &dsttype = "DST_TRIGGERED_EVENT_seb%", int stat = 1,
               const std::string &dsn = "FileCatalog")
{
  if (dsttype.empty() || dsttype.find_first_not_of("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_%") != std::string::npos)
  {
    std::cerr << "DstLookup: dsttype may only contain letters, digits, '_' and '%': " << dsttype << std::endl;
    return;
  }
  std::string sql =
      "SELECT d.dsttype, d.segment, coalesce(d.tag, '-'), coalesce(d.events, 0), d.filename,"
      "       coalesce(f.full_host_name, '-'), coalesce(f.size, -1), coalesce(f.full_file_path, '-')"
      " FROM datasets d LEFT JOIN files f ON f.lfn = d.filename"
      " WHERE d.runnumber = " + std::to_string(run) + " AND d.dsttype LIKE '" + dsttype + "'"
      " ORDER BY d.dsttype, d.segment, f.full_host_name";

  std::map<std::string, int> count;  // summary
  int nrow = 0;
  try
  {
    std::unique_ptr<odbc::Connection> con(odbc::DriverManager::getConnection(dsn, "", ""));
    std::unique_ptr<odbc::Statement> st(con->createStatement());
    std::unique_ptr<odbc::ResultSet> rs(st->executeQuery(sql));
    printf("run %d, dsttype LIKE '%s' (%s)\n", run, dsttype.c_str(), dsn.c_str());
    printf("%-28s %4s %-24s %8s %-7s %12s  %-12s %s\n", "dsttype", "seg", "tag", "events", "host", "size", "on disk?", "path");
    while (rs->next())
    {
      ++nrow;
      std::string type = rs->getString(1), seg = rs->getString(2), tag = rs->getString(3), ev = rs->getString(4);
      std::string lfn = rs->getString(5), host = rs->getString(6), size = rs->getString(7), path = rs->getString(8);
      long long csize = std::atoll(size.c_str());
      std::string verdict;
      if (host == "-") verdict = "no copy";
      else if (host == "hpss") verdict = "tape";
      else if (!stat) verdict = "(not checked)";
      else
      {
        // full_file_path normally includes the file name; if it is a directory, add the lfn
        std::string file = path;
        if (file.size() < lfn.size() || file.compare(file.size() - lfn.size(), lfn.size(), lfn) != 0) file += "/" + lfn;
        FileStat_t fs;
        if (gSystem->GetPathInfo(file.c_str(), fs) != 0) verdict = "MISSING";
        else if (csize >= 0 && fs.fSize != csize) verdict = "SIZE " + std::to_string(fs.fSize) + "!=" + size;
        else verdict = "ok";
      }
      count[verdict.compare(0, 4, "SIZE") == 0 ? "size mismatch" : verdict]++;
      printf("%-28s %4s %-24s %8s %-7s %12s  %-12s %s\n", type.c_str(), seg.c_str(), tag.c_str(), ev.c_str(),
             host.c_str(), size.c_str(), verdict.c_str(), path.c_str());
    }
  }
  catch (odbc::SQLException &e)
  {
    std::cerr << "DstLookup: " << dsn << ": " << e.getMessage() << std::endl;
    return;
  }
  if (nrow == 0)
  {
    printf("nothing in the FileCatalog for run %d, dsttype LIKE '%s'\n", run, dsttype.c_str());
    return;
  }
  printf("\n%d rows:", nrow);
  for (const auto &c : count) printf("  %s: %d", c.first.c_str(), c.second);
  printf("\n");
}
