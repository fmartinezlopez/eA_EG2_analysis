// EG2Selections.h
//
// The four CLAS EG2 selections.
//
// ---------------------------------------------------------------------------
// WHAT IS COMMON
// ---------------------------------------------------------------------------
// All four analyses use the SAME dataset (EG2, 2004, 5.014 GeV, dual target
// D2 + {C, Fe, Pb}) and the SAME inclusive DIS pre-selection:
//
//        Q^2 > 1 GeV^2 ,  W > 2 GeV ,  y < 0.85
//
// Everything below that differs. Specifically:
//
//   MORAN   PRC 105, 015201  (pi+, pi-)
//     event : Q2 > 1.0, W > 2.0, y < 0.85; (Q2, nu) slices
//     hadron: pi+ / pi-, binned in z (0.05-1.0) and pT^2 (0-1.5 GeV^2)
//     obs   : R_h = [N_h/N_e]_A / [N_h/N_e]_D
//     accept: ACCEPTANCE-CORRECTED
//
//   MINEEVA PRC 112, 035203  (pi0)
//     event : 1.0 < Q2 < 4.1, 2.2 < nu < 4.25, W > 2.0, y < 0.85
//     hadron: pi0, 0.3 < z < 1.0, 0 < pT^2 < 1.5
//     obs   : R_h = [N_h/N_e]_A / [N_h/N_e]_D
//     accept: ACCEPTANCE-CORRECTED
//
//   PAUL    PRC 111, 035201  (pi+ pi- azimuthal correlations)
//     event : Q2 > 1, W > 2, y < 0.85
//     lead  : pi+ with z > 0.5
//     sublead: every pi- with z > 0.05
//     pair  : pT > 250 MeV for BOTH pions; |p1| + |p2| < nu
//     obs   : C(dphi) = C0 (1/N_e'pi+) dN_e'pi+pi-/d(dphi), sliced in
//             dY = Y1 - Y2, p1T, p2T; R = C_A/C_D; sigma; b = sqrt(s_A^2-s_D^2)
//     accept: NOT unfolded. The p/theta fiducial cuts below are therefore part
//             of the observable definition and MUST be applied to MC.
//
//   PAUL    arXiv:2512.05083 (pi+ p azimuthal correlations)
//     event : Q2 > 1.0, W > 2.0, 2.3 < nu < 4.2
//     lead  : pi+ with z > 0.5
//     proton: 0.35 < p < 2.7 GeV/c
//     pair  : pT > 70 MeV for both; 0 < dY < 3.0 with dY = Y_pi - Y_p
//     obs   : C(dphi, dY); R = C_A/C_D; sigma; b = +/-sqrt|s_A^2 - s_C^2|
//             * CARBON reference for b, not deuterium *
//     accept: as above -- fiducial cuts are part of the definition.
//
// ---------------------------------------------------------------------------
// THE AZIMUTHAL-HOLE SUBTLETY
// ---------------------------------------------------------------------------
// CLAS had six-fold azimuthal sector structure, which carves holes in phi and
// therefore distorts dphi directly. The published correlation functions were
// corrected for this with a data-driven mixed-event factor M^i, i.e. they are
// corrected back to a detector with UNIFORM azimuthal acceptance.
//
// A predicted sample has uniform azimuthal acceptance by construction. So the
// consistent procedure is:
//   - apply the momentum/polar-angle fiducial cuts (they are phi-independent,
//     so they change the pair sample without distorting dphi), and
//   - apply NO mixed-event correction to MC.

#ifndef EG2_SELECTIONS_H
#define EG2_SELECTIONS_H

#include <cmath>
#include <limits>

#include "EG2Kinematics.h"

namespace eg2 {

constexpr double kDeg = kPi / 180.;
constexpr double kInf = std::numeric_limits<double>::infinity();

// --------------------------------------------------------------------------
// Shared DIS cuts
// --------------------------------------------------------------------------
struct DISCuts {
  double Q2min = 1.0;
  double Q2max = kInf;
  double Wmin = 2.0;
  double numin = 0.0;
  double numax = kInf;
  double ymax = 0.85;

