// EG2Binning.h
//
// The binning is NOT hardcoded. It is read out of the published-data CSVs at
// run time, so a prediction cell and a measurement cell are the same object by
// construction and the overlay is a plain join.
//
// Two schemas, matching the two CSV families:
//
//   multiplicity (Moran, Mineeva)
//     source_table,hadron,target,ref_target,Q2_min,Q2_max,nu_min,nu_max,
//     z_min,z_max,pT2_min,pT2_max,value,stat,syst,flag
//
//   correlations (Paul x2)
//     source_table,observable,target,ref_target,slice_var,slice_min,slice_max,
//     [dY_bin,dY_min,dY_max,] dphi_bin,dphi_min,dphi_max,value,stat,syst,flag
//
// Within one source_table the cells tile a grid, so lookup is a pair of binary
// searches rather than a linear scan.

#ifndef EG2_BINNING_H
#define EG2_BINNING_H

#include <algorithm>
#include <fstream>
#include <map>
#include <set>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

namespace eg2 {

// ---------------------------------------------------------------------------
// Minimal CSV reader (header row, no embedded newlines; quotes honoured)
// ---------------------------------------------------------------------------
class CsvTable {
 public:
  // Fields and header names are trimmed, as the published tables are
  // column-aligned for readability.
  explicit CsvTable(const std::string& path) {
    std::ifstream in(path);
    if (!in) throw std::runtime_error("EG2Binning: cannot open " + path);
    std::string line;
    if (!std::getline(in, line)) throw std::runtime_error("EG2Binning: empty " + path);
    header_ = Split(Strip(line));
    for (size_t i = 0; i < header_.size(); ++i) index_[header_[i]] = i;
    while (std::getline(in, line)) {
      const std::string s = Strip(line);
      if (s.empty()) continue;
      rows_.push_back(Split(s));
    }
  }

  size_t size() const { return rows_.size(); }
  bool Has(const std::string& col) const { return index_.count(col) > 0; }

  std::string Str(size_t r, const std::string& col) const {
    auto it = index_.find(col);
    if (it == index_.end()) return "";
    const std::vector<std::string>& row = rows_[r];
    return (it->second < row.size()) ? row[it->second] : "";
  }

  // Empty cell -> `dflt` (the CSVs use blanks for missing values).
  double Num(size_t r, const std::string& col, double dflt) const {
    const std::string s = Str(r, col);
    if (s.empty()) return dflt;
    try {
      return std::stod(s);
    } catch (...) {
      return dflt;
    }
  }

 private:
  static std::string Strip(std::string s) {
    while (!s.empty() && (s.back() == '\r' || s.back() == '\n')) s.pop_back();
    return s;
  }
  static std::string Trim(const std::string& s) {
    size_t a = s.find_first_not_of(" \t\r\n");
    if (a == std::string::npos) return "";
    size_t b = s.find_last_not_of(" \t\r\n");
    return s.substr(a, b - a + 1);
  }
  static std::vector<std::string> Split(const std::string& s) {
    std::vector<std::string> out;
    std::string cur;
    bool inq = false;
    for (char c : s) {
      if (c == '"') {
        inq = !inq;
      } else if (c == ',' && !inq) {
        out.push_back(cur);
        cur.clear();
      } else {
        cur.push_back(c);
      }
    }
    out.push_back(cur);
    for (auto& f : out) f = Trim(f);
    return out;
  }

  std::vector<std::string> header_;
  std::map<std::string, size_t> index_;
  std::vector<std::vector<std::string>> rows_;
};

// ---------------------------------------------------------------------------
// A set of [lo, hi) intervals. Gaps are allowed; a value in a gap matches
// nothing. The intervals are NOT guaranteed disjoint.
// ---------------------------------------------------------------------------
class Intervals {
 public:
  void Add(double lo, double hi) { raw_.insert({lo, hi}); }

  void Freeze() {
    ivs_.assign(raw_.begin(), raw_.end());
    los_.clear();
    hi_src_.clear();
    top_edge_ = 0.;
    for (const auto& iv : ivs_) {
      los_.push_back(iv.first);
      hi_src_.push_back(iv.second);
      if (iv.second > top_edge_) top_edge_ = iv.second;
    }
    overlap_ = false;
    for (size_t i = 1; i < ivs_.size(); ++i)
      if (ivs_[i].first < ivs_[i - 1].second) overlap_ = true;
  }

