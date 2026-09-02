#!/usr/bin/env python3
"""
Overlay GENIE predictions on the published CLAS EG2 measurements.

    python3 eg2_overlay.py --data ../data/clas_eg2_data --pred out --stage fsi \
                           --plots plots --syst quad --match-norm

Because the analysis filled the published cells directly (EG2Binning.h reads
its grid out of these same CSVs), the comparison is a join on the bin-edge
columns rather than an interpolation. Any row that fails to join is reported
rather than silently dropped -- an unjoined row means the prediction and the
measurement disagree about what a bin is, which is a bug, not a result.

Plotting conventions
--------------------
  * Continuation tables are merged. Moran's III/IV/V are one pi+ table with
    three nu windows, VI/VII/VIII the pi- counterpart, and IX-XII one pT^2
    table split by hadron. See TABLE_GROUP in eg2_io.py.
  * A table with more than one pT^2 bin is plotted against pT^2 and sliced in
    z; otherwise it is plotted against z. Deciding by bin counts instead breaks
    on Mineeva's Table I, which has six of each.
  * The correlation ratio R_A/D gets a log y axis: it swings by close to a
    decade between the near side and the away side, and the deviations that
    matter there are multiplicative. R_h does NOT -- it sits in a narrow band
    around unity, and a log axis there only compresses the attenuation trend
    that is the whole point of the measurement.
  * y limits are per panel. One shared range flattens every panel to the worst
    case; --share-y restores it.
  * Targets are drawn in order of Z, so deuterium leads every legend.
  * Output is PDF at dpi=500.

Two things this script will NOT do for you:

  * It will not combine overlapping tables into one chi-square. Moran's
    Table II is the (Q2,nu)-integrated marginal of III-VIII over the SAME
    events, and R/sigma/b are all derived from C. Use --fitset for a
    non-overlapping subset.

  * It will not pretend to know the bin-to-bin systematic correlations. Only
    the pi-p paper publishes a per-source breakdown. Run all three --syst
    models and quote the spread.
"""

import argparse
import os
import sys

import numpy as np
import pandas as pd

from eg2_io import (AXIS_LABEL, DATA_FILES, OBS_LABEL, TCOLOR, TMARK, Z_OF,
                    add_group, by_z, read_table, rng, slice_label)

# A defensible non-overlapping subset. Everything else is validation.
FITSET = {("Moran", "III-V"), ("Moran", "VI-VIII"), ("Mineeva", "I")}
FITSET_CORR = {("dipion", "C_dphi"), ("pionproton", "C_dphi_dY")}

KEY_MULT = ["source_table", "hadron", "target", "Q2_min", "Q2_max", "nu_min",
            "nu_max", "z_min", "z_max", "pT2_min", "pT2_max"]

# source_table is deliberately NOT a correlation join key: the derived
# observables are published in different tables from the C they come from
# (PRC 111 puts C integrated in III but R integrated in VII, sigma in XI, b in
# XII; the pi-p supplement uses S1/S2/S3/S4). The prediction inherits the C
# table label, so keying on it drops every R, sigma and b row.
KEY_CORR = ["observable", "target", "slice_var", "slice_min", "slice_max",
            "dY_bin", "dphi_bin"]

DPI = 500
EXT = "pdf"


def _round(df, cols):
    df = df.copy()
    for c in cols:
        if c in df.columns:
            df[c] = pd.to_numeric(df[c], errors="coerce").round(6)
    return df


# ---------------------------------------------------------------------------
# Joining
# ---------------------------------------------------------------------------
def join_mult(datadir, pred):
    frames = []
    for paper in ("Moran", "Mineeva"):
        d = read_table(os.path.join(datadir, DATA_FILES[paper]))
        d["paper"] = paper
        frames.append(d)
    data = pd.concat(frames, ignore_index=True)
    fl = [c for c in KEY_MULT if c.endswith(("_min", "_max"))]
    data, pred = _round(data, fl), _round(pred, fl)

    keep = ["paper"] + KEY_MULT + ["value", "stat", "n_raw_A", "Ne_raw_A", "Ne_raw_D"]
    keep = [c for c in keep if c in pred.columns]
    m = data.merge(pred[keep], on=["paper"] + KEY_MULT, how="left",
                   suffixes=("_data", "_mc"))
    return add_group(m)


