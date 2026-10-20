// CdbPlots.C -- cdb check plots, drawn only from the CSVs the check writes (plain ROOT, no CDB).
//
// CdbStatusPlots(status, fileid, title, out)   one tag / run group, all payload types, 3 pages:
//   status  cdb_status_<page>.csv  run,<type>,...  cells R (own payload) / D (default only) / - (nothing)
//   fileid  cdb_fileid_<page>.csv  run,<type>,...  cells: file number per type in run order, 0 = nothing
//   p1 status per run, p2 fraction of runs per status, p3 which payload file each run gets
// CdbDetectorPlots(status, fileid, detectors, title, outprefix)   the same, one PDF per detector:
//   detectors cdb_detectors_<page>.csv  payload,detector (detector order) -> <outprefix>_<detector>.pdf
// CdbFallbackPlot(fallback, title, out)        one global tag over its run groups, 1 page:
//   fallback cdb_fallback_<tag>.csv  domain,<g>_nruns,<g>_default,<g>_missing,...
//   cell "ok" / "default / nothing"; green = all own payloads, orange = some default only, red = some nothing
//   detectors (optional) cdb_detectors_<tag>.csv: rows grouped by detector, with the detector names
#include <TBox.h>
#include <TCanvas.h>
#include <TColor.h>
#include <TH2F.h>
#include <TLatex.h>
#include <TLine.h>
#include <TStyle.h>
#include <TSystem.h>

#include <algorithm>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

namespace
{
  using Table = std::vector<std::vector<std::string>>;

  Table ReadCsv(const std::string &fname)
  {
    Table t;
    std::ifstream in(fname);
    if (!in)
    {
      std::cerr << "CdbPlots: cannot read " << fname << std::endl;
      gSystem->Exit(1);
    }
    std::string line;
    while (std::getline(in, line))
    {
      if (!line.empty() && line.back() == '\r') line.pop_back();
      if (line.empty()) continue;
      std::vector<std::string> row;
      std::stringstream ss(line);
      std::string cell;
      while (std::getline(ss, cell, ',')) row.push_back(cell);
      if (!line.empty() && line.back() == ',') row.push_back("");
      t.push_back(row);
    }
    return t;
  }

  const int kColOwn = TColor::GetColor("#009900");
  const int kColDef = TColor::GetColor("#ff9900");
  const int kColNone = TColor::GetColor("#cc0000");
  const int kColNotWatched = TColor::GetColor("#dddddd");

  // canvas tall enough for one row per payload type, left margin for the longest name
  TCanvas *MakeCanvas(const char *name, const std::vector<std::string> &rows, int width = 1500)
  {
    size_t maxlen = 10;
    for (const auto &r : rows) maxlen = std::max(maxlen, r.size());
    int height = std::min(6000, std::max(400, 170 + 22 * static_cast<int>(rows.size())));
    auto *c = new TCanvas(name, name, width, height);
    c->SetLeftMargin(std::min(0.45, (7.0 * maxlen + 30) / width));
    c->SetRightMargin(0.04);
    c->SetTopMargin(120.0 / height);
    c->SetBottomMargin(50.0 / height);
    return c;
  }

  // run-number labels on ~10 evenly spaced bins of the run axis
  void RunLabels(TH2 *h, const Table &t)
  {
    int n = t.size() - 1;
    int step = std::max(1, n / 10);
    for (int i = 1; i <= n; i += step) h->GetXaxis()->SetBinLabel(i, t[i][0].c_str());
    h->GetXaxis()->SetBinLabel(n, t[n][0].c_str());
    h->GetXaxis()->LabelsOption("h");
    h->GetXaxis()->SetLabelSize(0.025);
    h->GetXaxis()->SetTickLength(0);
  }

  void TypeLabels(TH2 *h, const std::vector<std::string> &types, double height)
  {
    for (size_t j = 0; j < types.size(); ++j) h->GetYaxis()->SetBinLabel(j + 1, types[j].c_str());
    h->GetYaxis()->SetLabelSize(std::min(0.03, 11.0 / height));
    h->GetYaxis()->SetTickLength(0);
  }

