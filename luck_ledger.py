#!/usr/bin/env python3
"""The Luck Ledger: decompose Hero's results into distinct, honestly-labeled slices of luck
plus a residual ("everything else"). Answers "we're missing something about the downswing" with
one waterfall instead of a dozen separate cuts.

Components (for the deepest drawdown, from its peak to its trough, vs the rest of the sample as baseline):
  1. DEALT-CARD LUCK   - were you dealt stronger/weaker hole cards than your own average, in hands
                          that matter (raw hot/cold equity vs a random hand, a pure function of the
                          169 starting-hand class - independent of villain/board/how it was played)?
                          Monetized via the empirical $/equity-point slope from your OWN full sample
                          (regression, not an assumption), so estimation noise in the per-class equity
                          numbers cancels between baseline and window.
  2. ALL-IN LUCK       - reuses allin_ev.py's logic: equity at the moment of a clean HU all-in with
                          cards to come, vs what you actually collected.
  3. RIVER-CARD LUCK   - for clean HU showdowns that were NOT already all-in (money still going in
                          street by street): exact equity right before the river card falls (board =
                          flop+turn, one card left) vs the actual showdown result. Isolates "did that
                          one card flip who was ahead" from betting decisions made after it landed.
                          CAVEAT: monetized against the final pot as a simple stand-in for "money at
                          risk to that card" - some of that pot arrived via river betting made AFTER
                          the card was already public, so this is a reasonable approximation, not an
                          exact accounting (flagged, not hidden).
  4. RESIDUAL          - actual net minus the three components above: your decisions + variance the
                          other three don't capture (bet-sizing, fold/call choices, cbet lines, etc).
                          This is NOT "skill" on its own - it is what's left over.

Writes coinpoker_luck_ledger.csv (one row per component, window vs baseline) for the dashboard
waterfall chart. Run: python3 luck_ledger.py
"""
import argparse
import csv
import glob
import os
import random

from poker_eval import equity, equity_vs_random
import allin_ev

HERE = os.path.dirname(os.path.abspath(__file__))
FEAT = os.path.join(HERE, "coinpoker_features.csv")
OUT = os.path.join(HERE, "coinpoker_luck_ledger.csv")
WINDOW_START = WINDOW_END = None   # the deepest drawdown, found in main(); --window-start/--window-end override


def in_window(day):
    return WINDOW_START <= day[:10] <= WINDOW_END


def deepest_drawdown_start(rows):
    """(peak date, trough date) of the deepest peak-to-trough fall in cumulative net."""
    run = peak = 0.0
    peak_dt, best, best_dt, trough_dt = rows[0]["dt"], 0.0, rows[0]["dt"], rows[-1]["dt"]
    for r in sorted(rows, key=lambda r: r["dt"]):
        run += float(r["net"])
        if run > peak:
            peak, peak_dt = run, r["dt"]
        if peak - run > best:
            best, best_dt, trough_dt = peak - run, peak_dt, r["dt"]
    return best_dt[:10], trough_dt[:10]

RANKS = "23456789TJQKA"


def isna(v):
    return v in ("NA", "", None)


def repr_cards(hand169):
    """One concrete pair of cards for a 169-class label (e.g. 'AKs','AKo','AA') -
    equity vs random is invariant to which suits, by symmetry, so any valid pick works."""
    if len(hand169) == 2:
        r = hand169[0]
        return [r + "s", r + "h"]
    r1, r2, kind = hand169[0], hand169[1], hand169[2]
    if kind == "s":
        return [r1 + "s", r2 + "s"]
    return [r1 + "s", r2 + "h"]


def load_rows():
    with open(FEAT, newline="", encoding="utf-8") as f:
        rows = list(csv.DictReader(f))
    return [r for r in rows if r.get("is_bomb") != "TRUE"]


