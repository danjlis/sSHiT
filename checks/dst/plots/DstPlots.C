// DstPlots.C -- dst check plots, drawn only from the CSV the check writes (plain ROOT, no FileCatalog).
//
// DstRunPlots(csv, title, outprefix)   one run group, one PDF per DST: <outprefix>_<dst>.pdf
//   csv  dst_runs_<group>.csv  run,dst,status,segments,expected,on_disk,first_on_disk
//        one row per good run and expected DST (dst = the name in the DST list, in list order);
//        a missing DST has segments = on_disk = first_on_disk = 0
//   top     per run (in run order): first segment on disk (green) or not (red)
//   middle  percent of the expected segments on disk vs run number, one marker per run:
//           100% green, >= 95% yellow, < 95% black
//   bottom  runs per percent of segments on disk (same colours)
#include <TCanvas.h>
#include <TColor.h>
#include <TH1F.h>
#include <TGraph.h>
#include <TH2F.h>
#include <TLine.h>
#include <TLatex.h>
#include <TPad.h>
#include <TStyle.h>
#include <TSystem.h>

#include <algorithm>
#include <fstream>
#include <iostream>
#include <map>
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
      std::cerr << "DstPlots: cannot read " << fname << std::endl;
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
      t.push_back(row);
    }
    return t;
  }

  const int kColOk = TColor::GetColor("#009900");
  const int kColBad = TColor::GetColor("#cc0000");
  const int kColAlmost = TColor::GetColor("#e6b800");
  const int kColLow = kBlack;
  const double kAlmost = 0.95;

  struct Run
  {
    std::string run;
    double frac;  // on_disk / expected (0 if missing)
    bool first;   // first segment on disk
  };

  int FracColor(double f) { return f >= 1 ? kColOk : f >= kAlmost ? kColAlmost : kColLow; }

  void Header(TCanvas *c, const std::string &l1, const std::string &l2)
  {
    double h = c->GetWh();
    TLatex t;
    t.SetNDC();
    t.SetTextFont(62);
    t.SetTextSize(22.0 / h);
    t.DrawLatex(0.08, 1 - 35.0 / h, l1.c_str());
    t.SetTextFont(42);
    t.SetTextSize(18.0 / h);
    t.DrawLatex(0.08, 1 - 65.0 / h, l2.c_str());
  }

  void DrawDst(const std::string &dst, const std::vector<Run> &runs, const std::string &title, const std::string &out)
  {
    int nrun = runs.size();
    int nfirst = 0, nall = 0, nalmost = 0, nlow = 0;
    for (const auto &r : runs)
    {
      nfirst += r.first;
      (r.frac >= 1 ? nall : r.frac >= kAlmost ? nalmost : nlow)++;
    }
    auto *c = new TCanvas(("dst_" + dst).c_str(), dst.c_str(), 1500, 1250);
    Header(c, title + " " + dst + ": " + std::to_string(nrun) + " good runs (" + runs.front().run + "-" + runs.back().run + ")",
           Form("1st segment on disk: %d of %d runs.   Segments on disk: all %d, #geq 95%% %d, < 95%% %d", nfirst, nrun, nall, nalmost, nlow));
    const double kLeft = 0.10, kRight = 0.03;

    // ---- top: first segment on disk, one bin per run (run order)
    auto *top = new TPad("top", "", 0, 0.82, 1, 0.93);
    top->SetLeftMargin(kLeft);
    top->SetRightMargin(kRight);
    top->SetBottomMargin(0.40);
    top->SetTopMargin(0.02);
    top->Draw();
    top->cd();
    auto *h = new TH2F(("h_first_" + dst).c_str(), "", nrun, 0, nrun, 1, 0, 1);
    for (int i = 0; i < nrun; ++i) h->SetBinContent(i + 1, 1, runs[i].first ? 1 : 2);
    int pal[2] = {kColOk, kColBad};
    gStyle->SetPalette(2, pal);
    h->SetMinimum(0.5);
    h->SetMaximum(2.5);
    int step = std::max(1, nrun / 10);
    for (int i = 0; i < nrun; i += step) h->GetXaxis()->SetBinLabel(i + 1, runs[i].run.c_str());
    h->GetXaxis()->SetBinLabel(nrun, runs.back().run.c_str());
    h->GetXaxis()->LabelsOption("h");
    h->GetXaxis()->SetLabelSize(0.20);
    h->GetXaxis()->SetTickLength(0);
    h->GetYaxis()->SetBinLabel(1, "1st seg. on disk");
    h->GetYaxis()->SetLabelSize(0.2);
    h->GetYaxis()->SetTickLength(0);
    h->Draw("COL");

    // ---- middle: percent of the expected segments on disk vs run number
    c->cd();
    auto *mid = new TPad("mid", "", 0, 0.43, 1, 0.81);
    mid->SetLeftMargin(kLeft);
    mid->SetRightMargin(kRight);
    mid->SetBottomMargin(0.14);
    mid->SetTopMargin(0.04);
    mid->SetGridy();
    mid->Draw();
    mid->cd();
    double r0 = std::atof(runs.front().run.c_str()), r1 = std::atof(runs.back().run.c_str());
    double pad = std::max(1.0, 0.01 * (r1 - r0));
    auto *fr = new TH1F(("h_pct_" + dst).c_str(), "", 100, r0 - pad, r1 + pad);
    fr->SetMinimum(-3);
    fr->SetMaximum(105);
    fr->GetXaxis()->SetTitle("run number");
    fr->GetYaxis()->SetTitle("segments on disk [% of expected]");
    fr->GetXaxis()->SetNoExponent();
    fr->GetXaxis()->SetNdivisions(510);
    fr->GetXaxis()->SetTitleSize(0.05);
    fr->GetYaxis()->SetTitleSize(0.05);
    fr->GetXaxis()->SetLabelSize(0.045);
    fr->GetYaxis()->SetLabelSize(0.045);
    fr->GetYaxis()->SetTitleOffset(0.85);
    fr->Draw("AXIS");
    TLine cut;
    cut.SetLineStyle(2);
    cut.SetLineWidth(2);
    cut.SetLineColor(kColAlmost);
    cut.DrawLine(r0 - pad, 100 * kAlmost, r1 + pad, 100 * kAlmost);
    int col[3] = {kColLow, kColAlmost, kColOk};
    double msize = nrun > 2000 ? 0.5 : nrun > 300 ? 0.8 : 1.2;
    for (int k = 0; k < 3; ++k)
    {
      auto *g = new TGraph();
      for (const auto &r : runs)
        if ((r.frac >= 1 ? 2 : r.frac >= kAlmost ? 1 : 0) == k) g->SetPoint(g->GetN(), std::atof(r.run.c_str()), 100 * r.frac);
      if (g->GetN() == 0) continue;
      g->SetMarkerStyle(20);
      g->SetMarkerSize(msize);
      g->SetMarkerColor(col[k]);
      g->Draw("P SAME");
    }

    // ---- bottom: runs per percent of segments on disk (last bin = exactly all)
    c->cd();
    auto *bot = new TPad("bot", "", 0, 0, 1, 0.41);
    bot->SetLeftMargin(kLeft);
    bot->SetRightMargin(kRight);
    bot->SetBottomMargin(0.15);
    bot->SetTopMargin(0.04);
    bot->SetLogy();
    bot->Draw();
    bot->cd();
    TH1F *f[3];
    for (int k = 0; k < 3; ++k)
    {
      f[k] = new TH1F(Form("h_frac_%s_%d", dst.c_str(), k), "", 101, 0, 101);
      f[k]->SetFillColor(col[k]);
      f[k]->SetLineWidth(0);  // no outline: empty bins would draw a line along the axis
    }
    for (const auto &r : runs)
    {
      double x = r.frac >= 1 ? 100.5 : std::min(100 * r.frac, 99.99);
      f[r.frac >= 1 ? 2 : r.frac >= kAlmost ? 1 : 0]->Fill(x);
    }
    double ymax = 1;
    for (auto *x : f) ymax = std::max(ymax, x->GetMaximum());
    f[0]->SetMinimum(0.5);
    f[0]->SetMaximum(ymax * 3);
    f[0]->GetXaxis()->SetTitle("segments on disk [% of expected]");
    f[0]->GetYaxis()->SetTitle("good runs");
    f[0]->GetXaxis()->SetTitleSize(0.05);
    f[0]->GetYaxis()->SetTitleSize(0.05);
    f[0]->GetXaxis()->SetLabelSize(0.045);
    f[0]->GetYaxis()->SetLabelSize(0.045);
    f[0]->GetYaxis()->SetTitleOffset(0.85);
    f[0]->Draw("HIST");
    f[1]->Draw("HIST SAME");
    f[2]->Draw("HIST SAME");

    TLatex l;
    l.SetNDC();
    l.SetTextFont(62);
    l.SetTextSize(0.045);
    l.SetTextColor(kColLow);
    l.DrawLatex(0.14, 0.88, Form("< 95%%: %d", nlow));
    l.SetTextColor(kColAlmost);
    l.DrawLatex(0.30, 0.88, Form("#geq 95%%: %d", nalmost));
    l.SetTextColor(kColOk);
    l.DrawLatex(0.48, 0.88, Form("all: %d", nall));
    l.SetTextColor(kColBad);
    l.DrawLatex(0.64, 0.88, Form("1st segment not on disk: %d", nrun - nfirst));

    c->Print(out.c_str(), "pdf");
    delete c;
  }
}  // namespace

void DstRunPlots(const std::string &csv, const std::string &title, const std::string &outprefix)
{
  gStyle->SetOptStat(0);
  gStyle->SetOptTitle(0);
  Table t = ReadCsv(csv);
  if (t.size() < 2)
  {
    std::cerr << "DstPlots: no runs in " << csv << std::endl;
    gSystem->Exit(1);
  }
  std::vector<std::string> order;
  std::map<std::string, std::vector<Run>> runs;
  for (size_t i = 1; i < t.size(); ++i)
  {
    const auto &r = t[i];
    if (r.size() < 7) continue;
    double expected = std::atof(r[4].c_str()), disk = std::atof(r[5].c_str());
    if (!runs.count(r[1])) order.push_back(r[1]);
    runs[r[1]].push_back({r[0], expected > 0 ? std::min(1.0, disk / expected) : 0, r[6] == "1"});
  }
  for (const auto &d : order) DrawDst(d, runs[d], title, outprefix + "_" + d + ".pdf");
}
