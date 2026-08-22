// diagnose_em_pilot.C
//
// Diagnostic for a GENIE EM pilot sample (gst flat tree).
//
// Answers three questions:
//   1. Does the EM generator list populate the DIS region at all?
//   2. Are hadrons produced there with sensible multiplicities?
//   3. What fraction of generated events survive the EG2 fiducial selection,
//      i.e. how many events must be generated for the real production?
//
// Usage:
//   root -l -b -q 'diagnose_em_pilot.C("pilot_C12.gst.root")'

#include <TFile.h>
#include <TTree.h>
#include <TH1D.h>
#include <TString.h>
#include <TMath.h>

#include <cstdio>
#include <iostream>

// --- EG2 fiducial selection (Paul et al., arXiv:2512.05083) -----------------
namespace eg2 {
  const Double_t kQ2min = 1.0,  kQ2max = 4.0;   // GeV^2
  const Double_t kWmin  = 2.0;                  // GeV
  const Double_t kNumin = 2.3,  kNumax = 4.2;   // GeV
  const Double_t kZlead = 0.5;                  // leading pi+ energy fraction
  const Double_t kPpmin = 0.35, kPpmax = 2.7;   // proton momentum, GeV/c
  const Double_t kPtmin = 0.070;                // both hadrons, GeV/c, wrt q
}

// gntpc writes the final-state arrays with this fixed capacity.
const Int_t kNPmax = 250;

