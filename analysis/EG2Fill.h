// EG2Fill.h
//
// Accumulators plus the per-event fill logic for all four analyses.

#ifndef EG2_FILL_H
#define EG2_FILL_H

#include <string>
#include <vector>

#include "EG2Binning.h"
#include "EG2Kinematics.h"
#include "EG2Selections.h"

namespace eg2 {

inline int PdgOfSpecies(const std::string& h) {
  if (h == "pi+") return 211;
  if (h == "pi-") return -211;
  if (h == "pi0") return 111;
  if (h == "p" || h == "proton") return 2212;
  return 0;
}

// ---------------------------------------------------------------------------
// Multiplicity accumulator
// ---------------------------------------------------------------------------
//
// R_h is a ratio of MEAN MULTIPLICITIES, <n_h> = N_h / N_e, so the statistical
// error needs the multiplicity variance, not sqrt(N_h): an event contributing
// two pions to the same cell contributes them fully correlated. Hence S2.
struct MultAcc {
  MultTable tab;
  int pdg = 0;
  std::vector<double> Ne, Ne_raw;
  std::vector<double> S1, S2, S1_raw;
  std::vector<int> scratch;
  std::vector<int> touched;

  void Init(const MultTable& t) {
    tab = t;
    pdg = PdgOfSpecies(t.hadron);
    Ne.assign(t.nevt(), 0.);
    Ne_raw.assign(t.nevt(), 0.);
    S1.assign(t.ncell(), 0.);
    S2.assign(t.ncell(), 0.);
    S1_raw.assign(t.ncell(), 0.);
    scratch.assign(t.ncell(), 0);
  }

  void FillEvent(const DIS& d, const std::vector<Hadron>& had, double w) {
    int ev[MultTable::kMaxMatch];
    const int ne = tab.EventIndices(d.Q2, d.nu, ev);
    if (ne == 0) return;

    touched.clear();
    for (int e = 0; e < ne; ++e) {
      Ne[ev[e]] += w;
      Ne_raw[ev[e]] += 1.;
      for (const auto& h : had) {
        if (h.pdg != pdg) continue;
        int cell[MultTable::kMaxMatch];
        const int nc = tab.CellIndices(ev[e], h.z, h.pT2, cell);
        for (int c = 0; c < nc; ++c) {
          if (scratch[cell[c]] == 0) touched.push_back(cell[c]);
          ++scratch[cell[c]];
        }
      }
    }
    for (int ic : touched) {
      const double nh = scratch[ic];
      S1[ic] += w * nh;
      S2[ic] += w * nh * nh;
      S1_raw[ic] += nh;
      scratch[ic] = 0;
    }
  }
};

// ---------------------------------------------------------------------------
// Correlation accumulator
// ---------------------------------------------------------------------------
struct CorrAcc {
  std::string analysis;  // "dipion" | "pionproton"
  CorrSlice slice;
  std::vector<double> N, N_raw;

  void Init(const std::string& a, const CorrSlice& s) {
    analysis = a;
    slice = s;
    N.assign(s.nbins(), 0.);
    N_raw.assign(s.nbins(), 0.);
  }

  void FillPair(double dY, double dphi, double p1T, double p2T, double w) {
    if (!slice.InSlice(dY, p1T, p2T)) return;
    const int ib = slice.Index(dY, dphi);
    if (ib < 0) return;
    N[ib] += w;
    N_raw[ib] += 1.;
  }
};

// Running totals that the correlation functions are normalised against.
struct CorrTotals {
  double ndis = 0., ndis_raw = 0.;
  double nlead = 0., nlead_raw = 0.;
};

// ---------------------------------------------------------------------------
// Leading pi+ : unique by construction, because z > 0.5 for two pions would
// need more than all of nu. The "highest E" tie-break is therefore cosmetic.
// ---------------------------------------------------------------------------
inline const Hadron* FindLeadingPiPlus(const std::vector<Hadron>& had, double zmin,
                                       double pTmin, const Fiducial& fid) {
  const Hadron* lead = nullptr;
  for (const auto& h : had) {
    if (h.pdg != 211) continue;
    if (!(h.z > zmin)) continue;
    if (!(h.pT > pTmin)) continue;
    if (!fid.PassPiPlus(h)) continue;
    if (!lead || h.E > lead->E) lead = &h;
  }
  return lead;
}

// ---------------------------------------------------------------------------
// Di-pion channel (Paul, PRC 111)
// ---------------------------------------------------------------------------
inline void FillDiPion(const DIS& d, const std::vector<Hadron>& had,
                       const DiPionConfig& cfg, double eleP, double w,
                       CorrTotals* tot, std::vector<CorrAcc>* accs) {
  if (!cfg.dis.Pass(d)) return;
  if (!cfg.fid.PassElectron(d, eleP)) return;
  tot->ndis += w;
  tot->ndis_raw += 1.;

  const Hadron* lead = FindLeadingPiPlus(had, cfg.z_lead_min, cfg.pT_min, cfg.fid);
  if (!lead) return;
  tot->nlead += w;
  tot->nlead_raw += 1.;

  for (const auto& h : had) {
    if (h.pdg != -211) continue;
    if (!(h.z > cfg.z_sub_min)) continue;
    if (!(h.pT > cfg.pT_min)) continue;
    if (!cfg.fid.PassPiMinus(h)) continue;
    if (cfg.apply_psum_cut && !PassPSum(*lead, h, d.nu)) continue;

    const double dY = lead->Y - h.Y;
    if (dY != dY) continue;  // NaN guard
    const double dphi = AbsDeltaPhi(lead->phi, h.phi);
    for (auto& a : *accs) {
      if (a.analysis != "dipion") continue;
      a.FillPair(dY, dphi, lead->pT, h.pT, w);
    }
  }
}

// ---------------------------------------------------------------------------
// Pion-proton channel (Paul, arXiv:2512.05083)
// ---------------------------------------------------------------------------
inline void FillPionProton(const DIS& d, const std::vector<Hadron>& had,
                           const PiPConfig& cfg, double eleP, double w, CorrTotals* tot,
                           std::vector<CorrAcc>* accs) {
  if (!cfg.dis.Pass(d)) return;
  if (!cfg.fid.PassElectron(d, eleP)) return;
  tot->ndis += w;
  tot->ndis_raw += 1.;

  const Hadron* lead = FindLeadingPiPlus(had, cfg.z_lead_min, cfg.pT_min, cfg.fid);
  if (!lead) return;
  tot->nlead += w;
  tot->nlead_raw += 1.;

  for (const auto& h : had) {
    if (h.pdg != 2212) continue;
    if (!(h.pmag > cfg.p_proton_min && h.pmag < cfg.p_proton_max)) continue;
    if (!(h.pT > cfg.pT_min)) continue;
    if (!cfg.fid.PassProton(h)) continue;
    if (cfg.apply_psum_cut && !PassPSum(*lead, h, d.nu)) continue;

    const double dY = lead->Y - h.Y;  // pion minus proton
    if (dY != dY) continue;
    if (!(dY > cfg.dY_min && dY < cfg.dY_max)) continue;
    const double dphi = AbsDeltaPhi(lead->phi, h.phi);
    for (auto& a : *accs) {
      if (a.analysis != "pionproton") continue;
      a.FillPair(dY, dphi, lead->pT, h.pT, w);
    }
  }
}

}  // namespace eg2

#endif  // EG2_FILL_H