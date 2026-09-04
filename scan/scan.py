#!/usr/bin/env python3
"""
Scan pipeline: check completeness, merge counts, collect chi2 curves.

    . ./setup.sh          # provides EA_ANALYSIS, EA_DATA, EA_LISTDIR

    # everything, in order
    python3 scan/scan.py --base /path/to/data \
        --param fz-ct0pion --values 0.1,0.2,0.342,0.6,1.0 \
        --out merged --expect "D2=439,C12=90,Fe56=125,Pb208=57"

    # just the audit, and write retry lists for what is missing
    python3 scan.py ... --stages check --write-retry

    # re-collect after editing the systematic model, without re-merging
    python3 scan/scan.py ... --stages collect --syst norm

Three stages, run in order and aborting on failure, because each depends on the
one before:

  check    Are all inputs present at every parameter value?  Completeness is a
           SET DIFFERENCE against the input lists, so missing inputs can be
           named and resubmitted as a shorter list.

  merge    Sum the per-job counts into the layout eg2_observables.py wants.
           EG2Analysis writes raw sums, so counts from disjoint file subsets add
           and the merge reproduces a single pass exactly.  Then run
           eg2_observables.py and eg2_overlay.py at each value.

  collect  chi2 versus the parameter, per observable group, reusing
           eg2_overlay.chi2 so the numbers match what the overlay prints.
           Reports the delta-chi2 spans that set the anchor-design range.
"""

import argparse
import glob
import os
import re
import subprocess
import sys

import numpy as np
import pandas as pd

# Paths come from setup.sh.
def ea_path(var, what):
    v = os.environ.get(var)
    if not v:
        sys.exit(f"{var} is not set -- source setup.sh first.\n"
                 f"  It should point at {what}.")
    if not os.path.isdir(v):
        sys.exit(f"{var} = {v}\n  does not exist (expected {what}).")
    return os.path.abspath(v)


TARGETS = {"D2": "D", "C12": "C", "Fe56": "Fe", "Pb208": "Pb"}
SUM_MULT = ["N_e", "N_e_raw", "S1", "S2", "S1_raw"]
SUM_CORR = ["N", "N_raw"]
ROUND = 6
PROC_RE = r"counts_{k}_{lab}_{st}_(.+)_(\d+)\.csv$"
STEM_RE = r"counts_{k}_{lab}_{st}__(.+)\.csv$"


# ------------------------------------------------------------------ helpers
def tag_of(v):
    return v.replace(".", "p")


def stem_of(path):
    b = os.path.basename(path.strip())
    for suf in (".roi.ghep.root", ".ghep.root"):
        if b.endswith(suf):
            b = b[: -len(suf)]
            break
    return re.sub(r"[^A-Za-z0-9._-]", "_", b)


def read_list(path):
    if not os.path.exists(path):
        return None
    return [l.strip() for l in open(path)
            if l.strip() and not l.strip().startswith("#")]


def point_dir(base, tgt, param, v):
    return os.path.join(base, tgt, f"{param}_{tag_of(v)}")


def gather(bases, tgt, param, v, kind, lab, stage):
    out = []
    for b in bases:
        out += sorted(glob.glob(os.path.join(
            point_dir(b, tgt, param, v), f"counts_{kind}_{lab}_{stage}*.csv")))
    return out


# ------------------------------------------------------------------ stage: check
def file_stem(path, lab, stage, order):
    """Input stem a counts file came from, or None."""
    b = os.path.basename(path)
    m = re.search(STEM_RE.format(k="[a-z]+", lab=lab, st=stage), b)
    if m:
        return m.group(1)
    m = re.search(PROC_RE.format(k="[a-z]+", lab=lab, st=stage), b)
    if m:
        proc = int(m.group(2))
        if 0 <= proc < len(order):
            return stem_of(order[proc])
    return None


