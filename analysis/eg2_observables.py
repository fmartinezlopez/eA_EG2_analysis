#!/usr/bin/env python3
"""
Counts -> observables.

Reads the per-target counts written by EG2Analysis.C and produces predictions
in exactly the schema of the published CSVs, so that overlaying is a plain join
on the bin-edge columns.

    python3 eg2_observables.py --counts out --stage fsi --out out

Observables built here
----------------------
  R_h        = <n_h>_A / <n_h>_D                       (Moran, Mineeva)
  C(dphi)    = raw / (w_dphi * 2 * sum_j raw_D,j)      (Paul x2)
  C(dphi,dY) = raw / (w_dphi * w_dY * 2 * sum_j raw_D,j)
  R          = C_A / C_D  ==  raw_A / raw_D            (normalisation cancels)
  sigma      = sqrt( sum C (dphi - pi)^2 / sum C )
  b          = sqrt(sigma_A^2 - sigma_D^2)             DEUTERIUM ref  (di-pion)
             = +/-sqrt|sigma_T^2 - sigma_C^2|          CARBON ref     (pi-p)

Conventions:

1. The two correlation papers use DIFFERENT reference targets for b. The
   di-pion paper (PRC 111, Eq. 4) uses deuterium. The pi-p paper uses carbon.

2. <n_h> = S1/N_e is a mean multiplicity, so its variance is
   (S2/N_e - <n>^2)/N_e, not N_h.

Statistical errors are propagated by Poisson toys rather than by linearised
formulae, because sigma and b are non-linear in the bin contents.
"""

import argparse
import glob
import os
import sys

import numpy as np
import pandas as pd

from eg2_io import read_table

NUCLEI = ["C", "Fe", "Pb"]
KEY_MULT = ["paper", "source_table", "hadron", "Q2_min", "Q2_max", "nu_min", "nu_max",
            "z_min", "z_max", "pT2_min", "pT2_max"]
RNG = np.random.default_rng(20260824)


# ---------------------------------------------------------------------------
def load_counts(counts_dir, stage, kind):
    pat = os.path.join(counts_dir, f"counts_{kind}_*_{stage}.csv")
    files = sorted(glob.glob(pat))
    if not files:
        sys.exit(f"no counts files matching {pat}")
    df = pd.concat([read_table(f) for f in files], ignore_index=True)
    for c in df.columns:
        if c.endswith(("_min", "_max")):
            df[c] = df[c].round(6)
    return df


# ---------------------------------------------------------------------------
# Multiplicity ratios
# ---------------------------------------------------------------------------
def build_mult(df, ntoys):
    """R_h = <n>_A / <n>_D with the multiplicity variance carried properly."""
    df = df.copy()
    df["mean"] = np.where(df.N_e > 0, df.S1 / df.N_e, np.nan)
    # var of the per-event multiplicity, then of its mean
    m2 = np.where(df.N_e > 0, df.S2 / df.N_e, np.nan)
    df["var_mean"] = np.where(df.N_e > 0, (m2 - df["mean"] ** 2) / df.N_e, np.nan)
    # A single-event-per-cell sample has zero sample variance; fall back to
    # Poisson so that a 1-count bin does not claim a zero error.
    poisson = np.where(df.N_e > 0, df.S1 / df.N_e ** 2, np.nan)
    df["var_mean"] = np.where(df["var_mean"] > 0, df["var_mean"], poisson)

    den = df[df.target == "D"].set_index(KEY_MULT)
    out = []
    for tgt in NUCLEI:
        num = df[df.target == tgt].set_index(KEY_MULT)
        common = num.index.intersection(den.index)
        n, d = num.loc[common], den.loc[common]
        with np.errstate(divide="ignore", invalid="ignore"):
            R = n["mean"].values / d["mean"].values
            rel2 = (n["var_mean"].values / n["mean"].values ** 2
                    + d["var_mean"].values / d["mean"].values ** 2)
            stat = np.abs(R) * np.sqrt(np.clip(rel2, 0, None))
        rec = pd.DataFrame(list(common), columns=KEY_MULT)
        rec["target"] = tgt
        rec["ref_target"] = "D"
        rec["value"] = R
        rec["stat"] = stat
        rec["n_raw_A"] = n["S1_raw"].values
        rec["n_raw_D"] = d["S1_raw"].values
        rec["Ne_raw_A"] = n["N_e_raw"].values
        rec["Ne_raw_D"] = d["N_e_raw"].values
        out.append(rec)
    res = pd.concat(out, ignore_index=True)
    res.loc[~np.isfinite(res.value), ["value", "stat"]] = np.nan
    return res


# ---------------------------------------------------------------------------
# Correlation functions
# ---------------------------------------------------------------------------
def _sigma(C, dphi_c):
    """RMS width of C about dphi = pi. Independent of the normalisation."""
    s = C.sum()
    if not s > 0:
        return np.nan
    return np.sqrt(np.sum(C * (dphi_c - np.pi) ** 2) / s)