void diagnose_em_pilot(const char* path, Long64_t nscan = -1)
{
  TFile* f = TFile::Open(path);
  if (!f || f->IsZombie()) { ::Error("diagnose", "cannot open %s", path); return; }

  TTree* t = dynamic_cast<TTree*>(f->Get("gst"));
  if (!t) { ::Error("diagnose", "no 'gst' tree -- did you run gntpc -f gst?"); return; }

  const Long64_t n = t->GetEntries();
  printf("file    : %s\n", path);
  printf("events  : %lld\n\n", n);

  // NOTE on kinematic variables: gst carries both the true (Q2, W, x, y) and
  // the "as if the struck nucleon were at rest" variants (Q2s, Ws, xs, ys).
  // EG2 reconstructs Q2/W/nu from the scattered electron alone, so the 's'
  // variants match the experimental definition. Using the true ones will bias
  // every comparison.
  const Bool_t hasS = (t->GetBranch("Q2s") != nullptr && t->GetBranch("Ws") != nullptr);
  const TString bQ2 = hasS ? "Q2s" : "Q2";
  const TString bW  = hasS ? "Ws"  : "W";
  if (!hasS) printf("WARNING: no Q2s/Ws branches; falling back to true kinematics.\n\n");

  // ---------------- 1. process breakdown ------------------------------------
  const TString disRegion =
      TString::Format("(%s > %g && %s > %g)", bW.Data(), eg2::kWmin,
                                              bQ2.Data(), eg2::kQ2min);

  const char* plab[] = {"QEL", "RES", "DIS", "MEC", "COH"};
  const char* pbr []  = {"qel", "res", "dis", "mec", "coh"};

  printf("process breakdown\n");
  printf("  %-6s %12s %9s %12s\n", "", "all events", "", "W>2 & Q2>1");
  for (Int_t i = 0; i < 5; ++i) {
    if (!t->GetBranch(pbr[i])) continue;
    const Long64_t a = t->GetEntries(TString::Format("%s==1", pbr[i]));
    const Long64_t d = t->GetEntries(TString::Format("%s==1 && %s", pbr[i], disRegion.Data()));
    printf("  %-6s %12lld %7.2f%% %12lld\n", plab[i], a, n ? 100.*a/n : 0., d);
  }
  const Long64_t nDis = t->GetEntries(disRegion);
  printf("  %-6s %12lld %8s %12lld  (%.3f%% of generated)\n\n",
         "TOTAL", n, "", nDis, n ? 100.*nDis/n : 0.);

  if (nDis == 0) {
    printf("STOP: nothing populates W>2, Q2>1. Either the EM list has no DIS\n");
    printf("      thread, or the beam/spline setup is wrong.\n");
    f->Close();
    return;
  }

  // ---------------- 2. hadron production in the DIS region ------------------
  const char* hlab[] = {"pi+", "pi-", "pi0", "p", "n"};
  const char* hbr []  = {"nfpip", "nfpim", "nfpi0", "nfp", "nfn"};

  printf("mean final-state multiplicity in W>2 & Q2>1\n");
  for (Int_t i = 0; i < 5; ++i) {
    if (!t->GetBranch(hbr[i])) continue;
    const TString hname = TString::Format("h_%s", hbr[i]);
    TH1D h(hname.Data(), "", 30, 0, 30);
    t->Draw(TString::Format("%s>>%s", hbr[i], hname.Data()), disRegion, "goff");
    const Double_t ent = h.GetEntries();
    const Double_t f0  = (ent > 0) ? h.GetBinContent(1) / ent : 0.;   // N == 0
    printf("  <N_%-3s> = %5.2f   (frac with >=1: %.3f)\n",
           hlab[i], h.GetMean(), 1. - f0);
  }
  printf("\n");

  // ---------------- 3. EG2 fiducial efficiency ------------------------------
  Double_t Ev = 0, El = 0, pxl = 0, pyl = 0, pzl = 0, q2 = 0, w = 0;
  Int_t    nfs = 0;
  Int_t    pdgf[kNPmax];
  Double_t Ef[kNPmax], pxf[kNPmax], pyf[kNPmax], pzf[kNPmax];

  t->SetBranchStatus("*", 0);
  const char* need[] = {"Ev","El","pxl","pyl","pzl","nf","pdgf","Ef","pxf","pyf","pzf"};
  for (auto b : need) t->SetBranchStatus(b, 1);
  t->SetBranchStatus(bQ2.Data(), 1);
  t->SetBranchStatus(bW.Data(),  1);

  t->SetBranchAddress("Ev",   &Ev);
  t->SetBranchAddress("El",   &El);
  t->SetBranchAddress("pxl",  &pxl);
  t->SetBranchAddress("pyl",  &pyl);
  t->SetBranchAddress("pzl",  &pzl);
  t->SetBranchAddress(bQ2.Data(),  &q2);
  t->SetBranchAddress(bW.Data(),   &w);
  t->SetBranchAddress("nf",   &nfs);
  t->SetBranchAddress("pdgf", pdgf);
  t->SetBranchAddress("Ef",   Ef);
  t->SetBranchAddress("pxf",  pxf);
  t->SetBranchAddress("pyf",  pyf);
  t->SetBranchAddress("pzf",  pzf);

  const Long64_t nloop = (nscan > 0 && nscan < n) ? nscan : n;
  Long64_t kin = 0, sel = 0, truncated = 0;

  for (Long64_t i = 0; i < nloop; ++i) {
    t->GetEntry(i);

    const Double_t nu = Ev - El;
    if (!(q2 > eg2::kQ2min && q2 < eg2::kQ2max)) continue;
    if (!(w  > eg2::kWmin))                      continue;
    if (!(nu > eg2::kNumin && nu < eg2::kNumax)) continue;
    ++kin;

    // unit vector along q = k - k'
    const Double_t qx = -pxl, qy = -pyl, qz = Ev - pzl;
    const Double_t qn = TMath::Sqrt(qx*qx + qy*qy + qz*qz);
    if (qn <= 0) continue;
    const Double_t ux = qx/qn, uy = qy/qn, uz = qz/qn;

    if (nfs > kNPmax) { ++truncated; continue; }

    Double_t leadPiE = -1.;
    Bool_t   haveP   = kFALSE;

    for (Int_t j = 0; j < nfs; ++j) {
      const Double_t px = pxf[j], py = pyf[j], pz = pzf[j];
      const Double_t par = px*ux + py*uy + pz*uz;
      const Double_t p2  = px*px + py*py + pz*pz;
      const Double_t pt  = TMath::Sqrt(TMath::Max(p2 - par*par, 0.));

      if (pdgf[j] == 211) {                        // pi+
        if (nu > 0 && Ef[j]/nu > eg2::kZlead && pt > eg2::kPtmin)
          if (Ef[j] > leadPiE) leadPiE = Ef[j];
      } else if (pdgf[j] == 2212) {                // proton
        const Double_t p = TMath::Sqrt(p2);
        if (p > eg2::kPpmin && p < eg2::kPpmax && pt > eg2::kPtmin) haveP = kTRUE;
      }
    }
    if (leadPiE > 0 && haveP) ++sel;
  }

  if (truncated)
    printf("WARNING: %lld events had nf > kNPmax (%d) and were skipped.\n"
           "         Raise kNPmax to match your gntpc build.\n\n", truncated, kNPmax);

  printf("EG2 fiducial selection  (scanned %lld events)\n", nloop);
  printf("  kinematic cuts only     : %8lld  (%.4f%%)\n",
         kin, nloop ? 100.*kin/nloop : 0.);
  printf("  + leading pi+ and proton: %8lld  (%.5f%%)\n",
         sel, nloop ? 100.*sel/nloop : 0.);

  if (sel > 0) {
    const Double_t eff = (Double_t)sel / (Double_t)nloop;
    printf("\n  efficiency = %.3e\n", eff);
    const Double_t want[] = {1e5, 1e6};
    for (auto W_ : want)
      printf("  -> %.0e selected events needs %.3e generated\n", W_, W_/eff);
  } else {
    printf("\n  nothing selected -- increase pilot statistics, or check that the\n");
    printf("    DIS thread produces pions at all.\n");
  }

  f->Close();
}