def dealt_card_luck(rows):
    classes = sorted(set(r["hand169"] for r in rows if not isna(r["hand169"])))
    cache = {}
    for c in classes:
        cache[c] = equity_vs_random(repr_cards(c), mc=4000)

    def row_equity(r):
        return cache.get(r["hand169"])

    have = [r for r in rows if not isna(r["hand169"])]
    eqs = [row_equity(r) for r in have]
    nets = [float(r["net"]) for r in have]
    n = len(have)
    mean_eq = sum(eqs) / n
    mean_net = sum(nets) / n
    cov = sum((e - mean_eq) * (nt - mean_net) for e, nt in zip(eqs, nets)) / n
    var = sum((e - mean_eq) ** 2 for e in eqs) / n
    slope = cov / var if var > 0 else 0.0
    intercept = mean_net - slope * mean_eq

    win = [r for r in have if in_window(r["dt"])]
    base = [r for r in have if not in_window(r["dt"])]
    mu_win = sum(row_equity(r) for r in win) / len(win)
    mu_base = sum(row_equity(r) for r in base) / len(base) if base else mean_eq
    dollars_win = slope * (mu_win - mean_eq) * len(win)
    dollars_base = slope * (mu_base - mean_eq) * len(base) if base else 0.0
    return dict(
        slope=slope, intercept=intercept, mean_eq=mean_eq,
        mu_win=mu_win, mu_base=mu_base, n_win=len(win), n_base=len(base),
        dollars_win=dollars_win, dollars_base=dollars_base,
    )


def allin_luck(rows_by_window):
    hands = allin_ev.parse()
    ids_used = set(h["hid"] for h in hands)
    out = {"win": [0.0, 0.0, 0], "base": [0.0, 0.0, 0]}  # expected, actual, n
    for h in hands:
        e = equity(h["hero"], h["vill"], h["board"])
        exp = e * h["pot"]
        key = "win" if in_window(h["day"].replace("/", "-")) else "base"
        out[key][0] += exp
        out[key][1] += h["collected"]
        out[key][2] += 1
    return out, ids_used


def river_card_luck(rows, exclude_ids):
    cand = [
        r for r in rows
        if r["showdown"] == "TRUE"
        and not isna(r["villain_cards"])
        and not isna(r["flop"]) and not isna(r["turn_card"]) and not isna(r["river_card"])
        and r["n_flop"] == "2"
        and r["id"] not in exclude_ids
    ]
    out = {"win": [0.0, 0.0, 0], "base": [0.0, 0.0, 0]}
    for r in cand:
        hero = r["hero_cards"].split()
        vill = r["villain_cards"].split()
        board4 = r["flop"].split() + [r["turn_card"]]
        river = r["river_card"]
        if len(hero) != 2 or len(vill) != 2 or len(board4) != 4:
            continue
        e_before = equity(hero, vill, board4)              # exact (1 card left)
        result = equity(hero, vill, board4 + [river])       # exact, = 0/0.5/1
        pot_net = float(r["pot"]) - float(r["rake"]) - float(r["splash_fee"])
        exp = e_before * pot_net
        act = result * pot_net
        key = "win" if in_window(r["dt"]) else "base"
        out[key][0] += exp
        out[key][1] += act
        out[key][2] += 1
    return out