  // Upper edge is inclusive only for the topmost interval, so a hadron sitting
  // exactly at z = 1.0 or pT2 = 1.5 is not silently dropped.
  bool Contains(size_t i, double v) const {
    if (v < ivs_[i].first) return false;
    const bool top = (ivs_[i].second >= top_edge_);
    return v < ivs_[i].second || (top && v <= ivs_[i].second);
  }

  // Every matching interval. Returns the number written to `out`.
  int FindAll(double v, int* out, int max) const {
    int k = 0;
    if (ivs_.empty()) return 0;
    // Walk back from the last interval whose lower edge is <= v. Overlaps in
    // these tables are pathological, not structural, so the candidate window
    // is tiny.
    auto it = std::upper_bound(los_.begin(), los_.end(), v);
    if (it == los_.begin()) return 0;
    size_t i = static_cast<size_t>(it - los_.begin());
    while (i-- > 0 && k < max) {
      if (Contains(i, v)) out[k++] = static_cast<int>(i);
      if (ivs_[i].second <= v && !overlap_) break;  // disjoint: nothing lower can match
    }
    return k;
  }

  // Convenience for the strictly-disjoint axes.
  int Find(double v) const {
    int one[1];
    return FindAll(v, one, 1) ? one[0] : -1;
  }

  bool overlapping() const { return overlap_; }

  // The published bin edges are rounded: the top |dphi| bin ends at "3.14",
  // not at pi. Call after Freeze() to push the last upper edge out to the
  // true kinematic limit.
  void ExtendLastTo(double edge) {
    if (ivs_.empty()) return;
    if (edge > ivs_.back().second) {
      ivs_.back().second = edge;
      top_edge_ = edge;
    }
  }

  size_t size() const { return ivs_.size(); }
  double lo(size_t i) const { return ivs_[i].first; }
  double hi(size_t i) const { return ivs_[i].second; }
  // The edge exactly as it appears in the published table. Use this, not hi(),
  // when writing output, so the prediction joins to the measurement on
  // identical strings.
  double hi_src(size_t i) const { return hi_src_[i]; }

 private:
  std::set<std::pair<double, double>> raw_;
  std::vector<std::pair<double, double>> ivs_;
  std::vector<double> los_;
  std::vector<double> hi_src_;
  double top_edge_ = 0.;
  bool overlap_ = false;
};

// ---------------------------------------------------------------------------
// Multiplicity-ratio binning
// ---------------------------------------------------------------------------
//
// One MultTable per (source_table, hadron). Event windows are (Q2, nu)
// rectangles; hadron cells are (z, pT2) rectangles. The denominator N_e is
// counted per event window, which is what makes R_h = <n_h>_A / <n_h>_D
// well defined.
struct MultTable {
  std::string paper;    // "Moran" / "Mineeva"
  std::string source_table;
  std::string hadron;   // "pi+", "pi-", "pi0"
  Intervals q2, nu, z, pt2;
  // event index = iq2 * nnu + inu ; cell index = ievt * (nz*npt) + iz*npt + ipt
  size_t nevt() const { return q2.size() * nu.size(); }
  size_t ncellPerEvt() const { return z.size() * pt2.size(); }
  size_t ncell() const { return nevt() * ncellPerEvt(); }

  static const int kMaxMatch = 4;

  // A single event can belong to more than one published (Q2, nu) window --
  // see the note on Intervals. Both must be filled.
  int EventIndices(double Q2v, double nuv, int* out) const {
    int qa[kMaxMatch], na[kMaxMatch];
    const int nq = q2.FindAll(Q2v, qa, kMaxMatch);
    const int nn = nu.FindAll(nuv, na, kMaxMatch);
    int k = 0;
    for (int i = 0; i < nq; ++i)
      for (int j = 0; j < nn && k < kMaxMatch; ++j)
        out[k++] = qa[i] * static_cast<int>(nu.size()) + na[j];
    return k;
  }

  int CellIndices(int ievt, double zv, double pt2v, int* out) const {
    if (ievt < 0) return 0;
    int za[kMaxMatch], pa[kMaxMatch];
    const int nz = z.FindAll(zv, za, kMaxMatch);
    const int np = pt2.FindAll(pt2v, pa, kMaxMatch);
    int k = 0;
    for (int i = 0; i < nz; ++i)
      for (int j = 0; j < np && k < kMaxMatch; ++j)
        out[k++] = ievt * static_cast<int>(ncellPerEvt()) +
                   za[i] * static_cast<int>(pt2.size()) + pa[j];
    return k;
  }