  bool Pass(const DIS& d) const {
    if (!d.valid) return false;
    if (!(d.Q2 > Q2min && d.Q2 < Q2max)) return false;
    if (!(d.W > Wmin)) return false;
    if (!(d.nu > numin && d.nu < numax)) return false;
    if (!(d.y < ymax)) return false;
    return true;
  }
};

// --------------------------------------------------------------------------
// CLAS fiducial cuts (correlation analyses only)
// --------------------------------------------------------------------------
struct Fiducial {
  bool enabled = true;

  // Electron -- coarse stand-in, see [V4].
  double e_theta_min = 8. * kDeg;
  double e_theta_max = 45. * kDeg;
  double e_pmin = 0.5;

  // pi+ : 10 < theta < 120 deg, p > 200 MeV   (PRC 111, Sec. II)
  double pip_theta_min = 10. * kDeg;
  double pip_theta_max = 120. * kDeg;
  double pip_pmin = 0.200;

  // pi- : momentum threshold is theta-dependent because the toroid bent
  // negatives toward the beam pipe.  p > 700 MeV for 25-30 deg,
  // p > 500 MeV for 30-40 deg, p > 350 MeV above 40 deg.
  double pim_theta_min = 25. * kDeg;
  double pim_theta_max = 120. * kDeg;

  // proton -- see [V3]
  double p_theta_min = 0.;
  double p_theta_max = 180. * kDeg;

  bool PassElectron(const DIS& d, double pe) const {
    if (!enabled) return true;
    return d.theta_e > e_theta_min && d.theta_e < e_theta_max && pe > e_pmin;
  }

  bool PassPiPlus(const Hadron& h) const {
    if (!enabled) return true;
    return h.theta_lab > pip_theta_min && h.theta_lab < pip_theta_max &&
           h.pmag > pip_pmin;
  }

  bool PassPiMinus(const Hadron& h) const {
    if (!enabled) return true;
    const double th = h.theta_lab;
    if (!(th > pim_theta_min && th < pim_theta_max)) return false;
    if (th < 30. * kDeg) return h.pmag > 0.700;
    if (th < 40. * kDeg) return h.pmag > 0.500;
    return h.pmag > 0.350;
  }

  bool PassProton(const Hadron& h) const {
    if (!enabled) return true;
    return h.theta_lab > p_theta_min && h.theta_lab < p_theta_max;
  }
};

// --------------------------------------------------------------------------
// Per-analysis configuration
// --------------------------------------------------------------------------

// Moran (charged pions) and Mineeva (neutral pions): the (Q2, nu, z, pT^2)
// windows are NOT hardcoded -- they are read from the published-data CSVs so
// that prediction and measurement land in identical cells by construction.
// Only the analysis-wide guards live here.
struct MultiplicityConfig {
  DISCuts dis;                 // Q2min/Wmin/ymax; the windows come from the CSV
  bool use_fiducial = false;   // acceptance-corrected data -> no fiducial cuts
};

// Paul PRC 111 : di-pion azimuthal correlations
struct DiPionConfig {
  DISCuts dis{1.0, kInf, 2.0, 0.0, kInf, 0.85};
  double z_lead_min = 0.50;    // leading pi+
  double z_sub_min = 0.05;     // subleading pi-
  double pT_min = 0.250;       // BOTH pions, GeV, w.r.t. q
  bool apply_psum_cut = true;  // |p1| + |p2| < nu
  int n_dphi_bins = 8;         // equal width in |dphi| over [0, pi]
  Fiducial fid;
};

// Paul arXiv:2512.05083 : pion-proton azimuthal correlations
struct PiPConfig {
  DISCuts dis{1.0, kInf, 2.0, 2.3, 4.2, 0.85};  // [V1] Q2max left open
  double z_lead_min = 0.50;
  double p_proton_min = 0.35;
  double p_proton_max = 2.70;
  double pT_min = 0.070;       // both hadrons
  double dY_min = 0.0;
  double dY_max = 3.0;         // dY = Y_pi - Y_p
  bool apply_psum_cut = true;  // [V2] |p_pi| + T_p < nu
  int n_dphi_bins = 8;
  Fiducial fid;
};

// Energy-budget cut, stated in the papers as |p_1| + |p_2| < nu -- on the
// MOMENTUM magnitudes, not the energies.
inline bool PassPSum(const Hadron& a, const Hadron& b, double nu) {
  return (a.pmag + b.pmag) < nu;
}

}  // namespace eg2

#endif  // EG2_SELECTIONS_H