def main():
    global WINDOW_START, WINDOW_END
    random.seed(7)
    rows = load_rows()
    ap = argparse.ArgumentParser(description="Luck ledger for one window vs the rest")
    ap.add_argument("--window-start", default=None, help="YYYY-MM-DD (default: the deepest drawdown)")
    ap.add_argument("--window-end", default=None, help="YYYY-MM-DD")
    a = ap.parse_args()
    lo, hi = deepest_drawdown_start(rows)
    WINDOW_START, WINDOW_END = a.window_start or lo, a.window_end or hi
    win_rows = [r for r in rows if in_window(r["dt"])]
    base_rows = [r for r in rows if not in_window(r["dt"])]
    actual_net_win = sum(float(r["net"]) for r in win_rows)
    actual_net_base = sum(float(r["net"]) for r in base_rows)

    print(f"Hands: {len(rows)} total  ({len(win_rows)} in the window {WINDOW_START} to {WINDOW_END}, {len(base_rows)} outside it)\n")

    print("--- 1. Dealt-card luck (raw equity vs random, by 169-class) ---")
    dc = dealt_card_luck(rows)
    print(f"  overall avg dealt equity: {100*dc['mean_eq']:.2f}%  (should sit near 50% - sanity check)")
    print(f"  baseline avg equity: {100*dc['mu_base']:.2f}%   window avg equity: {100*dc['mu_win']:.2f}%")
    print(f"  empirical slope: ${dc['slope']:.2f} net per 1.0 equity swing per hand (your own full-sample regression)")
    print(f"  -> card luck, window: ${dc['dollars_win']:+.0f}   baseline: ${dc['dollars_base']:+.0f}\n")

    print("--- 2. All-in luck (reprising allin_ev.py) ---")
    ai, ai_ids = allin_luck(rows)
    ai_win_luck = ai["win"][1] - ai["win"][0]
    ai_base_luck = ai["base"][1] - ai["base"][0]
    print(f"  window:   n={ai['win'][2]:3}  expected ${ai['win'][0]:.0f}  actual ${ai['win'][1]:.0f}  luck ${ai_win_luck:+.0f}")
    print(f"  baseline: n={ai['base'][2]:3}  expected ${ai['base'][0]:.0f}  actual ${ai['base'][1]:.0f}  luck ${ai_base_luck:+.0f}\n")

    print("--- 3. River-card luck (non-all-in clean HU showdowns) ---")
    rc = river_card_luck(rows, ai_ids)
    rc_win_luck = rc["win"][1] - rc["win"][0]
    rc_base_luck = rc["base"][1] - rc["base"][0]
    print(f"  window:   n={rc['win'][2]:3}  expected ${rc['win'][0]:.0f}  actual ${rc['win'][1]:.0f}  luck ${rc_win_luck:+.0f}")
    print(f"  baseline: n={rc['base'][2]:3}  expected ${rc['base'][0]:.0f}  actual ${rc['base'][1]:.0f}  luck ${rc_base_luck:+.0f}\n")

    resid_win = actual_net_win - (dc["dollars_win"] + ai_win_luck + rc_win_luck)
    resid_base = actual_net_base - (dc["dollars_base"] + ai_base_luck + rc_base_luck)

    print("=== WATERFALL: the downswing window ===")
    print(f"  card luck        ${dc['dollars_win']:+8.0f}")
    print(f"  all-in luck      ${ai_win_luck:+8.0f}")
    print(f"  river-card luck  ${rc_win_luck:+8.0f}")
    print(f"  residual         ${resid_win:+8.0f}   (your decisions + unmodeled variance)")
    print(f"  -------------------------------")
    print(f"  ACTUAL NET       ${actual_net_win:+8.0f}\n")

    rows_out = [
        dict(window="downswing", component="card_luck", dollars=round(dc["dollars_win"], 1), n_hands=dc["n_win"]),
        dict(window="downswing", component="allin_luck", dollars=round(ai_win_luck, 1), n_hands=ai["win"][2]),
        dict(window="downswing", component="river_card_luck", dollars=round(rc_win_luck, 1), n_hands=rc["win"][2]),
        dict(window="downswing", component="residual", dollars=round(resid_win, 1), n_hands=len(win_rows)),
        dict(window="downswing", component="actual_net", dollars=round(actual_net_win, 1), n_hands=len(win_rows)),
        dict(window="baseline", component="card_luck", dollars=round(dc["dollars_base"], 1), n_hands=dc["n_base"]),
        dict(window="baseline", component="allin_luck", dollars=round(ai_base_luck, 1), n_hands=ai["base"][2]),
        dict(window="baseline", component="river_card_luck", dollars=round(rc_base_luck, 1), n_hands=rc["base"][2]),
        dict(window="baseline", component="residual", dollars=round(resid_base, 1), n_hands=len(base_rows)),
        dict(window="baseline", component="actual_net", dollars=round(actual_net_base, 1), n_hands=len(base_rows)),
    ]
    with open(OUT, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=["window", "component", "dollars", "n_hands"])
        w.writeheader()
        w.writerows(rows_out)
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()