  bool overlapping() const {
    return q2.overlapping() || nu.overlapping() || z.overlapping() ||
           pt2.overlapping();
  }
};

// Reads a multiplicity CSV and returns one MultTable per (source_table, hadron).
inline std::vector<MultTable> LoadMultBinning(const std::string& csv_path,
                                             const std::string& paper) {
  CsvTable t(csv_path);
  std::map<std::pair<std::string, std::string>, MultTable> m;
  for (size_t r = 0; r < t.size(); ++r) {
    const std::string st = t.Str(r, "source_table");
    const std::string h = t.Str(r, "hadron");
    auto key = std::make_pair(st, h);
    MultTable& tab = m[key];
    tab.paper = paper;
    tab.source_table = st;
    tab.hadron = h;
    tab.q2.Add(t.Num(r, "Q2_min", 0.), t.Num(r, "Q2_max", 0.));
    tab.nu.Add(t.Num(r, "nu_min", 0.), t.Num(r, "nu_max", 0.));
    tab.z.Add(t.Num(r, "z_min", 0.), t.Num(r, "z_max", 0.));
    tab.pt2.Add(t.Num(r, "pT2_min", 0.), t.Num(r, "pT2_max", 0.));
  }
  std::vector<MultTable> out;
  for (auto& kv : m) {
    kv.second.q2.Freeze();
    kv.second.nu.Freeze();
    kv.second.z.Freeze();
    kv.second.pt2.Freeze();
    out.push_back(kv.second);
  }
  return out;
}

// ---------------------------------------------------------------------------
// Correlation binning
// ---------------------------------------------------------------------------
//
// A "slice" is one (slice_var, slice_min, slice_max) triple -- e.g.
// ("dY", 0.5, 1.5) or ("integrated", nan, nan). Within a slice the pairs are
// binned in |dphi|, and for the pi-p analysis additionally in dY.
struct CorrSlice {
  std::string source_table;
  std::string slice_var;   // "integrated", "dY", "p1T", "p2T"
  double smin = 0., smax = 0.;
  bool has_range = false;
  Intervals dY;            // empty for the di-pion analysis
  Intervals dphi;
  bool two_d = false;

  size_t nbins() const {
    return (two_d ? dY.size() : 1) * dphi.size();
  }
  int Index(double dYv, double dphiv) const {
    const int b = dphi.Find(dphiv);
    if (b < 0) return -1;
    if (!two_d) return b;
    const int a = dY.Find(dYv);
    if (a < 0) return -1;
    return a * static_cast<int>(dphi.size()) + b;
  }
  bool InSlice(double dYv, double p1T, double p2T) const {
    if (!has_range) return true;
    if (slice_var == "dY") return dYv >= smin && dYv < smax;
    if (slice_var == "p1T") return p1T >= smin && p1T < smax;
    if (slice_var == "p2T") return p2T >= smin && p2T < smax;
    return true;
  }
};

// Only the `C_dphi` / `C_dphi_dY` rows define the primitive binning; R, sigma
// and b are all derived from C downstream, so filling them separately would
// double-count the same pairs.
inline std::vector<CorrSlice> LoadCorrBinning(const std::string& csv_path) {
  CsvTable t(csv_path);
  const bool has_dY = t.Has("dY_min");
  std::map<std::tuple<std::string, std::string, double, double>, CorrSlice> m;
  for (size_t r = 0; r < t.size(); ++r) {
    const std::string obs = t.Str(r, "observable");
    if (obs != "C_dphi" && obs != "C_dphi_dY") continue;
    const std::string st = t.Str(r, "source_table");
    std::string sv = t.Str(r, "slice_var");
    if (sv.empty()) sv = "integrated";
    const std::string smin_s = t.Str(r, "slice_min");
    const double smin = t.Num(r, "slice_min", 0.);
    const double smax = t.Num(r, "slice_max", 0.);
    auto key = std::make_tuple(st, sv, smin, smax);
    CorrSlice& s = m[key];
    s.source_table = st;
    s.slice_var = sv;
    s.smin = smin;
    s.smax = smax;
    s.has_range = !smin_s.empty();
    s.dphi.Add(t.Num(r, "dphi_min", 0.), t.Num(r, "dphi_max", 0.));
    if (has_dY && !t.Str(r, "dY_min").empty()) {
      s.two_d = true;
      s.dY.Add(t.Num(r, "dY_min", 0.), t.Num(r, "dY_max", 0.));
    }
  }
  std::vector<CorrSlice> out;
  for (auto& kv : m) {
    kv.second.dY.Freeze();
    kv.second.dphi.Freeze();
    kv.second.dphi.ExtendLastTo(3.14159265358979323846);
    out.push_back(kv.second);
  }
  return out;
}

}  // namespace eg2

#endif  // EG2_BINNING_H