  void Header(TCanvas *c, const std::string &l1, const std::string &l2 = "", bool legend = false)
  {
    double h = c->GetWh();
    TLatex t;
    t.SetNDC();
    t.SetTextFont(62);
    t.SetTextSize(22.0 / h);
    t.DrawLatex(c->GetLeftMargin(), 1 - 40.0 / h, l1.c_str());
    if (!l2.empty())
    {
      t.SetTextFont(42);
      t.SetTextSize(18.0 / h);
      t.DrawLatex(c->GetLeftMargin(), 1 - 75.0 / h, l2.c_str());
    }
    if (legend)
    {
      t.SetTextFont(62);
      t.SetTextSize(20.0 / h);
      double x = c->GetLeftMargin();
      t.SetTextColor(kColOwn);
      t.DrawLatex(x, 1 - 75.0 / h, "own payload");
      t.SetTextColor(kColDef);
      t.DrawLatex(x + 0.18, 1 - 75.0 / h, "default only (fallback)");
      t.SetTextColor(kColNone);
      t.DrawLatex(x + 0.45, 1 - 75.0 / h, "nothing");
    }
  }
}  // namespace

namespace
{
  // run column + the given columns (1-based) of every row
  Table Select(const Table &t, const std::vector<int> &cols)
  {
    Table s;
    for (const auto &row : t)
    {
      std::vector<std::string> r{row[0]};
      for (int c : cols) r.push_back(c < static_cast<int>(row.size()) ? row[c] : "");
      s.push_back(r);
    }
    return s;
  }

  // detector -> payload types, in the order of the detectors file
  std::vector<std::pair<std::string, std::vector<std::string>>> ReadDetectors(const std::string &fname)
  {
    std::vector<std::pair<std::string, std::vector<std::string>>> d;
    Table t = ReadCsv(fname);
    for (size_t i = 1; i < t.size(); ++i)
    {
      if (t[i].size() < 2) continue;
      if (d.empty() || d.back().first != t[i][1]) d.push_back({t[i][1], {}});
      d.back().second.push_back(t[i][0]);
    }
    return d;
  }

}  // namespace

void DrawStatus(const Table &st, const Table &fi, const std::string &title, const std::string &out);

void CdbStatusPlots(const std::string &status, const std::string &fileid,
                    const std::string &title, const std::string &out)
{
  Table st = ReadCsv(status);
  if (st.size() < 2 || st[0].size() < 2)
  {
    std::cerr << "CdbPlots: no runs or payload types in " << status << std::endl;
    gSystem->Exit(1);
  }
  DrawStatus(st, ReadCsv(fileid), title, out);
}

void CdbDetectorPlots(const std::string &status, const std::string &fileid, const std::string &detectors,
                      const std::string &title, const std::string &outprefix)
{
  Table st = ReadCsv(status);
  Table fi = ReadCsv(fileid);
  if (st.size() < 2 || st[0].size() < 2)
  {
    std::cerr << "CdbPlots: no runs or payload types in " << status << std::endl;
    gSystem->Exit(1);
  }
  for (const auto &d : ReadDetectors(detectors))
  {
    std::vector<int> cols;
    for (const auto &type : d.second)
    {
      auto it = std::find(st[0].begin() + 1, st[0].end(), type);
      if (it != st[0].end()) cols.push_back(it - st[0].begin());
    }
    if (cols.empty()) continue;
    DrawStatus(Select(st, cols), Select(fi, cols), title + " " + d.first, outprefix + "_" + d.first + ".pdf");
  }
}