def join_corr(datadir, pred):
    frames = []
    for a in ("dipion", "pionproton"):
        d = read_table(os.path.join(datadir, DATA_FILES[a]))
        d["analysis"] = a
        # The pi-p supplement has no slice_var column: its only slicing
        # variable is dY, carried as an explicit bin index.
        if "slice_var" not in d.columns:
            d["slice_var"] = "integrated"
        for c in ("slice_min", "slice_max", "dY_bin", "dY_min", "dY_max"):
            if c not in d.columns:
                d[c] = np.nan
        frames.append(d)
    data = pd.concat(frames, ignore_index=True)

    fl = ["slice_min", "slice_max"]
    data, pred = _round(data, fl), _round(pred, fl)
    for df in (data, pred):
        df["slice_var"] = df["slice_var"].fillna("integrated")
        for c in ("dY_bin", "dphi_bin"):
            df[c] = pd.to_numeric(df[c], errors="coerce")

    keep = ["analysis"] + KEY_CORR + ["source_table", "value", "stat", "n_raw"]
    p = pred[[c for c in keep if c in pred.columns]].rename(
        columns={"source_table": "source_table_mc"})
    m = data.merge(p, on=["analysis"] + KEY_CORR, how="left",
                   suffixes=("_data", "_mc"))
    dup = int(m.duplicated(subset=["analysis"] + KEY_CORR).sum())
    if dup:
        print(f"WARNING: {dup} correlation rows matched more than one prediction "
              f"-- the join key is not unique, check for a re-transcribed table")
    return m


def match_norm(m):
    """
    Rescale the MC correlation functions, per slice, so their deuterium
    integral matches the published one.

    Eq. 10 of PRC 111 normalises C so that the deuterium correlation function
    integrates to unity over 0..2pi, which forces sum_i C_D^i = n_bins/(2 pi).
    The tabulated values sit 1.5-7% above that, and not by a constant, so
    something in the published normalisation chain is not Eq. 10 as written.
    This does not touch R, sigma or b -- all normalisation-free -- and sigma
    computed from the tabulated C reproduces Table XI to +/-0.002 rad, so the
    shape of the published C is not in doubt. It only stops a 4% scale offset
    from reading as a physics disagreement in a direct C-vs-C overlay.
    """
    m = m.copy()
    isC = m.observable.isin(["C_dphi", "C_dphi_dY"])
    grp = ["analysis", "slice_var", "slice_min", "slice_max"]
    for key, g in m[isC].groupby(grp, dropna=False):
        d = g[g.target == "D"]
        sd, sm = d.value_data.sum(), d.value_mc.sum()
        if not (sd > 0 and sm > 0):
            continue
        f = sd / sm
        sel = isC.copy()
        for c, v in zip(grp, key):
            sel &= m[c].isna() if pd.isna(v) else (m[c] == v)
        m.loc[sel, "value_mc"] *= f
        m.loc[sel, "stat_mc"] *= f
    return m


# ---------------------------------------------------------------------------
# chi-square
# ---------------------------------------------------------------------------
def chi2(df, syst_model, label):
    d = df.dropna(subset=["value_data", "value_mc"]).copy()
    if d.empty:
        return None
    r = d.value_mc.values - d.value_data.values
    s_stat = np.hypot(d.stat_data.fillna(0).values, d.stat_mc.fillna(0).values)
    s_syst = d.syst.fillna(0).values if "syst" in d else np.zeros(len(d))

    if syst_model == "none":
        s = s_stat
    elif syst_model == "quad":
        s = np.hypot(s_stat, s_syst)
    elif syst_model == "norm":
        s = s_stat
        w = 1.0 / np.clip(s, 1e-12, None) ** 2
        f = np.sum(w * d.value_mc.values * d.value_data.values) / np.sum(
            w * d.value_data.values ** 2)
        r = d.value_mc.values - f * d.value_data.values
    else:
        sys.exit(f"unknown syst model {syst_model}")

    s = np.clip(s, 1e-12, None)
    c2 = float(np.sum((r / s) ** 2))
    ndf = len(r) - (1 if syst_model == "norm" else 0)
    return dict(label=label, n=len(r), chi2=c2, ndf=ndf, chi2_ndf=c2 / max(ndf, 1))