def common_stems(a, values, tgt, order):
    """Stems present at EVERY value.

    A scan measures how an observable MOVES with the parameter, so the points
    must be built from the same events. Self-normalisation protects each point
    individually, but it says nothing about the DIFFERENCE between two points
    computed on different event sets, and the difference is the measurement.
    """
    lab = TARGETS.get(tgt, tgt)
    per = []
    for v in values:
        files = gather(a.base, tgt, a.param, v, "corr", lab, a.stage)
        per.append({st for st in (file_stem(f, lab, a.stage, order) for f in files)
                    if st})
    return set.intersection(*per) if per else set()


def scan_present(files, lab, stage, order):
    """-> (present stems, naming, duplicates)"""
    if not files:
        return set(), None, {}
    stem_pat = STEM_RE.format(k="corr", lab=lab, st=stage)
    hits = [(f, re.search(stem_pat, os.path.basename(f))) for f in files]
    if any(m for _, m in hits):
        return {m.group(1) for _, m in hits if m}, "stem", {}

    # PROCESS naming: the payload takes line PROCESS+1 of the comment-stripped
    # list, so the index identifies the input -- provided the list is unchanged.
    proc_pat = PROC_RE.format(k="corr", lab=lab, st=stage)
    got, seen = set(), {}
    for f in files:
        m = re.search(proc_pat, os.path.basename(f))
        if not m:
            continue
        cluster, proc = m.group(1), int(m.group(2))
        if not 0 <= proc < len(order):
            continue
        st = stem_of(order[proc])
        seen.setdefault(st, []).append(cluster)
        got.add(st)
    return got, "process", {k: v for k, v in seen.items() if len(v) > 1}


def stage_check(a, values, tgts):
    print("\n" + "=" * 70)
    print("CHECK")
    print("=" * 70)
    missing, dupes, used_process = {}, {}, False
    common = {}

    hdr = (f"{'target':7s} {'inputs':>7s} " +
           " ".join(f"{v:>9s}" for v in values) + "   naming")
    print(hdr); print("-" * len(hdr))

    for tgt in tgts:
        lst = read_list(os.path.join(a.lists, f"filelist_{tgt}.txt"))
        if lst is None:
            print(f"{tgt:7s} !! no filelist_{tgt}.txt under {a.lists}")
            missing[tgt] = (None, None)
            continue
        want = {stem_of(p): p for p in lst}
        lab = TARGETS.get(tgt, tgt)
        row, permiss, namings = [], {}, set()
        for v in values:
            files = gather(a.base, tgt, a.param, v, "corr", lab, a.stage)
            got, naming, dup = scan_present(files, lab, a.stage, lst)
            if naming:
                namings.add(naming)
            if dup:
                dupes.setdefault(tgt, {})[v] = dup
            permiss[v] = sorted(set(want) - got)
            row.append(f"{len(got)}/{len(want)}")
        if "process" in namings:
            used_process = True
        print(f"{tgt:7s} {len(want):7d} " + " ".join(f"{c:>9s}" for c in row)
              + f"   [{'/'.join(sorted(namings)) or '-'}]")
        union = sorted(set().union(*permiss.values())) if permiss else []
        if union:
            missing[tgt] = (union, want)
        if a.intersect:
            common[tgt] = common_stems(a, values, tgt, lst)
            uniform = all(len(permiss[v]) == len(union) for v in values)
            print(f"        common to all values: {len(common[tgt])}/{len(want)}"
                  f"  ({'uniform loss' if uniform else 'NON-UNIFORM'})")

    if used_process:
        print("\n  PROCESS naming: the index->input mapping is valid only if the")
        print("    file lists are byte-identical to those used at submission.")

    if dupes:
        print("\n  !! DUPLICATES -- these inputs would be summed twice:")
        for tgt, byv in dupes.items():
            for v, d in byv.items():
                print(f"     {tgt} at {v}: {len(d)} input(s), e.g. "
                      f"{list(d)[0]} in clusters {list(d.values())[0]}")
        print("     Delete the older files before merging.")

    if not missing:
        print("\n  all inputs present at all values")
        return not dupes

    if a.intersect and not dupes:
        worst = min((len(common[t]) / max(len(read_list(
            os.path.join(a.lists, f"filelist_{t}.txt")) or [1]), 1))
            for t in common) if common else 0.0
        print(f"\n  --intersect: merging only files present at every value.")
        print(f"  Smallest surviving fraction: {100*worst:.1f}%")
        if worst >= a.min_frac:
            print(f"  Above --min-frac {100*a.min_frac:.0f}%, so the scan is")
            print("   comparable across points.")
            return True
        print(f"  BELOW --min-frac {100*a.min_frac:.0f}% -- too much of the")
        print("   sample is gone. Retry before scanning.")
        return False

    print("\n  !! INCOMPLETE")
    for tgt, (union, want) in missing.items():
        if union is None:
            continue
        print(f"     {tgt}: {len(union)}/{len(want)} inputs missing at one or "
              f"more values ({100*len(union)/len(want):.1f}%)")
        if a.write_retry:
            os.makedirs(a.lists, exist_ok=True)
            out = os.path.join(a.lists, f"filelist_{tgt}_retry.txt")
            with open(out, "w") as fh:
                fh.write(f"# retry: {a.param} = {','.join(values)}\n")
                for s in union:
                    fh.write(want[s] + "\n")
            print(f"       -> {out}")

    if not a.write_retry:
        print("\n  --write-retry generates the retry lists.")
    return False


