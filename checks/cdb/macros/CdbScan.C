// CdbScan.C -- resolve (tag, run, payload type) -> payload URL (read only).
//
// One CDB query per run: CDBUtils::PayloadIOVs(run) returns all payload types valid
// for that run. Appends TSV lines to outfile:
//   tag  run  payload  url  iov_start  iov_end     (url = "-" if no valid payload)
// If the tag does not exist a single line "tag - - TAG_NOT_FOUND - -" is written.
// SphenixClient.h first: CDBUtils.h only forward-declares it, but cling needs the
// complete type to instantiate CDBUtils' unique_ptr<SphenixClient> destructor
#include <sphenixnpc/SphenixClient.h>
#include <sphenixnpc/CDBUtils.h>

#include <TStopwatch.h>

#include <algorithm>
#include <cstdint>
#include <fstream>
#include <iostream>
#include <string>
#include <tuple>
#include <vector>

R__LOAD_LIBRARY(libsphenixnpc.so)

std::vector<std::string> ReadLines(const std::string &fname)
{
  std::vector<std::string> v;
  std::ifstream in(fname);
  std::string line;
  while (in >> line)
  {
    v.push_back(line);
  }
  return v;
}

void CdbScan(const std::string &tag, const std::string &runlist,
             const std::string &payloadlist, const std::string &outfile)
{
  std::ofstream out(outfile, std::ios::app);
  CDBUtils cdb;
  if (cdb.setGlobalTag(tag) != 0)
  {
    out << tag << "\t-\t-\tTAG_NOT_FOUND\t-\t-\n";
    return;
  }
  std::vector<std::string> runs = ReadLines(runlist);
  std::vector<std::string> payloads = ReadLines(payloadlist);
  std::cout << "CdbScan: tag " << tag << ", " << runs.size() << " runs, "
            << payloads.size() << " payload types" << std::endl;

  // progress every ~5% of the runs
  size_t step = std::max<size_t>(1, runs.size() / 20);
  TStopwatch timer;
  size_t nrun = 0;
  for (const auto &srun : runs)
  {
    if (srun.empty() || srun.find_first_not_of("0123456789") != std::string::npos)
    {
      std::cout << "CdbScan: skipping, not a run number: " << srun << std::endl;
      continue;
    }
    uint64_t run = std::stoull(srun);
    auto iovs = cdb.PayloadIOVs(run);
    for (const auto &pl : payloads)
    {
      auto it = iovs.find(pl);
      if (it == iovs.end())
      {
        out << tag << "\t" << run << "\t" << pl << "\t-\t-\t-\n";
      }
      else
      {
        out << tag << "\t" << run << "\t" << pl << "\t"
            << std::get<0>(it->second) << "\t"
            << std::get<1>(it->second) << "\t"
            << std::get<2>(it->second) << "\n";
      }
    }
    if (++nrun % step == 0 || nrun == runs.size())
    {
      std::cout << "CdbScan: " << tag << " " << nrun << "/" << runs.size() << " runs (last "
                << run << ", " << iovs.size() << " payload types valid), "
                << static_cast<int>(timer.RealTime()) << "s" << std::endl;
      timer.Continue();
    }
  }
}