void DrawStatus(const Table &st, const Table &fi, const std::string &title, const std::string &out)
{
  gStyle->SetOptStat(0);
  gStyle->SetOptTitle(0);
  int nrun = st.size() - 1;
  std::vector<std::string> types(st[0].begin() + 1, st[0].end());
  int ntype = types.size();
  std::string runs = std::to_string(nrun) + " runs (" + st[1][0] + "-" + st[nrun][0] + "), " + std::to_string(ntype) + " payload types";

  // ---- p1: status per run
  TCanvas *c = MakeCanvas("cdb_status", types);
  auto *h = new TH2F("h_status", "", nrun, 0, nrun, ntype, 0, ntype);
  std::vector<int> nown(ntype, 0), ndef(ntype, 0), nnone(ntype, 0);
  for (int i = 1; i <= nrun; ++i)
  {
    for (int j = 0; j < ntype && j + 1 < static_cast<int>(st[i].size()); ++j)
    {
      const std::string &s = st[i][j + 1];
      int v = (s == "R") ? 1 : (s == "D") ? 2 : 3;
      (v == 1 ? nown : v == 2 ? ndef : nnone)[j]++;
      h->SetBinContent(i, j + 1, v);
    }
  }
  int pal[3] = {kColOwn, kColDef, kColNone};
  gStyle->SetPalette(3, pal);
  h->SetMinimum(0.5);
  h->SetMaximum(3.5);
  RunLabels(h, st);
  TypeLabels(h, types, c->GetWh());
  h->Draw("COL");
  Header(c, title + ": " + runs, "", true);
  c->Print((out + "(").c_str(), "pdf");

  // ---- p2: fraction of runs per status
  c->Clear();
  auto *f = new TH2F("h_frac", "", 1, 0, 1, ntype, 0, ntype);
  TypeLabels(f, types, c->GetWh());
  f->GetXaxis()->SetTitle("fraction of runs");
  f->GetXaxis()->SetLabelSize(0.025);
  f->Draw("AXIS");
  TBox b;
  TLatex n;
  n.SetTextSize(std::min(0.025, 10.0 / c->GetWh()));
  n.SetTextAlign(32);
  for (int j = 0; j < ntype; ++j)
  {
    double x0 = 0, fr[3] = {nown[j] / double(nrun), ndef[j] / double(nrun), nnone[j] / double(nrun)};
    for (int k = 0; k < 3; ++k)
    {
      if (fr[k] <= 0) continue;
      b.SetFillColor(pal[k]);
      b.DrawBox(x0, j + 0.1, x0 + fr[k], j + 0.9);
      x0 += fr[k];
    }
    if (ndef[j] + nnone[j] > 0)
      n.DrawLatex(0.995, j + 0.5, Form("#color[0]{%d / %d / %d}", nown[j], ndef[j], nnone[j]));
  }
  f->Draw("AXIS SAME");
  Header(c, title + ": fraction of runs per status", "", true);
  c->Print(out.c_str(), "pdf");

  // ---- p3: which payload file each run gets (colour = file number within the type, white = nothing)
  c->Clear();
  auto *m = new TH2F("h_file", "", nrun, 0, nrun, ntype, 0, ntype);
  std::vector<int> maxid(ntype, 0);
  for (int i = 1; i < static_cast<int>(fi.size()); ++i)
    for (int j = 0; j < ntype && j + 1 < static_cast<int>(fi[i].size()); ++j) maxid[j] = std::max(maxid[j], std::atoi(fi[i][j + 1].c_str()));
  for (int i = 1; i < static_cast<int>(fi.size()) && i <= nrun; ++i)
  {
    for (int j = 0; j < ntype && j + 1 < static_cast<int>(fi[i].size()); ++j)
    {
      int id = std::atoi(fi[i][j + 1].c_str());
      if (id > 0) m->SetBinContent(i, j + 1, 0.001 + 0.999 * (id - 1) / std::max(1, maxid[j] - 1));
    }
  }
  gStyle->SetPalette(kRainBow);
  m->SetMinimum(1e-4);
  m->SetMaximum(1);
  RunLabels(m, st);
  TypeLabels(m, types, c->GetWh());
  m->Draw("COL");
  Header(c, title + ": which payload file each run gets",
         "colour = distinct file, in run order; white = nothing. A long band = one payload for a run range, a speckle = per-run payloads");
  c->Print((out + ")").c_str(), "pdf");
  delete h;
  delete f;
  delete m;
  delete c;
}

