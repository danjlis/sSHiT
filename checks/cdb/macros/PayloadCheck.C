// PayloadCheck.C -- open each ROOT payload file and validate it.
// input: one path per line. output TSV: path  status  nkeys  message
//   status: OK | ZOMBIE | RECOVERED | NOKEYS | NOOPEN
#include <TError.h>
#include <TFile.h>

#include <fstream>
#include <memory>
#include <string>

void PayloadCheck(const std::string &listfile, const std::string &outfile)
{
  gErrorIgnoreLevel = kFatal;
  std::ifstream in(listfile);
  std::ofstream out(outfile);
  std::string path;
  while (std::getline(in, path))
  {
    if (path.empty())
    {
      continue;
    }
    std::unique_ptr<TFile> f(TFile::Open(path.c_str(), "READ"));
    if (!f)
    {
      out << path << "\tNOOPEN\t0\tTFile::Open failed\n";
      continue;
    }
    if (f->IsZombie())
    {
      out << path << "\tZOMBIE\t0\tfile is a zombie\n";
      continue;
    }
    int nkeys = f->GetNkeys();
    if (f->TestBit(TFile::kRecovered))
    {
      out << path << "\tRECOVERED\t" << nkeys << "\tfile was not closed properly (keys recovered)\n";
    }
    else if (nkeys == 0)
    {
      out << path << "\tNOKEYS\t0\tfile has no keys\n";
    }
    else
    {
      out << path << "\tOK\t" << nkeys << "\t\n";
    }
  }
}