# ------------------------------------------------------------------ stage: merge
def merge_kind(files, sumcols, label):
    frames = []
    for f in files:
        d = pd.read_csv(f)
        miss = [c for c in sumcols if c not in d.columns]
        if miss:
            return None, f"{os.path.basename(f)} lacks {miss}"
        for c in d.columns:
            if c.endswith(("_min", "_max")):
                d[c] = pd.to_numeric(d[c], errors="coerce").round(ROUND)
        frames.append(d)

    keys = [c for c in frames[0].columns if c not in sumcols]
    nkey = {len(f.drop_duplicates(subset=keys)) for f in frames}
    if len(nkey) != 1:
        return None, (f"inputs disagree on bin count {sorted(nkey)} -- a job "
                      f"died or used a different data dir")
    for col in ("target", "stage"):
        if col in frames[0].columns:
            vals = set().union(*(set(f[col].dropna().unique()) for f in frames))
            if len(vals) > 1:
                return None, f"mixed {col} values {sorted(vals)}"

    out = pd.concat(frames, ignore_index=True) \
            .groupby(keys, dropna=False, as_index=False)[sumcols].sum()
    n = nkey.pop()
    if len(out) != n:
        return None, f"merged to {len(out)} rows from {n} keys -- keys not matching"
    if out[sumcols].isna().any().any() or (out[sumcols] < 0).any().any():
        return None, "NaN or negative after summing"
    return out, f"{len(files)} files -> {len(out)} rows"