void CdbFallbackPlot(const std::string &fallback, const std::string &title, const std::string &out,
                     const std::string &detectors = "")
{
  gStyle->SetOptStat(0);
  gStyle->SetOptTitle(0);
  Table t = ReadCsv(fallback);
  if (t.size() < 2 || t[0].size() < 4)
  {
    std::cerr << "CdbPlots: no run groups or payload types in " << fallback << std::endl;
    gSystem->Exit(1);
  }
  // rows grouped by detector (top to bottom), detector name at each block
  std::vector<std::pair<int, std::string>> blocks;  // first row index, detector
  if (!detectors.empty())
  {
    Table sorted{t[0]};
    for (const auto &d : ReadDetectors(detectors))
    {
      size_t before = sorted.size();
      for (const auto &type : d.second)
        for (size_t j = 1; j < t.size(); ++j)
          if (t[j][0] == type) sorted.push_back(t[j]);
      if (sorted.size() > before) blocks.push_back({static_cast<int>(before), d.first});
    }
    if (sorted.size() == t.size()) t = sorted;
    else blocks.clear();
  }
  // ROOT draws bin 1 at the bottom: reverse so the first type is on top
  std::reverse(t.begin() + 1, t.end());
  int ng = (t[0].size() - 1) / 3, ntype = t.size() - 1;
  std::vector<std::string> types;
  for (int j = 1; j <= ntype; ++j) types.push_back(t[j][0]);
  TCanvas *c = MakeCanvas("cdb_fallback", types, std::max(900, 300 + 190 * ng));
  if (!blocks.empty()) c->SetRightMargin(0.09);
  auto *h = new TH2F("h_fallback", "", ng, 0, ng, ntype, 0, ntype);
  for (int g = 0; g < ng; ++g)
  {
    std::string name = t[0][1 + 3 * g];
    name = name.substr(0, name.rfind("_nruns"));
    // runs of the group: the largest count over its types
    int nr = 0;
    for (int j = 1; j <= ntype; ++j)
      if (1 + 3 * g < static_cast<int>(t[j].size())) nr = std::max(nr, std::atoi(t[j][1 + 3 * g].c_str()));
    h->GetXaxis()->SetBinLabel(g + 1, Form("%s (%d)", name.c_str(), nr));
  }
  h->GetXaxis()->SetLabelSize(std::min(0.03, 14.0 / c->GetWw() * 2));
  TypeLabels(h, types, c->GetWh());
  h->Draw("AXIS");
  TBox b;
  TLatex l;
  l.SetTextAlign(22);
  l.SetTextSize(std::min(0.025, 11.0 / c->GetWh()));
  for (int j = 1; j <= ntype; ++j)
  {
    for (int g = 0; g < ng; ++g)
    {
      int k = 1 + 3 * g;
      bool watched = k + 2 < static_cast<int>(t[j].size()) && !t[j][k].empty();
      int nd = watched ? std::atoi(t[j][k + 1].c_str()) : 0, nm = watched ? std::atoi(t[j][k + 2].c_str()) : 0;
      b.SetFillColor(!watched ? kColNotWatched : nm > 0 ? kColNone : nd > 0 ? kColDef : kColOwn);
      b.DrawBox(g + 0.03, j - 1 + 0.08, g + 0.97, j - 0.08);
      if (watched) l.DrawLatex(g + 0.5, j - 0.5, (nd + nm == 0) ? "#color[0]{ok}" : Form("#color[0]{%d / %d}", nd, nm));
    }
  }
  h->Draw("AXIS SAME");
  TLatex dl;
  dl.SetTextAlign(12);
  dl.SetTextFont(62);
  dl.SetTextSize(std::min(0.03, 13.0 / c->GetWh()));
  for (size_t k = 0; k < blocks.size(); ++k)
  {
    // block k: sorted rows [first, next first), stored reversed: y from ntype - next + 1 to ntype - first + 1
    int first = blocks[k].first, next = (k + 1 < blocks.size()) ? blocks[k + 1].first : ntype + 1;
    double ytop = ntype - first + 1, ybot = ntype - next + 1;
    if (k > 0)
    {
      TLine ln;
      ln.SetLineWidth(3);
      ln.DrawLine(0, ytop, ng, ytop);
    }
    dl.DrawLatex(ng + 0.04, 0.5 * (ytop + ybot), blocks[k].second.c_str());
  }
  Header(c, title, "per run group: runs with default only / with nothing (ok = every run has its own payload; grey = not watched)");
  c->Print(out.c_str(), "pdf");
}
