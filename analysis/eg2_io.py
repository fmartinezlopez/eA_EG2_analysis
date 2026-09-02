#!/usr/bin/env python3
"""
Shared conventions for the EG2 layer: reading the published tables, grouping
continuation tables, ordering targets, and labelling axes.

Kept in one module so the observables step, the grid checker and the overlay
cannot drift apart on any of them.
"""

import numpy as np
import pandas as pd

DATA_FILES = {
    "Moran": "clas_eg2_charged_pion_multiplicity_ratios_Moran_PRC105_015201.csv",
    "Mineeva": "clas_eg2_neutral_pion_multiplicity_ratios_Mineeva_PRC112_035203.csv",
    "dipion": "clas_eg2_dipion_correlations_Paul_PRC111_035201.csv",
    "pionproton": "clas_eg2_pion_proton_correlations_Paul_2512_05083.csv",
}


def read_table(path):
    """
    Read a published table. The CSVs are column-aligned for readability, so
    both the header names and the field values carry padding; everything is
    trimmed here rather than at each call site.
    """
    d = pd.read_csv(path, skipinitialspace=True)
    d.columns = [str(c).strip() for c in d.columns]
    for c in d.columns:
        d[c] = d[c].map(lambda v: v.strip() if isinstance(v, str) else v)
    return d


# ---------------------------------------------------------------------------
# Continuation tables
# ---------------------------------------------------------------------------
# Morán splits single tables across several numbered pages. III/IV/V are one
# pi+ table with three nu windows; VI/VII/VIII the pi- counterpart; IX-XII are
# one pT^2 table, with the pi+ half on IX-X and the pi- half on XI-XII. Plotting
# them separately produces figures that each show a third of a table and panel
# sets that look arbitrary.
TABLE_GROUP = {
    "Moran": {
        "II": "II",
        "III": "III-V", "IV": "III-V", "V": "III-V",
        "VI": "VI-VIII", "VII": "VI-VIII", "VIII": "VI-VIII",
        "IX": "IX-XII", "X": "IX-XII", "XI": "IX-XII", "XII": "IX-XII",
    },
}


def table_group(paper, source_table):
    return TABLE_GROUP.get(paper, {}).get(str(source_table).strip(),
                                          str(source_table).strip())


def add_group(df, paper_col="paper", table_col="source_table"):
    df = df.copy()
    df["table_group"] = [table_group(p, t)
                         for p, t in zip(df[paper_col], df[table_col])]
    return df


# ---------------------------------------------------------------------------
# Targets: always ordered by Z, so deuterium leads every legend
# ---------------------------------------------------------------------------
Z_OF = {"D": 1, "C": 6, "Fe": 26, "Pb": 82}
TCOLOR = {"D": "#333333", "C": "#1f77b4", "Fe": "#d62728", "Pb": "#2ca02c"}
TMARK = {"D": "o", "C": "s", "Fe": "^", "Pb": "D"}


def by_z(targets):
    return sorted(set(targets), key=lambda t: (Z_OF.get(t, 999), str(t)))


# ---------------------------------------------------------------------------
# Labels
# ---------------------------------------------------------------------------
SLICE_LABEL = {
    "dY": r"$\Delta Y$",
    "p1T": r"$p_{1T}$",
    "p2T": r"$p_{2T}$",
    "integrated": "integrated",
}

AXIS_LABEL = {
    "z": r"$z$",
    "pT2": r"$p_T^2$ [GeV$^2$]",
    "dphi": r"$|\Delta\phi|$ [rad]",
    "dY": r"$\Delta Y$",
}

OBS_LABEL = {
    "C_dphi": r"$C(\Delta\phi)$",
    "C_dphi_dY": r"$C(\Delta\phi,\Delta Y)$",
    "R_A_over_D": r"$R_{A/D}$",
    "sigma_RMS_width_rad": r"$\sigma$ [rad]",
    "b_broadening_rad": r"$b$ [rad]",
    "R_h": r"$R_h$",
}


def slice_label(sv):
    return SLICE_LABEL.get(str(sv).strip(), str(sv).strip())


def rng(lo, hi, fmt="{:g}"):
    """En-dash range, for panel titles."""
    return f"{fmt.format(lo)}\u2013{fmt.format(hi)}"