def stage_merge(a, values, tgts, expect):
    print("\n" + "=" * 70)
    print("MERGE")
    print("=" * 70)
    anadir, datadir = os.path.abspath(a.anadir), os.path.abspath(a.data)
    nfail = 0

    # With --intersect every value is merged from the SAME inputs, so the
    # points are comparable even when jobs failed unevenly.
    keep_stems, lists = {}, {}
    if a.intersect:
        for tgt in tgts:
            lst = read_list(os.path.join(a.lists, f"filelist_{tgt}.txt"))
            if lst is None:
                continue
            lists[tgt] = lst
            keep_stems[tgt] = common_stems(a, values, tgt, lst)
            print(f"  {tgt:6s}: using {len(keep_stems[tgt])}/{len(lst)} inputs "
                  f"common to all values")

    for v in values:
        odir = os.path.abspath(os.path.join(a.out, f"{a.param}_{tag_of(v)}"))
        os.makedirs(odir, exist_ok=True)
        print(f"\n  {a.param} = {v}")
        ok = True
        for tgt in tgts:
            lab = TARGETS.get(tgt, tgt)
            keep = keep_stems.get(tgt)
            for kind, sumcols in (("mult", SUM_MULT), ("corr", SUM_CORR)):
                files = gather(a.base, tgt, a.param, v, kind, lab, a.stage)
                if keep is not None:
                    order = lists.get(tgt, [])
                    before = len(files)
                    files = [f for f in files
                             if file_stem(f, lab, a.stage, order) in keep]
                    if before != len(files):
                        print(f"    .. {tgt:6s} {kind:4s}: {before} -> {len(files)}"
                              f" (intersection)")
                n_exp = len(keep) if keep is not None else expect.get(tgt)
                if not files:
                    print(f"    !! {tgt:6s} {kind:4s}: no files"); ok = False; continue
                if n_exp and len(files) < n_exp:
                    print(f"    !! {tgt:6s} {kind:4s}: {len(files)}/{n_exp} "
                          f"-- incomplete"); ok = False; continue
                if n_exp and len(files) > n_exp:
                    print(f"    !! {tgt:6s} {kind:4s}: {len(files)} files for "
                          f"{n_exp} inputs -- duplicates"); ok = False; continue
                out, msg = merge_kind(files, sumcols, f"{tgt} {kind}")
                if out is None:
                    print(f"    !! {tgt:6s} {kind:4s}: {msg}"); ok = False; continue
                out.to_csv(os.path.join(
                    odir, f"counts_{kind}_{lab}_{a.stage}.csv"), index=False)
                print(f"    OK {tgt:6s} {kind:4s}: {msg}")
        if not ok:
            print("    -> counts incomplete, not analysing this value")
            nfail += 1
            continue

        for script, extra in (
            ("eg2_observables.py", ["--counts", odir, "--stage", a.stage, "--out", odir]),
            ("eg2_overlay.py", ["--data", datadir, "--pred", odir, "--stage", a.stage,
                                "--out", odir, "--syst", a.syst, "--match-norm"]
             + (["--plots", os.path.join(odir, "plots")] if a.plots else [])),
        ):
            r = subprocess.run([sys.executable, script] + extra,
                               cwd=anadir, capture_output=True, text=True)
            if r.returncode:
                print(f"    !! {script} failed:\n{r.stdout[-500:]}{r.stderr[-500:]}")
                nfail += 1
                break
            if script == "eg2_overlay.py":
                open(os.path.join(odir, "overlay.log"), "w").write(r.stdout)
            print(f"    OK {script}")

    return nfail == 0


# ------------------------------------------------------------------ stage: collect
def describe(v, c, ndf):
    """min, delta-chi2 spans and shape verdict for one chi2 curve."""
    i = int(np.argmin(c))
    d = c - c[i]
    out = [f"minimum at {v[i]:.4g},  chi2 = {c[i]:.1f}"
           + (f"  (chi2/ndf = {c[i]/ndf:.1f})" if ndf else "")]
    for lvl in (1, 9, 25):
        inr = v[d <= lvl]
        out.append(f"$\\Delta\\chi^2$ < {lvl:2d}:  "
                   + (f"[{inr.min():.4g}, {inr.max():.4g}]" if inr.size else "-"))
    dd = np.diff(c)
    if c.max() - c.min() < 1:
        out.append("FLAT: does not constrain this parameter")
    elif (dd > 0).all():
        out.append("MONOTONIC: minimum below the scanned range")
    elif (dd < 0).all():
        out.append("MONOTONIC: minimum above the scanned range")
    else:
        out.append("interior minimum: bracketed")
    return out


def analysis_of(label):
    """'Moran TIII-V pi+' -> 'Moran' ;  'dipion R_A_over_D' -> 'dipion'."""
    return label.split()[0] if label and label != "TOTAL" else label


