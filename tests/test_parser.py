"""The R parser has to recover what the simulator knows: Hero's net, VPIP and flops seen,
hand by hand. Runs the real parse_coinpoker.R on a fresh synthetic set in a temp folder."""
from __future__ import annotations

import csv
import os
import shutil
import subprocess
import sys

import pytest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
import simulate_hands  # noqa: E402


@pytest.fixture(scope="module")
def parsed(tmp_path_factory):
    work = tmp_path_factory.mktemp("run")
    shutil.copy(os.path.join(ROOT, "parse_coinpoker.R"), work)
    simulate_hands.write(str(work / "hands"), 1500, seed=11, rakeback_csv=None,
                         truth_csv=str(work / "truth.csv"))
    subprocess.run(["Rscript", "parse_coinpoker.R"], cwd=work, check=True, capture_output=True)
    with open(work / "truth.csv") as f:
        truth = {r["id"]: r for r in csv.DictReader(f)}
    with open(work / "coinpoker_hands.csv") as f:
        got = {r["id"]: r for r in csv.DictReader(f)}
    return truth, got


def test_every_hand_is_parsed(parsed):
    truth, got = parsed
    assert set(got) == set(truth)


def test_net_matches_to_the_cent(parsed):
    truth, got = parsed
    off = [i for i in truth if abs(float(got[i]["net"]) - float(truth[i]["net"])) > 0.005]
    assert not off, f"{len(off)} hands off, e.g. {off[:3]}"


def test_vpip_and_flops_seen(parsed):
    truth, got = parsed
    flag = lambda v: v in ("TRUE", "1")  # noqa: E731
    assert all(flag(got[i]["vpip"]) == (truth[i]["vpip"] == "1") for i in truth)
    assert all(flag(got[i]["saw_flop"]) == (truth[i]["saw_flop"] == "1") for i in truth)
