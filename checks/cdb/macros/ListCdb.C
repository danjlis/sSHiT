// ListCdb.C -- print every global tag and payload type in the CDB (read only).
// output lines: "global tag: <name>" / "payload type: <name>"
// SphenixClient.h first: CDBUtils.h only forward-declares it, but cling needs the
// complete type to instantiate CDBUtils' unique_ptr<SphenixClient> destructor
#include <sphenixnpc/SphenixClient.h>
#include <sphenixnpc/CDBUtils.h>

R__LOAD_LIBRARY(libsphenixnpc.so)

void ListCdb()
{
  CDBUtils cdb;
  cdb.listGlobalTags();
  cdb.listPayloadTypes();
}