# ---------------------------------------------------------------------------
# Plotting
# ---------------------------------------------------------------------------
def _grid(n, share_y):
    import matplotlib.pyplot as plt
    ncol = min(3, max(1, n))
    nrow = int(np.ceil(n / ncol))
    fig, axes = plt.subplots(nrow, ncol, figsize=(4.6 * ncol, 3.6 * nrow),
                             squeeze=False, sharey=share_y)
    return fig, axes.ravel()


def _autoscale(ax, share_y, logy):
    if share_y:
        return
    vals = []
    for ln in ax.get_lines():
        y = np.asarray(ln.get_ydata(), dtype=float)
        vals.append(y[np.isfinite(y)])
    v = np.concatenate([x for x in vals if x.size]) if any(x.size for x in vals) else None
    if v is None or v.size == 0:
        return
    if logy:
        v = v[v > 0]
        if v.size == 0:
            return
        ax.set_ylim(float(v.min()) / 1.35, float(v.max()) * 1.35)
        return
    lo, hi = float(v.min()), float(v.max())
    pad = 0.10 * (hi - lo) if hi > lo else max(0.05 * abs(hi), 0.05)
    ax.set_ylim(lo - pad, hi + pad)


def _draw(ax, xmin, xmax, g, logy=False):
    """Data as points with total error, MC as a line with a stat band.

    Targets are drawn in order of Z so deuterium leads the legend, and each
    target's data and prediction handles stay adjacent.
    """
    drew = False
    for tgt in by_z(g.target.unique()):
        gg = g[g.target == tgt].sort_values(xmin)
        if gg.empty:
            continue
        xc = 0.5 * (gg[xmin].values + gg[xmax].values)
        col, mk = TCOLOR.get(tgt, "k"), TMARK.get(tgt, "o")
        syst = gg.syst.fillna(0).values if "syst" in gg else np.zeros(len(gg))
        tot = np.hypot(gg.stat_data.fillna(0).values, syst)
        ax.errorbar(xc, gg.value_data.values, yerr=tot, fmt=mk, ms=4.5, lw=1,
                    color=col, label=f"{tgt} data", zorder=3)
        mc = gg.value_mc.values
        mce = gg.stat_mc.fillna(0).values
        nfin = int(np.isfinite(mc).sum())
        if nfin:
            drew = True
            # A one- or two-point panel draws an invisible line, so mark the
            # points as well; several published tables have single-cell panels.
            ax.plot(xc, mc, "-", lw=1.7, color=col, alpha=0.9,
                    marker=("_" if nfin < 3 else None), ms=14, mew=1.8,
                    label=f"{tgt} GENIE", zorder=2)
            lo, hi = mc - mce, mc + mce
            if logy:
                lo = np.clip(lo, 1e-6, None)
            ax.fill_between(xc, lo, hi, color=col, alpha=0.18, lw=0, zorder=1)
    if not drew:
        ax.text(0.5, 0.5, "no prediction\nin this panel", ha="center", va="center",
                transform=ax.transAxes, fontsize=8, color="crimson")
    return drew


