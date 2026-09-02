// EG2Kinematics.h
//
// Kinematic helpers for the CLAS EG2 analyses, shared by all four channels.
//
// CONVENTIONS, all of which follow the published CLAS definitions:
//
//   q      = k - k'                     (lab frame)
//   Q2     = -q^2                       (lepton-only)
//   nu     = E - E'                     (lab energy transfer)
//   y      = nu / E
//   W^2    = M_N^2 + 2 M_N nu - Q2      (struck nucleon AT REST
//                                        -- the experimental definition)
//   z_h    = E_h / nu
//   p_T    = component of the hadron momentum transverse to q
//   Y_h    = 0.5 ln[(E_h + p_z,h)/(E_h - p_z,h)], p_z along q
//   phi_h  = azimuth about q, measured from a FIXED transverse axis
//
// Rapidity differences and transverse momenta are invariant under boosts along
// q, which is exactly why Paul et al. chose them as binning variables. So it
// does not matter that we evaluate them in the lab.

#ifndef EG2_KINEMATICS_H
#define EG2_KINEMATICS_H

#include <cmath>
#include <limits>

namespace eg2 {

constexpr double kMassProton = 0.93827208;
constexpr double kMassNucleon = 0.93891875;  // isoscalar (M_p + M_n)/2
constexpr double kPi = 3.14159265358979323846;

struct Vec3 {
  double x = 0., y = 0., z = 0.;
  double mag2() const { return x * x + y * y + z * z; }
  double mag() const { return std::sqrt(mag2()); }
  double dot(const Vec3& o) const { return x * o.x + y * o.y + z * o.z; }
};

inline Vec3 cross(const Vec3& a, const Vec3& b) {
  return Vec3{a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x};
}

// Orthonormal frame with z-hat along q. The transverse axes are built from an
// arbitrary seed vector; any seed gives the same Delta phi, which is all we use.
struct QFrame {
  Vec3 uz, ux, uy;  // unit vectors
  double qmag = 0.;
  bool valid = false;

  // q = k - k' from the probe and scattered-lepton three-momenta.
  static QFrame FromMomenta(const Vec3& k, const Vec3& kp) {
    QFrame f;
    Vec3 q{k.x - kp.x, k.y - kp.y, k.z - kp.z};
    f.qmag = q.mag();
    if (!(f.qmag > 0.)) return f;
    f.uz = Vec3{q.x / f.qmag, q.y / f.qmag, q.z / f.qmag};

    // Seed: whichever global axis is least parallel to q, so the cross product
    // never degenerates.
    Vec3 seed{1., 0., 0.};
    if (std::fabs(f.uz.x) > std::fabs(f.uz.y)) seed = Vec3{0., 1., 0.};
    if (std::fabs(f.uz.x) > std::fabs(f.uz.z) &&
        std::fabs(f.uz.y) > std::fabs(f.uz.z))
      seed = Vec3{0., 0., 1.};

    Vec3 t = cross(f.uz, seed);
    const double tn = t.mag();
    if (!(tn > 0.)) return f;
    f.ux = Vec3{t.x / tn, t.y / tn, t.z / tn};
    f.uy = cross(f.uz, f.ux);
    f.valid = true;
    return f;
  }

  double pLong(const Vec3& p) const { return p.dot(uz); }

  double pTrans(const Vec3& p) const {
    const double pl = pLong(p);
    const double d = p.mag2() - pl * pl;
    return std::sqrt(d > 0. ? d : 0.);
  }

  // Azimuth about q, in (-pi, pi].
  double phi(const Vec3& p) const { return std::atan2(p.dot(uy), p.dot(ux)); }
};

// |Delta phi| folded into [0, pi]. CLAS bins in |Delta phi| because
// C(+d) and C(-d) are equal by symmetry.
inline double AbsDeltaPhi(double phi1, double phi2) {
  double d = std::fabs(phi1 - phi2);
  while (d > 2. * kPi) d -= 2. * kPi;
  if (d > kPi) d = 2. * kPi - d;
  return d;
}

// Rapidity along q. Returns +/-inf-safe large values for light-cone edges.
inline double Rapidity(double E, double pz) {
  const double num = E + pz;
  const double den = E - pz;
  if (!(num > 0.) || !(den > 0.)) return std::numeric_limits<double>::quiet_NaN();
  return 0.5 * std::log(num / den);
}

// Inclusive lepton kinematics reconstructed from the scattered electron alone.
struct DIS {
  double Ebeam = 0.;
  double Eprime = 0.;
  double nu = 0.;
  double Q2 = 0.;
  double W = 0.;   // "Ws": struck nucleon at rest
  double x = 0.;   // "xs"
  double y = 0.;
  double theta_e = 0.;  // rad, w.r.t. beam
  QFrame frame;
  bool valid = false;

  static DIS Reconstruct(const Vec3& k, double Ebeam, const Vec3& kp, double Eprime,
                         double Mn = kMassNucleon) {
    DIS d;
    d.Ebeam = Ebeam;
    d.Eprime = Eprime;
    d.nu = Ebeam - Eprime;
    // Q2 = 2(E E' - k.k') - m_e^2 - m_e^2 ~ 2(E E' - k.k') for m_e -> 0
    d.Q2 = 2. * (Ebeam * Eprime - k.dot(kp));
    const double W2 = Mn * Mn + 2. * Mn * d.nu - d.Q2;
    d.W = (W2 > 0.) ? std::sqrt(W2) : 0.;
    d.y = (Ebeam > 0.) ? d.nu / Ebeam : 0.;
    d.x = (d.nu > 0.) ? d.Q2 / (2. * Mn * d.nu) : 0.;
    const double kn = k.mag(), kpn = kp.mag();
    d.theta_e = (kn > 0. && kpn > 0.) ? std::acos(k.dot(kp) / (kn * kpn)) : 0.;
    d.frame = QFrame::FromMomenta(k, kp);
    d.valid = d.frame.valid && d.nu > 0.;
    return d;
  }
};

// Per-hadron quantities in the DIS frame.
struct Hadron {
  int pdg = 0;
  double E = 0.;
  Vec3 p;
  double z = 0.;
  double pT = 0.;
  double pT2 = 0.;
  double Y = 0.;
  double phi = 0.;
  double theta_lab = 0.;  // rad, w.r.t. beam -- needed for CLAS fiducial cuts
  double pmag = 0.;

  static Hadron Build(int pdg, double E, const Vec3& p, const DIS& d, const Vec3& beam) {
    Hadron h;
    h.pdg = pdg;
    h.E = E;
    h.p = p;
    h.pmag = p.mag();
    h.z = (d.nu > 0.) ? E / d.nu : 0.;
    h.pT = d.frame.pTrans(p);
    h.pT2 = h.pT * h.pT;
    h.Y = Rapidity(E, d.frame.pLong(p));
    h.phi = d.frame.phi(p);
    const double bn = beam.mag();
    h.theta_lab = (bn > 0. && h.pmag > 0.) ? std::acos(p.dot(beam) / (bn * h.pmag)) : 0.;
    return h;
  }
};

}  // namespace eg2

#endif  // EG2_KINEMATICS_H