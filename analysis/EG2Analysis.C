// EG2Analysis.C
//
// One pass over a target's gst files fills all four CLAS EG2 analyses and
// writes RAW COUNTS to CSV. No ratios, no normalisation, no plotting.
//
// Why stop at counts: every published observable is a ratio of a nuclear
// target to deuterium, so nothing can be computed until all four targets
// exist. Splitting here keeps the expensive step (10^8 events) apart from the
// fiddly step (error propagation, normalisation conventions, the
// carbon-vs-deuterium reference for b), which you will want to redo often.
//
// Usage:
//   root -l -b -q 'EG2Analysis.C+("/pnfs/.../C12/*.gst.root","C","fsi")'
//   root -l -b -q 'EG2Analysis.C+("pilot_D2.gst.root","D","prefsi",-1,"../data")'
//
//   arg 1  glob, or comma-separated list, of gst files
//   arg 2  target label: D, C, Fe, Pb   (must match the CSV `target` column)
//   arg 3  "fsi" (gst `f` arrays) or "prefsi" (gst `i` arrays)
//   arg 4  max events, -1 for all
//   arg 5  directory holding the four clas_eg2_*.csv data tables
//   arg 6  output directory
//
// PRE-FSI: the gst `i` arrays (ni, pdgi, Ei, pxi, ...) ARE the primary
// hadronic system -- the hadrons before intranuclear rescattering, GHEP status
// kIStHadronInTheNucleus. stage="prefsi" therefore gives the no-cascade
// baseline for free, from the same files, and any A-dependence that survives
// there is NOT final-state interactions. Run it every time.

#include <TChain.h>
#include <TError.h>   // ::Error / ::Info -- not pulled in transitively by ACLiC
#include <TFile.h>
#include <TString.h>
#include <TSystem.h>

#include <cstdio>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

#include "EG2Binning.h"
#include "EG2Fill.h"
#include "EG2Kinematics.h"
#include "EG2Selections.h"

namespace {

const Int_t kNPmax = 250;  // gntpc's fixed array capacity

std::vector<std::string> SplitCommas(const std::string& spec) {
  std::vector<std::string> out;
  std::stringstream ss(spec);
  std::string item;
  while (std::getline(ss, item, ',')) {
    if (!item.empty()) out.push_back(item);
  }
  return out;
}

}  // namespace