def stage_collect(a, values):
    print("\n" + "=" * 70)
    print("COLLECT")
    print("=" * 70)
    sys.path.insert(0, os.path.abspath(a.anadir))
    try:
        from eg2_overlay import FITSET, FITSET_CORR, chi2
        from eg2_io import read_table
    except ImportError as e:
        print(f"  cannot import the analysis modules from {a.anadir}: {e}")
        return False

    recs = []
    for v in values:
        d = os.path.join(a.out, f"{a.param}_{tag_of(v)}")
        got = {}
        fm = os.path.join(d, f"compare_mult_{a.stage}.csv")
        fc = os.path.join(d, f"compare_corr_{a.stage}.csv")
        if os.path.exists(fm):
            for (p, t, h), g in read_table(fm).groupby(
                    ["paper", "table_group", "hadron"]):
                if a.fitset and (p, t) not in FITSET:
                    continue
                r = chi2(g, a.syst, f"{p} T{t} {h}")
                if r:
                    got[r["label"]] = (r["chi2"], r["ndf"])
        if os.path.exists(fc):
            for (an, o), g in read_table(fc).groupby(["analysis", "observable"]):
                if a.fitset and (an, o) not in FITSET_CORR:
                    continue
                r = chi2(g, a.syst, f"{an} {o}")
                if r:
                    got[r["label"]] = (r["chi2"], r["ndf"])
        if not got:
            print(f"  no usable comparison tables at {v}")
            continue
        got["TOTAL"] = (sum(x[0] for x in got.values()),
                        sum(x[1] for x in got.values()))
        rec = {"value": float(v)}
        for k, (c2, ndf) in got.items():
            rec[k] = c2
            rec[f"ndf::{k}"] = ndf
        recs.append(rec)

    if not recs:
        print("  nothing to collect")
        return False

    df = pd.DataFrame(recs).sort_values("value").reset_index(drop=True)
    keys = sorted([c for c in df.columns
                   if c != "value" and not c.startswith("ndf::")],
                  key=lambda k: (k != "TOTAL", k))

    hdr = f"{'value':>9s} " + " ".join(f"{k[:20]:>21s}" for k in keys)
    print(); print(hdr); print("-" * len(hdr))
    for _, r in df.iterrows():
        print(f"{r['value']:9.4g} " + " ".join(
            f"{r[k]:21.1f}" if pd.notna(r.get(k)) else f"{'-':>21s}" for k in keys))

    print("\n  PRIOR RANGE (delta-chi2 about the scan minimum)")
    for k in keys:
        s = df[["value", k]].dropna()
        if len(s) < 3:
            continue
        vv, cc = s["value"].values, s[k].values
        i = int(np.argmin(cc))
        ndf = int(df[f"ndf::{k}"].dropna().iloc[0]) if f"ndf::{k}" in df else 0
        print(f"\n    {k}  ({ndf} dof)")
        print(f"      minimum {vv[i]:.4g}, chi2 {cc[i]:.1f}"
              + (f"  (chi2/ndf {cc[i]/ndf:.2f})" if ndf else ""))
        for lvl in (1, 9, 25):
            inr = vv[cc - cc.min() <= lvl]
            print(f"      delta-chi2 < {lvl:2d} : "
                  f"[{inr.min():.4g}, {inr.max():.4g}]" if inr.size else "      -")
        if cc.max() - cc.min() < 1:
            print("      FLAT: this group does not constrain the parameter.")
        elif i in (0, len(vv) - 1):
            print("      MINIMUM AT AN ENDPOINT: extend the scan, or the prior")
            print("      edge will set the posterior.")


    # ---- aggregate the groups into analysis-level sums -------------------
    # NOTE: this only sums correctly over a NON-OVERLAPPING set of groups.
    per_analysis = {}
    for k in keys:
        if k == "TOTAL":
            continue
        per_analysis.setdefault(analysis_of(k), []).append(k)

    for an, members in sorted(per_analysis.items()):
        if len(members) < 2:
            continue
        col = f"[{an}]"
        df[col] = df[members].sum(axis=1)
        df[f"ndf::{col}"] = sum(
            int(df[f"ndf::{m}"].dropna().iloc[0]) for m in members
            if f"ndf::{m}" in df.columns)

    # page order: individual groups, then analysis sums, then TOTAL
    pages = ([k for k in keys if k != "TOTAL"]
             + sorted(c for c in df.columns if c.startswith("[")))
    if "TOTAL" in df.columns:
        pages.append("TOTAL")

    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        from matplotlib.backends.backend_pdf import PdfPages

        pdf_path = os.path.join(a.out, f"scan_chi2_{a.param}.pdf")
        with PdfPages(pdf_path) as pdf:
            for k in pages:
                sdf = df[["value", k]].dropna()
                if len(sdf) < 2:
                    continue
                vv, cc = sdf["value"].values, sdf[k].values
                ndf = (int(df[f"ndf::{k}"].dropna().iloc[0])
                       if f"ndf::{k}" in df.columns
                       and df[f"ndf::{k}"].notna().any() else 0)

                fig, ax = plt.subplots(1, 2, figsize=(10.5, 4.4))
                ax[0].plot(vv, cc, "o-", color="#1f77b4", lw=1.6, ms=5)
                ax[0].set_ylabel(r"$\chi^2$")
                ax[1].plot(vv, cc - cc.min(), "o-", color="#d62728", lw=1.6, ms=5)
                ax[1].set_ylabel(r"$\Delta\chi^2$")
                for lvl, ls in ((1, ":"), (9, "--"), (25, "-.")):
                    ax[1].axhline(lvl, color="gray", lw=0.8, ls=ls)
                    ax[1].text(vv[-1], lvl, f" {lvl}", va="center", fontsize=7,
                               color="gray")
                top = max(30.0, float(np.percentile(cc - cc.min(), 80)) * 1.6)
                ax[1].set_ylim(0, top)
                for j in (0, 1):
                    ax[j].set_xlabel(f"--{a.param}")
                    ax[j].grid(alpha=0.3)
                    if vv.min() > 0 and vv.max() / vv.min() > 5:
                        ax[j].set_xscale("log")

                kind = ("TOTAL" if k == "TOTAL"
                        else "analysis sum" if k.startswith("[") else "table")
                fig.suptitle(f"{k}    [{kind}]"
                             + (f"   {ndf} dof" if ndf else "")
                             + f"    stage {a.stage}, syst {a.syst}",
                             fontsize=11)
                fig.text(0.5, 0.005, "   |   ".join(describe(vv, cc, ndf)),
                         ha="center", fontsize=8)
                fig.tight_layout(rect=[0, 0.045, 1, 0.94])
                pdf.savefig(fig)
                plt.close(fig)

            fig, ax = plt.subplots(figsize=(9, 5.2))
            for k in pages:
                sdf = df[["value", k]].dropna()
                if len(sdf) < 2:
                    continue
                vv, cc = sdf["value"].values, sdf[k].values
                style = dict(lw=2.4, color="k", ls="-") if k == "TOTAL" else (
                        dict(lw=1.8, ls="--") if k.startswith("[") else
                        dict(lw=1.0, ls="-", alpha=0.75))
                ax.plot(vv, cc - cc.min(), "o", ms=3, label=k[:30], **style)
            for lvl, ls in ((1, ":"), (9, "--"), (25, "-.")):
                ax.axhline(lvl, color="gray", lw=0.8, ls=ls)
            ax.set_ylim(0, 60)
            ax.set_xlabel(f"--{a.param}"); ax.set_ylabel(r"$\Delta\chi^2$")
            if vv.min() > 0 and vv.max() / vv.min() > 5:
                ax.set_xscale("log")
            ax.grid(alpha=0.3)
            ax.legend(fontsize=6, ncol=2)
            ax.set_title("all groups (thin), analysis sums (dashed), TOTAL (black)",
                         fontsize=10)
            fig.tight_layout()
            pdf.savefig(fig); plt.close(fig)

        print(f"  wrote {pdf_path}  ({len(pages)} pages + summary)")
    except Exception as e:
        print(f"  (no plot: {e})")

    csv = os.path.join(a.out, f"scan_chi2_{a.param}.csv")
    df.drop(columns=[c for c in df.columns if c.startswith("ndf::")]) \
      .to_csv(csv, index=False)
    print(f"  wrote {csv}")

    return True


