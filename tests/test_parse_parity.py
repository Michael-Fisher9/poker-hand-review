"""The Python parser has to agree with the R parser on every column of every hand, and with
the simulator's own record of Hero's net, VPIP and flops seen. The R comparison is skipped where
R isn't installed; the check against the simulator always runs."""
from __future__ import annotations

import os
import shutil
import subprocess
import sys

import numpy as np
import pandas as pd
import pytest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
import parse_coinpoker  # noqa: E402
import simulate_hands  # noqa: E402


@pytest.fixture(scope="module")
def work(tmp_path_factory):
    work = tmp_path_factory.mktemp("parity")
    simulate_hands.write(str(work / "hands"), 1500, seed=11, rakeback_csv=None,
                         truth_csv=str(work / "truth.csv"))
    parse_coinpoker.main(["--hands", str(work / "hands"), "--out", str(work)])
    os.rename(work / "coinpoker_hands.csv", work / "py_hands.csv")
    os.rename(work / "coinpoker_snapshots.csv", work / "py_snapshots.csv")
    return work


def test_python_matches_the_simulator(work):
    truth = pd.read_csv(work / "truth.csv").set_index("id")
    got = pd.read_csv(work / "py_hands.csv").set_index("id")
    assert set(got.index) == set(truth.index)
    got = got.loc[truth.index]
    assert (got.net - truth.net).abs().max() < 0.005
    assert (got.vpip.astype(bool) == truth.vpip.astype(bool)).all()
    assert (got.saw_flop.astype(bool) == truth.saw_flop.astype(bool)).all()


def same(a, b):
    numeric = pd.api.types.is_numeric_dtype
    if a.dtype == bool or b.dtype == bool or not (numeric(a) and numeric(b)):
        text = lambda x: x.astype(object).where(x.notna(), "NA").astype(str).str.upper()  # noqa: E731
        return text(a) == text(b)
    return np.isclose(a, b, atol=1e-9, equal_nan=True)


@pytest.mark.skipif(shutil.which("Rscript") is None, reason="R not installed")
def test_python_matches_r_column_by_column(work):
    shutil.copy(os.path.join(ROOT, "parse_coinpoker.R"), work)
    subprocess.run(["Rscript", "parse_coinpoker.R"], cwd=work, check=True, capture_output=True)
    r = pd.read_csv(work / "coinpoker_hands.csv", keep_default_na=False, na_values=["NA"])
    py = pd.read_csv(work / "py_hands.csv", keep_default_na=False, na_values=[""])
    assert list(py.columns) == list(r.columns)
    assert list(py.id) == list(r.id)   # same hands in the same order
    r["dt"] = pd.to_datetime(r.dt)
    py["dt"] = pd.to_datetime(py.dt)
    off = {c: int((~same(py[c], r[c])).sum()) for c in r.columns if c != "dt"}
    off = {c: n for c, n in off.items() if n}
    assert not off, f"columns that differ (hands): {off}"
    assert (py.dt == r.dt).all()

    rs = pd.read_csv(work / "coinpoker_snapshots.csv")
    ps = pd.read_csv(work / "py_snapshots.csv")
    assert list(ps.columns) == list(rs.columns)
    assert (ps.date.astype(str) == rs.date.astype(str)).all()
    # Daily rates are rounded to 0.1 (0.01 for af). Where the exact value is a tie, R's float sum
    # can land either side of it, so allow one unit in the last place there and nowhere else.
    for c in rs.columns.drop("date"):
        unit = 0.01 if c == "af" else 0.1
        assert np.allclose(ps[c], rs[c], atol=unit + 1e-9, equal_nan=True), c
        assert (~np.isclose(ps[c], rs[c], atol=1e-9, equal_nan=True)).sum() <= 2, c