def _finish(fig, axes, npanel, ylabel, title, path):
    import matplotlib.pyplot as plt
    for ax in axes[npanel:]:
        ax.axis("off")
    axes[0].set_ylabel(ylabel)
    h, l = axes[0].get_legend_handles_labels()
    # get_legend_handles_labels() returns Line2D artists before ErrorbarContainer
    # ones, so relying on draw order silently reshuffles the legend into
    # "all GENIE, then all data". Sort explicitly: by Z, then data before
    # prediction. Deuterium therefore always leads.
    def order(lab):
        parts = str(lab).split()
        t = parts[0] if parts else ""
        kind = 0 if lab.endswith("data") else 1
        return (Z_OF.get(t, 999), kind, str(lab))
    pairs = sorted(zip(l, h), key=lambda x: order(x[0]))
    l = [x[0] for x in pairs]
    h = [x[1] for x in pairs]
    # Matplotlib fills column-major, so one column per target keeps each
    # target's data and prediction together.
    ncol = max(1, len(l) // 2) if len(l) % 2 == 0 else min(4, len(l))
    fig.legend(h, l, fontsize=7.5, ncol=ncol, loc="lower center",
               bbox_to_anchor=(0.5, -0.005), columnspacing=1.6, handletextpad=0.5)
    fig.suptitle(title, fontsize=10)
    fig.tight_layout(rect=(0, 0.05, 1, 1))
    fig.savefig(path, dpi=DPI)
    plt.close(fig)


def plot_mult(m, outdir, stage, share_y=False):
    import matplotlib
    matplotlib.use("Agg")

    os.makedirs(outdir, exist_ok=True)
    for (paper, grp, had), g in m.groupby(["paper", "table_group", "hadron"]):
        # A pT^2-differential table is plotted against pT^2 and sliced in z.
        npt = g.pT2_min.nunique()
        xvar, pvar = ("pT2", "z") if npt > 1 else ("z", "pT2")
        xmin, xmax = f"{xvar}_min", f"{xvar}_max"

        pcols = ["Q2_min", "Q2_max", "nu_min", "nu_max", f"{pvar}_min", f"{pvar}_max"]
        panels = sorted(set(map(tuple, g[pcols].values.tolist())))
        nq = g[["Q2_min", "Q2_max"]].drop_duplicates().shape[0]
        nnu = g[["nu_min", "nu_max"]].drop_duplicates().shape[0]
        npv = g[[f"{pvar}_min", f"{pvar}_max"]].drop_duplicates().shape[0]

        fig, axes = _grid(len(panels), share_y)
        for ax, key in zip(axes, panels):
            sel = np.ones(len(g), bool)
            for c, v in zip(pcols, key):
                sel &= (g[c].values == v)
            _draw(ax, xmin, xmax, g[sel])
            # Name only what distinguishes this panel.
            bits = []
            if nq > 1:
                bits.append(r"$Q^2$ " + rng(key[0], key[1]))
            if nnu > 1:
                bits.append(r"$\nu$ " + rng(key[2], key[3]))
            if npv > 1:
                bits.append(AXIS_LABEL[pvar].split(" [")[0] + " " + rng(key[4], key[5]))
            if not bits:
                bits = [r"$Q^2$ " + rng(key[0], key[1]) +
                        r", $\nu$ " + rng(key[2], key[3])]
            ax.set_title(", ".join(bits), fontsize=8.5)
            ax.axhline(1.0, color="gray", lw=0.7, ls=":", zorder=0)
            ax.set_xlabel(AXIS_LABEL[xvar], fontsize=9)
            ax.tick_params(labelsize=7.5)
            _autoscale(ax, share_y, False)
        safe = str(had).replace("+", "p").replace("-", "m")
        _finish(fig, axes, len(panels), OBS_LABEL["R_h"],
                f"{paper} Table {grp}, {had}   ({stage}, vs {xvar})",
                os.path.join(outdir, f"mult_{paper}_{grp}_{safe}_{stage}.{EXT}"))


def plot_corr_dphi(m, outdir, stage, share_y=False):
    """C(dphi) and R_A/D, one figure per (analysis, observable, slice_var)."""
    import matplotlib
    matplotlib.use("Agg")

    os.makedirs(outdir, exist_ok=True)
    sel = m[m.observable.isin(["C_dphi", "C_dphi_dY", "R_A_over_D"])]
    for (ana, obs, sv), g in sel.groupby(["analysis", "observable", "slice_var"]):
        logy = (obs == "R_A_over_D")
        pcols = ["slice_min", "slice_max", "dY_bin"]
        panels = sorted(set(map(tuple, g[pcols].fillna(-9e9).values.tolist())))
        fig, axes = _grid(len(panels), share_y)
        for ax, key in zip(axes, panels):
            msk = np.ones(len(g), bool)
            for c, v in zip(pcols, key):
                msk &= (g[c].isna().values if v == -9e9 else (g[c].values == v))
            sub = g[msk]
            _draw(ax, "dphi_min", "dphi_max", sub, logy=logy)
            bits = []
            if key[0] != -9e9:
                bits.append(slice_label(sv) + " " + rng(key[0], key[1]))
            if key[2] != -9e9 and sub.dY_min.notna().any():
                bits.append(r"$\Delta Y$ " +
                            rng(sub.dY_min.dropna().iloc[0], sub.dY_max.dropna().iloc[0]))
            ax.set_title(", ".join(bits) if bits else "integrated", fontsize=8.5)
            if logy:
                ax.set_yscale("log")
                ax.axhline(1.0, color="gray", lw=0.7, ls=":", zorder=0)
            ax.set_xlabel(AXIS_LABEL["dphi"], fontsize=9)
            ax.tick_params(labelsize=7.5)
            _autoscale(ax, share_y, logy)
        _finish(fig, axes, len(panels), OBS_LABEL.get(obs, obs),
                f"{ana}: {OBS_LABEL.get(obs, obs)}, sliced in {slice_label(sv)}"
                f"   ({stage})",
                os.path.join(outdir, f"corr_{ana}_{obs}_{sv}_{stage}.{EXT}"))


def plot_corr_scalar(m, outdir, stage, share_y=False):
    """
    RMS widths and broadenings.

    These are one number per (target, slice) rather than a function of dphi, so
    they need a different layout from C -- which is why they were not being
    drawn at all before. One panel per slicing variable: dY-binned values (the
    pi-p supplement) against the dY midpoint, the di-pion slices against their
    own slice midpoint, and the fully integrated value as a categorical panel
    over targets.
    """
    import matplotlib
    matplotlib.use("Agg")

    os.makedirs(outdir, exist_ok=True)
    sel = m[m.observable.isin(["sigma_RMS_width_rad", "b_broadening_rad"])]
    for (ana, obs), g in sel.groupby(["analysis", "observable"]):
        panels = []
        if g.dY_bin.notna().any():
            panels.append((r"$\Delta Y$", g[g.dY_bin.notna()], "dY_min", "dY_max"))
        rest = g[g.dY_bin.isna()]
        for sv in [s for s in rest.slice_var.unique() if s != "integrated"]:
            sub = rest[(rest.slice_var == sv) & rest.slice_min.notna()]
            if len(sub):
                panels.append((slice_label(sv), sub, "slice_min", "slice_max"))
        intg = rest[(rest.slice_var == "integrated") & rest.slice_min.isna()]
        has_int = len(intg) > 0

        n = len(panels) + (1 if has_int else 0)
        if n == 0:
            continue
        fig, axes = _grid(n, share_y)
        for ax, (lab, sub, xmin, xmax) in zip(axes, panels):
            _draw(ax, xmin, xmax, sub)
            ax.set_title(f"vs {lab}", fontsize=8.5)
            ax.set_xlabel(lab, fontsize=9)
            ax.tick_params(labelsize=7.5)
            if obs.startswith("b_"):
                ax.axhline(0.0, color="gray", lw=0.7, ls=":", zorder=0)
            _autoscale(ax, share_y, False)

        if has_int:
            ax = axes[len(panels)]
            tg = by_z(intg.target.unique())
            for i, t in enumerate(tg):
                r = intg[intg.target == t]
                syst = r.syst.fillna(0).values if "syst" in r else np.zeros(len(r))
                ax.errorbar([i], r.value_data.values[:1],
                            yerr=np.hypot(r.stat_data.fillna(0).values[:1], syst[:1]),
                            fmt=TMARK.get(t, "o"), ms=6, color=TCOLOR.get(t, "k"),
                            label=f"{t} data")
                v = r.value_mc.values[:1]
                if np.isfinite(v).all():
                    ax.errorbar([i], v, yerr=r.stat_mc.fillna(0).values[:1],
                                fmt="_", ms=18, mew=2.2, color=TCOLOR.get(t, "k"),
                                alpha=0.9, label=f"{t} GENIE")
            ax.set_xticks(range(len(tg)))
            ax.set_xticklabels(tg)
            ax.set_xlim(-0.5, len(tg) - 0.5)
            ax.set_title("integrated", fontsize=8.5)
            if obs.startswith("b_"):
                ax.axhline(0.0, color="gray", lw=0.7, ls=":", zorder=0)
            ax.tick_params(labelsize=7.5)

        # sigma is not a ratio; the di-pion CSV nonetheless carries
        # ref_target='D' on its sigma rows, so only label the reference for b.
        ref = [x for x in g.ref_target.dropna().unique() if str(x).strip()]
        reftxt = (f"   [reference: {ref[0]}]"
                  if ref and obs == "b_broadening_rad" else "")
        _finish(fig, axes, n, OBS_LABEL.get(obs, obs),
                f"{ana}: {OBS_LABEL.get(obs, obs)}{reftxt}   ({stage})",
                os.path.join(outdir, f"corr_{ana}_{obs}_{stage}.{EXT}"))


# ---------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--data", default="../data/clas_eg2_data")
    ap.add_argument("--pred", default="out")
    ap.add_argument("--stage", default="fsi")
    ap.add_argument("--plots", default="")
    ap.add_argument("--share-y", action="store_true",
                    help="one y range per figure; off by default because it "
                         "flattens the panels that matter")
    ap.add_argument("--match-norm", action="store_true",
                    help="rescale MC C per slice to the published deuterium "
                         "integral (see match_norm docstring)")
    ap.add_argument("--syst", default="quad", choices=["none", "quad", "norm"])
    ap.add_argument("--fitset", action="store_true",
                    help="restrict the chi2 to the non-overlapping subset")
    ap.add_argument("--out", default="out")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)

    pm = read_table(os.path.join(a.pred, f"pred_mult_{a.stage}.csv"))
    pc = read_table(os.path.join(a.pred, f"pred_corr_{a.stage}.csv"))
    m = join_mult(a.data, pm)
    c = join_corr(a.data, pc)
    if a.match_norm:
        c = match_norm(c)
        print("MC correlation functions rescaled to the published D integral")

    for name, df in (("multiplicity", m), ("correlation", c)):
        have = df.value_data.notna()
        missing = int((have & df.value_mc.isna()).sum())
        print(f"{name}: {len(df)} data rows, {int(have.sum())} with a value, "
              f"{missing} without a matching prediction")
        if missing:
            bad = df[have & df.value_mc.isna()]
            cols = [x for x in ("paper", "analysis", "table_group", "source_table",
                                "observable", "hadron", "target") if x in bad.columns]
            print("  unjoined groups:",
                  bad[cols].drop_duplicates().to_dict("records")[:6])

    m.to_csv(os.path.join(a.out, f"compare_mult_{a.stage}.csv"), index=False)
    c.to_csv(os.path.join(a.out, f"compare_corr_{a.stage}.csv"), index=False)

    print(f"\nchi2 (syst model: {a.syst})")
    print(f"  {'group':38s} {'n':>5s} {'chi2':>10s} {'chi2/ndf':>9s}")
    rows = []
    for (p, t, h), g in m.groupby(["paper", "table_group", "hadron"]):
        if a.fitset and (p, t) not in FITSET:
            continue
        r = chi2(g, a.syst, f"{p} T{t} {h}")
        if r:
            rows.append(r)
    for (an, o), g in c.groupby(["analysis", "observable"]):
        if a.fitset and (an, o) not in FITSET_CORR:
            continue
        r = chi2(g, a.syst, f"{an} {o}")
        if r:
            rows.append(r)
    for r in rows:
        print(f"  {r['label']:38s} {r['n']:5d} {r['chi2']:10.1f} {r['chi2_ndf']:9.2f}")
    if rows:
        tot = sum(r["chi2"] for r in rows)
        ndf = sum(r["ndf"] for r in rows)
        print(f"  {'TOTAL':38s} {sum(r['n'] for r in rows):5d} {tot:10.1f} "
              f"{tot / max(ndf, 1):9.2f}")

    if a.plots:
        plot_mult(m, a.plots, a.stage, a.share_y)
        plot_corr_dphi(c, a.plots, a.stage, a.share_y)
        plot_corr_scalar(c, a.plots, a.stage, a.share_y)
        print(f"\nplots written to {a.plots}/ (PDF, dpi={DPI})")


if __name__ == "__main__":
    main()