# ------------------------------------------------------------------ stage: deficit
def stage_deficit(a, values):
    """How much attenuation GENIE produces, against how much the data need.

    R_M = [N_h/N_e]_A / [N_h/N_e]_D is 1 if the nucleus does nothing.

    ABOVE z ~ 0.2 the data have R < 1 and (1 - R) is a depletion: hadrons are
    absorbed, or lose energy and migrate to lower z.

    BELOW z ~ 0.2 the data have R > 1 -- an enhancement, fed by the hadrons
    that migrated down from higher z.
    """
    print("\n" + "=" * 70)
    print("DEFICIT   attenuation produced vs attenuation required")
    print("=" * 70)
    sys.path.insert(0, os.path.abspath(a.anadir))
    try:
        from eg2_io import read_table
    except ImportError as e:
        print(f"  cannot import eg2_io from {a.anadir}: {e}")
        return False

    ref = a.deficit_at or (values[len(values) // 2])
    d = os.path.join(a.out, f"{a.param}_{tag_of(ref)}")
    f = os.path.join(d, f"compare_mult_{a.stage}.csv")
    if not os.path.exists(f):
        print(f"  no {f}")
        return False
    print(f"  at {a.param} = {ref}   ({a.stage})\n")

    df = read_table(f)
    need = {"value_mc", "value_data"}
    if not need <= set(df.columns):
        print(f"  table lacks {sorted(need - set(df.columns))}")
        return False

    # Group by TABLE as well.
    by = [c for c in ("target", "hadron", "paper", "table_group")
          if c in df.columns]
    if a.tables:
        want = {t.strip() for t in a.tables.split(",")}
        for col in ("table_group", "source_table"):
            if col in df.columns:
                df = df[df[col].astype(str).isin(want)]
                break
        print(f"  restricted to tables: {sorted(want)}\n")
    zc = "z_min" if "z_min" in df.columns else None

    for keys, g in (df.groupby(by) if by else [((), df)]):
        keys = keys if isinstance(keys, tuple) else (keys,)
        lab = " ".join(str(k) for k in keys) or "all"
        print(f"  --- {lab} ---")
        if zc:
            g = g.copy()
            g["_z"] = pd.to_numeric(g[zc], errors="coerce")
            bins = g.groupby("_z")
            print(f"    {'z':>6s} {'R_mc':>7s} {'R_data':>7s} {'R_mc-R_data':>12s} "
                  f"{'dep_mc':>7s} {'dep_dat':>8s} {'frac':>7s}")
            for z, gg in bins:
                mc = pd.to_numeric(gg.value_mc, errors="coerce").mean()
                da = pd.to_numeric(gg.value_data, errors="coerce").mean()
                if not (np.isfinite(mc) and np.isfinite(da)):
                    continue
                dmc, dda = 1 - mc, 1 - da
                if dda > 0.05:
                    fr = f"{dmc/dda:7.2f}"
                elif dda < -0.02:
                    fr = "  ENH  "     # enhancement: R > 1, not attenuation
                else:
                    fr = "    -  "     # R ~ 1, ratio not meaningful
                print(f"    {z:6.2f} {mc:7.3f} {da:7.3f} {mc-da:+12.3f} "
                      f"{dmc:7.3f} {dda:8.3f} {fr}")
        else:
            mc = pd.to_numeric(g.value_mc, errors="coerce").mean()
            da = pd.to_numeric(g.value_data, errors="coerce").mean()
            print(f"    R_mc {mc:.3f}   R_data {da:.3f}   diff {mc-da:+.3f}")
        print()

    return True


# ------------------------------------------------------------------ main
def main():
    p = argparse.ArgumentParser()
    p.add_argument("--base", action="append", default=[],
                   help="campaign dir; repeat to fold in a retry campaign")
    p.add_argument("--param", required=True)
    p.add_argument("--values", required=True)
    p.add_argument("--stage", default="fsi")
    p.add_argument("--stages", default="check,merge,collect")

    p.add_argument("--out", default="merged")


    p.add_argument("--syst", default="quad", choices=["none", "quad", "norm"])
    p.add_argument("--targets", default=",".join(TARGETS))
    p.add_argument("--expect", default=None,
                   help='files per target, e.g. "D2=439,C12=90,Fe56=125,Pb208=57"')
    p.add_argument("--fitset", action="store_true")
    p.add_argument("--write-retry", action="store_true")
    p.add_argument("--plots", action="store_true")
    p.add_argument("--tables", default=None,
                   help="restrict the deficit to these table groups, e.g. "
                        "'III-V,VI-VIII' -- the z-differential ones")
    p.add_argument("--deficit-at", default=None,
                   help="parameter value to read the deficit at (default: middle)")
    p.add_argument("--intersect", action="store_true",
                   help="merge only inputs present at EVERY value, so the points "
                        "are built from the same events")
    p.add_argument("--min-frac", type=float, default=0.8,
                   help="with --intersect, fail if a target keeps less than this")
    p.add_argument("--force", action="store_true",
                   help="continue to the next stage even if one fails")
    a = p.parse_args()

    values = [v.strip() for v in a.values.split(",") if v.strip()]
    tgts = [t.strip() for t in a.targets.split(",") if t.strip()]
    stages = [s.strip() for s in a.stages.split(",") if s.strip()]
    expect = {}
    if a.expect:
        for kv in a.expect.split(","):
            k, v = kv.split("=")
            expect[k.strip()] = int(v)

    if {"check", "merge"} & set(stages) and not a.base:
        sys.exit("--base is required for the check and merge stages")

    a.anadir = ea_path("EA_ANALYSIS", "the analysis code (eg2_*.py)")
    a.data = ea_path("EA_DATA", "the published CLAS tables (clas_eg2_*.csv)")
    a.lists = ea_path("EA_LISTDIR", "the per-target input file lists")

    # Check before doing any work.
    need = {"merge": [os.path.join(a.anadir, f)
                      for f in ("eg2_observables.py", "eg2_overlay.py")],
            "collect": [os.path.join(a.anadir, f)
                        for f in ("eg2_overlay.py", "eg2_io.py")],
            "deficit": [os.path.join(a.anadir, "eg2_io.py")]}
    missing = sorted({f for st in stages for f in need.get(st, [])
                      if not os.path.exists(f)})
    if missing:
        print(f"ERROR: analysis modules not found under {a.anadir}")
        for f in missing:
            print(f"         missing {os.path.basename(f)}")
        print("       Check EA_ANALYSIS in setup.sh.")
        return 1
    if "merge" in stages and not glob.glob(os.path.join(a.data, "clas_eg2_*.csv")):
        print(f"ERROR: no clas_eg2_*.csv under {a.data}  (check EA_DATA)")
        return 1

    print(f"parameter : --{a.param}")
    print(f"values    : {values}")
    print(f"stages    : {stages}")
    print(f"analysis  : {a.anadir}")
    if {"merge", "deficit"} & set(stages):
        print(f"data      : {a.data}")
    if "check" in stages:
        print(f"lists     : {a.lists}")
    if a.base:
        for b in a.base:
            print(f"base      : {b}")

    for s in stages:
        if s == "check":
            ok = stage_check(a, values, tgts)
        elif s == "merge":
            ok = stage_merge(a, values, tgts, expect)
        elif s == "collect":
            ok = stage_collect(a, values)
        elif s == "deficit":
            ok = stage_deficit(a, values)
        else:
            sys.exit(f"unknown stage '{s}' (check, merge, collect, deficit)")
        if not ok and not a.force:
            print(f"\nstage '{s}' failed -- stopping. --force to continue anyway.")
            return 1
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main())