def build_corr(df, analysis, b_reference, ntoys):
    """
    One row per (slice, dY bin, dphi bin, target, observable).

    `b_reference` is "D" for the di-pion paper and "C" for the pi-p paper.
    """
    pairs = df[(df.analysis == analysis) & (df.kind == "pairs")].copy()
    if pairs.empty:
        return pd.DataFrame()
    lead = (df[(df.analysis == analysis) & (df.kind == "nlead")]
            .set_index("target")["N_raw"].to_dict())

    if "slice_var" not in pairs.columns:
        pairs["slice_var"] = "integrated"
    pairs["slice_var"] = pairs["slice_var"].fillna("integrated")
    for c in ("slice_min", "slice_max"):
        if c not in pairs.columns:
            pairs[c] = np.nan
    slice_cols = ["source_table", "slice_var", "slice_min", "slice_max"]
    pairs["slice_min"] = pairs["slice_min"].fillna(-999.0)
    pairs["slice_max"] = pairs["slice_max"].fillna(-999.0)
    targets = [t for t in ["D", "C", "Fe", "Pb"] if t in pairs.target.unique()]
    if "D" not in targets:
        sys.exit(f"{analysis}: deuterium counts missing -- every observable is a D ratio")

    rows = []
    for skey, sdf in pairs.groupby(slice_cols, dropna=False):
        st, sv, smin, smax = skey
        two_d = sdf["dY_bin"].notna().any()
        idx_cols = (["dY_bin", "dphi_bin"] if two_d else ["dphi_bin"])
        edge_cols = (["dY_min", "dY_max", "dphi_min", "dphi_max"] if two_d
                     else ["dphi_min", "dphi_max"])

        grid = (sdf[sdf.target == "D"].sort_values(idx_cols)[idx_cols + edge_cols]
                .reset_index(drop=True))
        nb = len(grid)
        ndphi = int(grid["dphi_bin"].max()) + 1

        # Equal-width |dphi| bins over [0, pi] -- the printed 2.75-3.14 edge is
        # pi/8 rounded, and using it as a width biases the tail bin.
        w_dphi = np.pi / ndphi
        w_dY = ((grid["dY_max"] - grid["dY_min"]).values if two_d else np.ones(nb))
        dphi_c = (grid["dphi_bin"].values + 0.5) * w_dphi

        Nraw = {}
        for t in targets:
            s = (sdf[sdf.target == t].sort_values(idx_cols)
                 .set_index(idx_cols)["N_raw"])
            Nraw[t] = s.reindex(grid.set_index(idx_cols).index).fillna(0.0).values

        def observables(Nt, leadt):
            """raw, C, R, sigma for one toy (or the nominal)."""
            raw = {t: (Nt[t] / leadt[t] if leadt[t] > 0 else np.full(nb, np.nan))
                   for t in targets}
            norm = 2.0 * np.nansum(raw["D"])
            C = {t: (raw[t] / (w_dphi * w_dY * norm) if norm > 0
                     else np.full(nb, np.nan)) for t in targets}
            R = {t: np.where(raw["D"] > 0, raw[t] / raw["D"], np.nan) for t in targets}
            # sigma: per dY bin, plus an "all dY" value for the 2D case
            sig = {}
            for t in targets:
                if two_d:
                    per = {}
                    for iy in sorted(grid["dY_bin"].unique()):
                        m = grid["dY_bin"].values == iy
                        per[int(iy)] = _sigma(C[t][m], dphi_c[m])
                    tot = np.zeros(ndphi)
                    for ib in range(ndphi):
                        tot[ib] = np.nansum(C[t][grid["dphi_bin"].values == ib])
                    per[-1] = _sigma(tot, (np.arange(ndphi) + 0.5) * w_dphi)
                    sig[t] = per
                else:
                    sig[t] = {-1: _sigma(C[t], dphi_c)}
            return C, R, sig

        leadn = {t: lead.get(t, 0.0) for t in targets}
        C0, R0, S0 = observables(Nraw, leadn)

        # --- Poisson toys -------------------------------------------------
        Ctoy = {t: np.empty((ntoys, nb)) for t in targets}
        Rtoy = {t: np.empty((ntoys, nb)) for t in targets}
        keys = sorted(S0["D"].keys())
        Stoy = {t: {k: np.empty(ntoys) for k in keys} for t in targets}
        for i in range(ntoys):
            Nt = {t: RNG.poisson(np.clip(Nraw[t], 0, None)).astype(float) for t in targets}
            lt = {t: float(RNG.poisson(max(leadn[t], 0))) for t in targets}
            c, r, s = observables(Nt, lt)
            for t in targets:
                Ctoy[t][i] = c[t]
                Rtoy[t][i] = r[t]
                for k in keys:
                    Stoy[t][k][i] = s[t][k]

        def err(a):
            with np.errstate(invalid="ignore"):
                return np.nanstd(a, axis=0)

        base = grid[edge_cols + idx_cols].copy()
        base["source_table"] = st
        base["slice_var"] = sv
        base["slice_min"] = np.nan if smin == -999.0 else smin
        base["slice_max"] = np.nan if smax == -999.0 else smax
        base["analysis"] = analysis

        for t in targets:
            r = base.copy()
            r["observable"] = "C_dphi_dY" if two_d else "C_dphi"
            r["target"] = t
            r["ref_target"] = ""
            r["value"] = C0[t]
            r["stat"] = err(Ctoy[t])
            r["n_raw"] = Nraw[t]
            rows.append(r)
            if t != "D":
                r = base.copy()
                r["observable"] = "R_A_over_D"
                r["target"] = t
                r["ref_target"] = "D"
                r["value"] = R0[t]
                r["stat"] = err(Rtoy[t])
                r["n_raw"] = Nraw[t]
                rows.append(r)

        # --- widths and broadenings --------------------------------------
        for k in keys:
            meta = {"analysis": analysis, "source_table": st, "slice_var": sv,
                    "slice_min": np.nan if smin == -999.0 else smin,
                    "slice_max": np.nan if smax == -999.0 else smax,
                    "dphi_bin": np.nan, "dphi_min": np.nan, "dphi_max": np.nan}
            if two_d and k >= 0:
                m = grid["dY_bin"].values == k
                meta.update(dY_bin=k, dY_min=grid["dY_min"].values[m][0],
                            dY_max=grid["dY_max"].values[m][0])
            else:
                meta.update(dY_bin=np.nan, dY_min=np.nan, dY_max=np.nan)

            for t in targets:
                rows.append(pd.DataFrame([{**meta, "observable": "sigma_RMS_width_rad",
                                           "target": t, "ref_target": "",
                                           "value": S0[t][k],
                                           "stat": np.nanstd(Stoy[t][k]),
                                           "n_raw": np.nan}]))
            ref = b_reference
            if ref in S0:
                for t in targets:
                    if t == ref:
                        continue
                    d0 = S0[t][k] ** 2 - S0[ref][k] ** 2
                    bv = np.sign(d0) * np.sqrt(abs(d0))
                    dt = Stoy[t][k] ** 2 - Stoy[ref][k] ** 2
                    bt = np.sign(dt) * np.sqrt(np.abs(dt))
                    rows.append(pd.DataFrame([{**meta, "observable": "b_broadening_rad",
                                               "target": t, "ref_target": ref,
                                               "value": bv,
                                               "stat": np.nanstd(bt),
                                               "n_raw": np.nan}]))

    res = pd.concat(rows, ignore_index=True)
    cols = ["analysis", "source_table", "observable", "target", "ref_target",
            "slice_var", "slice_min", "slice_max", "dY_bin", "dY_min", "dY_max",
            "dphi_bin", "dphi_min", "dphi_max", "value", "stat", "n_raw"]
    for c in cols:
        if c not in res:
            res[c] = np.nan
    return res[cols]


