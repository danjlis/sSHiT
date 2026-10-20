// TagPayloads.C -- which payload types a global tag provides at the given runs (read only).
// Prints one line per (run, payload type):
//   TP <run> <payload type> <iov_start> <iov_end> <url>
// SphenixClient.h first: CDBUtils.h only forward-declares it, but cling needs the
// complete type to instantiate CDBUtils' unique_ptr<SphenixClient> destructor
#include <sphenixnpc/SphenixClient.h>
#include <sphenixnpc/CDBUtils.h>

#include <cstdint>
#include <fstream>
#include <iostream>
#include <string>
#include <tuple>

R__LOAD_LIBRARY(libsphenixnpc.so)

void TagPayloads(const std::string &tag, const std::string &runlist)
{
  CDBUtils cdb;
  if (cdb.setGlobalTag(tag) != 0)
  {
    std::cout << "TP_ERROR global tag " << tag << " does not exist" << std::endl;
    return;
  }
  std::ifstream in(runlist);
  std::string srun;
  while (in >> srun)
  {
    if (srun.find_first_not_of("0123456789") != std::string::npos)
    {
      std::cout << "TP_SKIP not a run number: " << srun << std::endl;
      continue;
    }
    uint64_t run = std::stoull(srun);
    auto iovs = cdb.PayloadIOVs(run);
    if (iovs.empty())
    {
      std::cout << "TP_EMPTY " << run << std::endl;
    }
    for (const auto &[pt, val] : iovs)
    {
      std::cout << "TP " << run << " " << pt << " " << std::get<1>(val) << " "
                << std::get<2>(val) << " " << std::get<0>(val) << std::endl;
    }
  }
}