void EG2Analysis(const char* input, const char* target, const char* stage = "fsi",
                 Long64_t maxevents = -1,
                 const char* datadir = "../data",
                 const char* outdir = "out") {
  using namespace eg2;

  const bool prefsi = (std::string(stage) == "prefsi");
  gSystem->mkdir(outdir, kTRUE);

  // ---------------------------------------------------------------- binning
  //
  // A missing or misnamed table throws out of CsvTable. Uncaught, that aborts
  // the whole ROOT session with a bare std::runtime_error, so catch it here and
  // say which path was tried -- the usual cause is `datadir` pointing one level
  // off from where the CSVs actually live.
  const std::string d(datadir);
  std::vector<MultTable> mtabs;
  std::vector<CorrSlice> dipion_slices, pip_slices;
  try {
    auto a = LoadMultBinning(
        d + "/clas_eg2_charged_pion_multiplicity_ratios_Moran_PRC105_015201.csv", "Moran");
    auto b = LoadMultBinning(
        d + "/clas_eg2_neutral_pion_multiplicity_ratios_Mineeva_PRC112_035203.csv",
        "Mineeva");
    mtabs.insert(mtabs.end(), a.begin(), a.end());
    mtabs.insert(mtabs.end(), b.begin(), b.end());
    dipion_slices =
        LoadCorrBinning(d + "/clas_eg2_dipion_correlations_Paul_PRC111_035201.csv");
    pip_slices =
        LoadCorrBinning(d + "/clas_eg2_pion_proton_correlations_Paul_2512_05083.csv");
  } catch (const std::exception& e) {
    ::Error("EG2Analysis", "could not load the published tables from '%s': %s",
            datadir, e.what());
    return;
  }

  std::vector<MultAcc> macc(mtabs.size());
  for (size_t i = 0; i < mtabs.size(); ++i) macc[i].Init(mtabs[i]);

  std::vector<CorrAcc> cacc;
  for (const auto& s : dipion_slices) {
    cacc.emplace_back();
    cacc.back().Init("dipion", s);
  }
  for (const auto& s : pip_slices) {
    cacc.emplace_back();
    cacc.back().Init("pionproton", s);
  }
  CorrTotals tot_dipi, tot_pip;

  for (const auto& t : mtabs)
    if (t.overlapping())
      printf("NOTE: %s Table %s (%s) has overlapping published windows; events "
             "in the overlap fill every matching cell, as they must.\n",
             t.paper.c_str(), t.source_table.c_str(), t.hadron.c_str());

  size_t ncells = 0;
  for (const auto& t : mtabs) ncells += t.ncell();
  if (mtabs.empty() || ncells == 0) {
    ::Error("EG2Analysis",
            "the fill grid is EMPTY (%zu tables, %zu cells). The data CSVs were "
            "read but yielded no bins -- almost always a column-name mismatch. "
            "Check the header of %s.",
            mtabs.size(), ncells, datadir);
    return;
  }
  printf("multiplicity tables : %zu (%zu cells)\n", mtabs.size(), ncells);
  printf("correlation slices  : dipion %zu, pi-p %zu\n", dipion_slices.size(),
         pip_slices.size());

  MultiplicityConfig cfg_mult;  // Q2>1, W>2, y<0.85; windows come from the CSV
  DiPionConfig cfg_dipi;
  PiPConfig cfg_pip;

  // ---------------------------------------------------------------- input
  TChain ch("gst");
  for (const auto& f : SplitCommas(input)) ch.Add(f.c_str());
  const Long64_t nall = ch.GetEntries();
  if (nall == 0) {
    ::Error("EG2Analysis", "no entries in '%s' -- wrong path, or gntpc not run with -f gst",
            input);
    return;
  }

  Double_t Ev = 0, pxv = 0, pyv = 0, pzv = 0;
  Double_t El = 0, pxl = 0, pyl = 0, pzl = 0;
  Double_t wght = 1.;
  Int_t nf = 0, ni = 0;
  Int_t pdgf[kNPmax], pdgi[kNPmax];
  Double_t Ef[kNPmax], pxf[kNPmax], pyf[kNPmax], pzf[kNPmax];
  Double_t Ei[kNPmax], pxi[kNPmax], pyi[kNPmax], pzi[kNPmax];

  ch.SetBranchStatus("*", 0);
  for (const char* b : {"Ev", "pxv", "pyv", "pzv", "El", "pxl", "pyl", "pzl", "wght", "nf",
                        "pdgf", "Ef", "pxf", "pyf", "pzf", "ni", "pdgi", "Ei", "pxi", "pyi",
                        "pzi"}) {
    if (ch.GetBranch(b)) ch.SetBranchStatus(b, 1);
  }

  ch.SetBranchAddress("Ev", &Ev);
  ch.SetBranchAddress("El", &El);
  ch.SetBranchAddress("pxl", &pxl);
  ch.SetBranchAddress("pyl", &pyl);
  ch.SetBranchAddress("pzl", &pzl);
  const bool has_probe_p = (ch.GetBranch("pxv") != nullptr);
  if (has_probe_p) {
    ch.SetBranchAddress("pxv", &pxv);
    ch.SetBranchAddress("pyv", &pyv);
    ch.SetBranchAddress("pzv", &pzv);
  }
  const bool has_w = (ch.GetBranch("wght") != nullptr);
  if (has_w) ch.SetBranchAddress("wght", &wght);
  ch.SetBranchAddress("nf", &nf);
  ch.SetBranchAddress("pdgf", pdgf);
  ch.SetBranchAddress("Ef", Ef);
  ch.SetBranchAddress("pxf", pxf);
  ch.SetBranchAddress("pyf", pyf);
  ch.SetBranchAddress("pzf", pzf);
  const bool has_pre = (ch.GetBranch("ni") != nullptr);
  if (has_pre) {
    ch.SetBranchAddress("ni", &ni);
    ch.SetBranchAddress("pdgi", pdgi);
    ch.SetBranchAddress("Ei", Ei);
    ch.SetBranchAddress("pxi", pxi);
    ch.SetBranchAddress("pyi", pyi);
    ch.SetBranchAddress("pzi", pzi);
  }
  if (prefsi && !has_pre) {
    ::Error("EG2Analysis", "stage=prefsi but this gst has no 'ni' branch");
    return;
  }

  // ---------------------------------------------------------------- loop
  const Long64_t nloop = (maxevents > 0 && maxevents < nall) ? maxevents : nall;
  Long64_t n_truncated = 0;
  std::vector<Hadron> had;
  had.reserve(kNPmax);

  for (Long64_t iev = 0; iev < nloop; ++iev) {
    ch.GetEntry(iev);
    if (iev && !(iev % 1000000)) printf("  ... %lld / %lld\n", iev, nloop);

    const double w = has_w ? wght : 1.;

    const Vec3 kbeam = has_probe_p ? Vec3{pxv, pyv, pzv} : Vec3{0., 0., Ev};
    const Vec3 kscat{pxl, pyl, pzl};
    const DIS dis = DIS::Reconstruct(kbeam, Ev, kscat, El);
    if (!dis.valid) continue;

    const Int_t n = prefsi ? ni : nf;
    if (n > kNPmax) {
      ++n_truncated;
      continue;
    }

    had.clear();
    for (Int_t j = 0; j < n; ++j) {
      const int pdg = prefsi ? pdgi[j] : pdgf[j];
      if (pdg != 211 && pdg != -211 && pdg != 111 && pdg != 2212) continue;
      const double E = prefsi ? Ei[j] : Ef[j];
      const Vec3 p =
          prefsi ? Vec3{pxi[j], pyi[j], pzi[j]} : Vec3{pxf[j], pyf[j], pzf[j]};
      had.push_back(Hadron::Build(pdg, E, p, dis, kbeam));
    }

    if (cfg_mult.dis.Pass(dis)) {
      for (auto& a : macc) a.FillEvent(dis, had, w);
    }
    FillDiPion(dis, had, cfg_dipi, kscat.mag(), w, &tot_dipi, &cacc);
    FillPionProton(dis, had, cfg_pip, kscat.mag(), w, &tot_pip, &cacc);
  }

  if (n_truncated)
    printf("WARNING: %lld events had n > kNPmax (%d) and were skipped.\n", n_truncated,
           kNPmax);

  // ---------------------------------------------------------------- output
  const std::string tag = std::string(target) + "_" + stage;
  const std::string fmult = std::string(outdir) + "/counts_mult_" + tag + ".csv";
  const std::string fcorr = std::string(outdir) + "/counts_corr_" + tag + ".csv";

  FILE* fm = fopen(fmult.c_str(), "w");
  fprintf(fm,
          "target,stage,paper,source_table,hadron,Q2_min,Q2_max,nu_min,nu_max,"
          "z_min,z_max,pT2_min,pT2_max,N_e,N_e_raw,S1,S2,S1_raw\n");
  for (const auto& a : macc) {
    const auto& t = a.tab;
    for (size_t iq = 0; iq < t.q2.size(); ++iq)
      for (size_t in = 0; in < t.nu.size(); ++in) {
        const size_t ie = iq * t.nu.size() + in;
        for (size_t iz = 0; iz < t.z.size(); ++iz)
          for (size_t ip = 0; ip < t.pt2.size(); ++ip) {
            const size_t ic = ie * t.ncellPerEvt() + iz * t.pt2.size() + ip;
            fprintf(fm,
                    "%s,%s,%s,%s,%s,%g,%g,%g,%g,%g,%g,%g,%g,%.10g,%.10g,%.10g,%.10g,%.10g\n",
                    target, stage, t.paper.c_str(), t.source_table.c_str(),
                    t.hadron.c_str(), t.q2.lo(iq), t.q2.hi(iq), t.nu.lo(in), t.nu.hi(in),
                    t.z.lo(iz), t.z.hi(iz), t.pt2.lo(ip), t.pt2.hi(ip), a.Ne[ie],
                    a.Ne_raw[ie], a.S1[ic], a.S2[ic], a.S1_raw[ic]);
          }
      }
  }
  fclose(fm);

  FILE* fc = fopen(fcorr.c_str(), "w");
  fprintf(fc,
          "target,stage,analysis,kind,source_table,slice_var,slice_min,slice_max,"
          "dY_bin,dY_min,dY_max,dphi_bin,dphi_min,dphi_max,N,N_raw\n");
  // N_{e'pi+} is one number per analysis, shared by every slice, and R = C_A/C_D
  // depends on its A/D ratio -- so it has to be carried alongside the pairs.
  const struct {
    const char* name;
    const CorrTotals* t;
  } totals[] = {{"dipion", &tot_dipi}, {"pionproton", &tot_pip}};
  for (const auto& tt : totals) {
    fprintf(fc, "%s,%s,%s,nlead,,,,,,,,,,,%.10g,%.10g\n", target, stage, tt.name,
            tt.t->nlead, tt.t->nlead_raw);
    fprintf(fc, "%s,%s,%s,ndis,,,,,,,,,,,%.10g,%.10g\n", target, stage, tt.name,
            tt.t->ndis, tt.t->ndis_raw);
  }
  for (const auto& a : cacc) {
    const auto& s = a.slice;
    const size_t ndy = s.two_d ? s.dY.size() : 1;
    for (size_t iy = 0; iy < ndy; ++iy)
      for (size_t ib = 0; ib < s.dphi.size(); ++ib) {
        const size_t k = iy * s.dphi.size() + ib;
        fprintf(fc, "%s,%s,%s,pairs,%s,%s,", target, stage, a.analysis.c_str(),
                s.source_table.c_str(), s.slice_var.c_str());
        if (s.has_range)
          fprintf(fc, "%g,%g,", s.smin, s.smax);
        else
          fprintf(fc, ",,");
        if (s.two_d)
          fprintf(fc, "%zu,%g,%g,", iy, s.dY.lo(iy), s.dY.hi_src(iy));
        else
          fprintf(fc, ",,,");
        fprintf(fc, "%zu,%g,%g,%.10g,%.10g\n", ib, s.dphi.lo(ib), s.dphi.hi_src(ib),
                a.N[k], a.N_raw[k]);
      }
  }
  fclose(fc);

  printf("\nscanned %lld / %lld events\n", nloop, nall);
  printf("di-pion : DIS %.0f, with leading pi+ %.0f\n", tot_dipi.ndis_raw,
         tot_dipi.nlead_raw);
  printf("pi-p    : DIS %.0f, with leading pi+ %.0f\n", tot_pip.ndis_raw,
         tot_pip.nlead_raw);
  printf("wrote %s\n      %s\n", fmult.c_str(), fcorr.c_str());
}