# ---------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--counts", default="out", help="directory of counts_*.csv")
    ap.add_argument("--stage", default="fsi", choices=["fsi", "prefsi"])
    ap.add_argument("--out", default="out")
    ap.add_argument("--ntoys", type=int, default=400,
                    help="Poisson toys for the statistical errors")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)

    m = build_mult(load_counts(a.counts, a.stage, "mult"), a.ntoys)
    fm = os.path.join(a.out, f"pred_mult_{a.stage}.csv")
    m.to_csv(fm, index=False)

    cdf = load_counts(a.counts, a.stage, "corr")
    parts = [p for p in (build_corr(cdf, "dipion", "D", a.ntoys),
                         build_corr(cdf, "pionproton", "C", a.ntoys)) if not p.empty]
    if parts:
        c = pd.concat(parts, ignore_index=True)
    else:
        print("no correlation pairs found -- writing an empty prediction table")
        c = pd.DataFrame(columns=[
            "analysis", "source_table", "observable", "target", "ref_target",
            "slice_var", "slice_min", "slice_max", "dY_bin", "dY_min", "dY_max",
            "dphi_bin", "dphi_min", "dphi_max", "value", "stat", "n_raw"])
    fc = os.path.join(a.out, f"pred_corr_{a.stage}.csv")
    c.to_csv(fc, index=False)

    print(f"{fm}: {len(m)} rows")
    print(f"{fc}: {len(c)} rows")
    thin = m[(m.Ne_raw_A < 100) | (m.Ne_raw_D < 100)]
    if len(thin):
        print(f"WARNING: {len(thin)} multiplicity cells have <100 MC events in a "
              f"denominator -- treat their R as indicative only")


if __name__ == "__main__":
    main()