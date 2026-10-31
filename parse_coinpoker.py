#!/usr/bin/env python3
"""Python port of parse_coinpoker.R: CoinPoker cash hand histories (text) into one row per hand
from Hero's view. Same columns, same rules; tests/test_parse_parity.py checks every column against
the R parser on the same hands. Writes coinpoker_hands.csv and coinpoker_snapshots.csv.

    python parse_coinpoker.py [--hands hands] [--out .]
"""
from __future__ import annotations

import argparse
import math
import re
from decimal import ROUND_HALF_UP, Decimal
from pathlib import Path

import numpy as np
import pandas as pd

NA = float("nan")
STREET_TAG = re.compile(r"\*\*\* (FIRST |SECOND )?(FLOP|TURN|RIVER|SHOWDOWN)")
ACTION = re.compile(r"^(\S+): (posts|bets|calls|raises|ALLIN|RETURN)")
FLOP_ACTION = re.compile(r"^(\S+): (bets|checks|calls|raises|folds|ALLIN)")
SHOWS = re.compile(r"^(\S+): shows \[([^]]+)\] \(([A-Za-z ]+)\)")
RANK_ORDER = {"High Card": 1, "One Pair": 2, "Two Pair": 3, "Three Of A Kind": 4, "Straight": 5,
              "Flush": 6, "Full House": 7, "Four Of A Kind": 8, "Straight Flush": 9}


def num(s, pat):
    # first capture group as a number; the currency glyph is skipped by each pattern's [^0-9]*
    m = re.search(pat, s) if s is not None else None
    if not m:
        return NA
    try:
        return float(m.group(1))
    except ValueError:
        return NA


def r2(x):
    return NA if x is None or (isinstance(x, float) and math.isnan(x)) else round(x, 2)


def pos_label(occ, btn, n):
    if n == 2:   # heads-up: the button is the small blind
        return {btn: "BTN", [s for s in occ if s != btn][0]: "BB"}
    bi = occ.index(btn)
    order = occ[bi:] + occ[:bi]   # BTN, SB, BB, ..., CO
    labs = [None] * n
    labs[0] = "BTN"
    if n >= 2:
        labs[1] = "SB"
    if n >= 3:
        labs[2] = "BB"
    rest = list(range(3, n))
    for k, endlab in enumerate(["CO", "HJ", "UTG", "MP", "EP", "EP2"][:len(rest)]):
        labs[rest[len(rest) - 1 - k]] = endlab   # named from the button backward
    return dict(zip(order, labs))


def first_index(L, pred, start=0):
    for i in range(start, len(L)):
        if pred(L[i]):
            return i
    return None


def parse_block(L):
    hdr = L[0]
    hid = int(re.search(r"Hand #(\d+)", hdr).group(1))
    paren = re.search(r"\(([^)]+)\)", hdr).group(1)   # "₮0.05/₮0.10" or ".../₮0.01"
    stk = [float(x) for x in re.findall(r"[0-9.]+", paren)]
    sb, bb = stk[0], stk[1]
    ante_hdr = stk[2] if len(stk) >= 3 else 0.0
    is_bomb = "BombPot" in hdr
    dt = re.search(r"([0-9]{4}/[0-9]{2}/[0-9]{2} [0-9:]{8})", hdr).group(1)
    m = re.search(r"Table '([^']+)'", L[1])
    table_id = m.group(1) if m else None
    n_max = int(num(L[1], r"([0-9]+)-max"))
    btn = int(num(L[1], r"Seat #([0-9]+) is the button"))

    hole_i = first_index(L, lambda x: "*** HOLE CARDS" in x)
    seat_lines = [x for x in L[: hole_i + 1] if re.match(r"^Seat [0-9]+: .* in chips\)", x)]
    seats = [int(re.match(r"^Seat ([0-9]+):", x).group(1)) for x in seat_lines]
    who = [re.match(r"^Seat [0-9]+: (\S+) \(", x).group(1) for x in seat_lines]
    stacks = [float(re.match(r".*\([^0-9]*([0-9.]+) in chips\)", x).group(1)) for x in seat_lines]
    hero_seat = seats[who.index("Hero")]
    hero_stack = stacks[who.index("Hero")]
    n_players = len(seats)
    poslab = pos_label(sorted(seats), btn, n_players)
    hero_pos = poslab[hero_seat]
    name_pos = {w: poslab[s] for s, w in zip(seats, who)}

    hero_cards = None
    for x in L:
        m = re.search(r"Dealt to Hero \[([^]]+)\]", x)
        if m:
            hero_cards = m.group(1)
            break

    # walk the whole hand tracking Hero's committed chips per street; antes and blinds are
    # posted before *** HOLE CARDS ***
    committed = cstreet = ante = collected = returned = 0.0
    street = 0
    preflop_vpip = preflop_raise = folded_pre = False
    flop_occurred = turn_occurred = river_occurred = False
    fold_street = None
    pf_aggr = pf_calls = 0
    flop_call = turn_call = river_call = 0.0
    # pot accounting for every player, so the pot Hero faced at each decision is exact
    pot_running = 0.0
    scommit = {}
    flop_call_pot = turn_call_pot = river_pot = NA
    hero_flop_bet = hero_flop_pot = hero_turn_bet = hero_turn_pot = NA
    hero_river_bet = hero_river_pot = NA
    # any Hero aggression per street: a check-raise or a shove is not a "bets" line
    hero_aggr = {1: False, 2: False, 3: False}
    for ln in L:
        tag = STREET_TAG.search(ln)
        if tag:
            committed += cstreet
            cstreet = 0.0
            scommit = {}
            street = {"FLOP": 1, "TURN": 2, "RIVER": 3, "SHOWDOWN": 4}[tag.group(2)]
            flop_occurred |= street == 1
            turn_occurred |= street == 2
            river_occurred |= street == 3
            continue
        if "*** SUMMARY" in ln:
            committed += cstreet
            cstreet = 0.0
            break
        if "Hero collected" in ln:
            collected += num(ln, r"collected[^0-9]*([0-9.]+) from pot")
        am = ACTION.match(ln)
        if am:
            nm, verb = am.group(1), am.group(2)
            cur = scommit.get(nm, 0.0)
            if nm == "Hero" and verb in ("bets", "raises", "ALLIN") and street in hero_aggr:
                hero_aggr[street] = True
            if verb == "posts":
                if "ante" in ln:
                    pot_running += num(ln, r"ante[^0-9]*([0-9.]+)")
                else:
                    x = num(ln, r"blind[^0-9]*([0-9.]+)")
                    scommit[nm] = x
                    pot_running += x
            elif verb == "bets":
                x = num(ln, r"bets[^0-9]*([0-9.]+)")
                if nm == "Hero":
                    if street == 1 and math.isnan(hero_flop_bet):
                        hero_flop_bet, hero_flop_pot = x, pot_running
                    if street == 2 and math.isnan(hero_turn_bet):
                        hero_turn_bet, hero_turn_pot = x, pot_running
                    if street == 3 and math.isnan(hero_river_bet):
                        hero_river_bet, hero_river_pot = x, pot_running
                scommit[nm] = cur + x
                pot_running += x
            elif verb == "calls":
                x = num(ln, r"calls[^0-9]*([0-9.]+)")
                if nm == "Hero":   # pot before Hero's first call on each street, including the bet he faces
                    if street == 1 and math.isnan(flop_call_pot):
                        flop_call_pot = pot_running
                    if street == 2 and math.isnan(turn_call_pot):
                        turn_call_pot = pot_running
                    if street == 3 and math.isnan(river_pot):
                        river_pot = pot_running
                scommit[nm] = cur + x
                pot_running += x
            elif verb == "raises":
                y = num(ln, r" to[^0-9]*([0-9.]+)")
                pot_running += y - cur
                scommit[nm] = y
            elif verb == "ALLIN":
                x = num(ln, r"ALLIN[^0-9]*([0-9.]+)")
                scommit[nm] = cur + x
                pot_running += x
            elif verb == "RETURN":
                pot_running -= num(ln, r"RETURN[^0-9]*([0-9.]+)")
        if ln.startswith("Hero: "):
            if "posts ante" in ln:
                ante += num(ln, r"ante[^0-9]*([0-9.]+)")
            elif "posts small blind" in ln or "posts big blind" in ln:
                cstreet = num(ln, r"blind[^0-9]*([0-9.]+)")
            elif "raises" in ln:
                cstreet = num(ln, r" to[^0-9]*([0-9.]+)")
                if street == 0:
                    preflop_raise = True
                else:
                    pf_aggr += 1
            elif ": bets" in ln:
                cstreet += num(ln, r"bets[^0-9]*([0-9.]+)")
                if street >= 1:
                    pf_aggr += 1
            elif ": calls" in ln:
                ca = num(ln, r"calls[^0-9]*([0-9.]+)")
                cstreet += ca
                if street == 0:
                    preflop_vpip = True
                else:
                    pf_calls += 1
                if street == 1:
                    flop_call += ca
                if street == 2:
                    turn_call += ca
                if street == 3:
                    river_call += ca
            elif ": ALLIN" in ln:
                cstreet += num(ln, r"ALLIN[^0-9]*([0-9.]+)")
                if street == 0:
                    preflop_vpip = True
                else:
                    pf_aggr += 1
            elif ": RETURN" in ln:
                returned += num(ln, r"RETURN[^0-9]*([0-9.]+)")
            elif ": folds" in ln:
                if fold_street is None:
                    fold_street = street
                if street == 0:
                    folded_pre = True
    saw_turn = turn_occurred and (fold_street is None or fold_street >= 2)
    saw_river = river_occurred and (fold_street is None or fold_street >= 3)
    if preflop_raise:
        preflop_vpip = True
    total_in = ante + committed
    net = collected + returned - total_in
    # a real showdown names a hand rank in Hero's summary line; an uncalled win says only "won (X)"
    saw_flop = flop_occurred and not folded_pre
    si = first_index(L, lambda x: "*** SUMMARY" in x)
    hsum = [x for x in L[si:] if re.match(r"^Seat [0-9]+: Hero", x)] if si is not None else []
    showdown = bool(hsum) and " with " in hsum[0]
    sd_cat = None
    if showdown:
        m = re.search(r" with ([A-Za-z ]+?)(,| and|$)", hsum[0])
        if m:
            sd_cat = m.group(1).strip()
    # the strongest hand any other player tabled: when Hero loses, the winner had to show
    villain_cat = villain_cards = None
    shown = [m for m in (SHOWS.match(x) for x in L) if m and m.group(1) != "Hero"]
    if shown:
        best = max(shown, key=lambda m: RANK_ORDER.get(m.group(3), 0))
        villain_cat, villain_cards = best.group(3), best.group(2)

    # preflop action, all players: raise-first-in, 3-bet, fold to 3-bet
    pf_end = first_index(L, lambda x: bool(re.search(r"\*\*\* (FIRST |SECOND )?(FLOP|SHOWDOWN|SUMMARY)", x)),
                         hole_i + 1)
    pf = L[hole_i + 1: pf_end if pf_end is not None else len(L)]
    rc = 0
    hero_first = hero_open_done = last_raiser_hero = False
    open_raise = three_bet = fold_to_3bet = limp = call_open = False
    rfi_opp = vsopen_opp = ftb_opp = False
    open_to = NA
    opener_name = vsopen_pos = None
    tb_to_bb = tb_ratio = NA
    for ln in pf:
        is_hero = ln.startswith("Hero: ")
        a_raise, a_call, a_fold = ": raises" in ln, ": calls" in ln, ": folds" in ln
        pname = re.match(r"^(\S+):", ln)
        pname = pname.group(1) if pname else ln
        raise_to = NA
        if a_raise:
            m = re.match(r".*\bto[^0-9]*([0-9.]+)", ln)   # greedy: the last "to" on the line
            raise_to = float(m.group(1)) if m else NA
        if is_hero:
            if not hero_first:
                hero_first = True
                if rc == 0:
                    rfi_opp = True
                elif rc == 1:
                    vsopen_opp = True
                    vsopen_pos = name_pos.get(opener_name)
            if a_raise:
                if rc == 0:
                    open_raise = hero_open_done = True
                elif rc == 1:
                    three_bet = True
                    tb_to_bb = raise_to / bb
                    tb_ratio = raise_to / open_to if not math.isnan(open_to) and open_to > 0 else NA
            elif a_call:
                if rc == 0:
                    limp = True
                else:
                    call_open = True
            elif a_fold:
                if hero_open_done and rc >= 2:
                    fold_to_3bet = True
        if a_raise:
            if rc == 0:
                open_to, opener_name = raise_to, pname
            rc += 1
            last_raiser_hero = is_hero
        if hero_open_done and rc >= 2:
            ftb_opp = True
    hero_pf_aggr = rc > 0 and last_raiser_hero

    def flop_lines():
        f0 = first_index(L, lambda x: bool(re.search(r"\*\*\* (FIRST |SECOND )?FLOP", x)))
        if f0 is None:
            return None
        f1 = first_index(L, lambda x: "***" in x, f0 + 1)
        return L[f0 + 1: f1 if f1 is not None else len(L)]

    # flop continuation bet and fold to it
    cbet_opp = cbet_flop = fcbet_opp = fold_to_cbet = False
    n_flop, hero_first_flop = None, None
    fl = flop_lines() if saw_flop else None
    if fl is not None:
        bet_made = hero_acted = False
        for ln in fl:
            is_hero = ln.startswith("Hero: ")
            a_bet, a_raise, a_fold = ": bets" in ln, ": raises" in ln, ": folds" in ln
            if is_hero and not hero_acted:
                hero_acted = True
                if hero_pf_aggr and not bet_made:
                    cbet_opp = True
                    cbet_flop = a_bet
                if not hero_pf_aggr and bet_made:
                    fcbet_opp = True
                    fold_to_cbet = a_fold
            if a_bet or a_raise:
                bet_made = True
        # heads-up or multiway, and whether Hero acts first (out of position) on the flop
        actors = [m.group(1) for m in (FLOP_ACTION.match(x) for x in fl) if m]
        n_flop = len(set(actors))
        hero_first_flop = bool(actors) and actors[0] == "Hero"

    # board cards for single-board hands; run-it-twice hands get none
    multi_board = any(re.search(r"\*\*\* (FIRST|SECOND) (FLOP|TURN|RIVER)", x) for x in L)
    # every collected line, to spot equity cashouts: cashed equity leaves the pot unrecorded
    coll = [x for x in L if "collected" in x]
    all_collected = sum(num(x, r"collected[^0-9]*([0-9.]+)") for x in coll)
    n_collectors = len({re.sub(r"^(\S+) collected.*", r"\1", x) for x in coll})

    def board(tag):
        bl = [x for x in L if re.match(rf"^\*\*\* {tag} \*\*\*", x)]
        if multi_board or not bl:
            return None
        return re.findall(r"\[([^]]+)\]", bl[0])[-1]   # the last bracket holds the new card(s)

    return {
        "id": hid, "datetime": dt, "table_id": table_id, "n_max": n_max, "n_players": n_players,
        "sb": sb, "bb": bb, "ante": ante_hdr, "is_bomb": is_bomb,
        "hero_seat": hero_seat, "button_seat": btn, "hero_pos": hero_pos,
        "hero_cards": hero_cards, "hero_stack": hero_stack,
        "vpip": preflop_vpip, "pfr": preflop_raise, "saw_flop": saw_flop,
        "showdown": showdown, "invested": r2(total_in), "collected": r2(collected), "net": r2(net),
        "rfi_opp": rfi_opp, "open_raise": open_raise, "vsopen_opp": vsopen_opp, "three_bet": three_bet,
        "vsopen_pos": vsopen_pos, "tb_to_bb": r2(tb_to_bb), "tb_ratio": r2(tb_ratio),
        "ftb_opp": ftb_opp, "fold_to_3bet": fold_to_3bet, "limp": limp, "call_open": call_open,
        "saw_turn": saw_turn, "saw_river": saw_river, "hero_pf_aggr": hero_pf_aggr,
        "cbet_opp": cbet_opp, "cbet_flop": cbet_flop, "fcbet_opp": fcbet_opp, "fold_to_cbet": fold_to_cbet,
        "pf_aggr": pf_aggr, "pf_calls": pf_calls,
        "sd_cat": sd_cat, "flop_call": r2(flop_call), "turn_call": r2(turn_call), "river_call": r2(river_call),
        "villain_cat": villain_cat, "villain_cards": villain_cards,
        "flop_call_pot": r2(flop_call_pot), "turn_call_pot": r2(turn_call_pot), "river_pot": r2(river_pot),
        "hero_flop_bet": r2(hero_flop_bet), "hero_flop_pot": r2(hero_flop_pot),
        "hero_turn_bet": r2(hero_turn_bet), "hero_turn_pot": r2(hero_turn_pot),
        "hero_river_bet": r2(hero_river_bet), "hero_river_pot": r2(hero_river_pot),
        "hero_flop_aggr": hero_aggr[1], "hero_turn_aggr": hero_aggr[2], "hero_river_aggr": hero_aggr[3],
        "n_flop": n_flop, "hero_first_flop": hero_first_flop,
        "all_collected": r2(all_collected), "n_collectors": n_collectors,
        "hero_collected": r2(collected), "hero_never_folded": fold_street is None, "multi_board": multi_board,
        "flop": board("FLOP"), "turn_card": board("TURN"), "river_card": board("RIVER"),
        # pot, rake and splash fee from the summary; the splash fee is a house drop like rake
        **summary(L),
    }


def summary(L):
    s = next((x for x in L if "Total pot" in x), None)
    sf = num(s, r"Splash Fee[^0-9]*([0-9.]+)")
    return {"pot": num(s, r"Total pot[^0-9]*([0-9.]+)"), "rake": num(s, r"Rake[^0-9]*([0-9.]+)"),
            "splash_fee": 0.0 if math.isnan(sf) else sf}


def read_blocks(folder):
    files = sorted(Path(folder).glob("*.txt"))
    lines = []
    for f in files:
        lines += f.read_text(encoding="utf-8").splitlines()
    starts = [i for i, x in enumerate(lines) if x.startswith("CoinPoker Hand #")]
    ends = starts[1:] + [len(lines)]
    return files, [lines[a:b] for a, b in zip(starts, ends)]


def parse(folder):
    files, blocks = read_blocks(folder)
    df = pd.DataFrame([parse_block(b) for b in blocks])

    # Equity cashouts: a player who cashes out all-in equity takes money out of the pot without
    # a "collected" line. Credit the shortfall to Hero only when it can only be his: one board,
    # Hero in to the end, Hero collected nothing, and exactly one other player collected.
    df["pot_unaccounted"] = (df.pot - df.rake - df.splash_fee - df.all_collected).clip(lower=0).round(2)
    df["is_cashout"] = df.pot_unaccounted > 0.02
    to_hero = (df.is_cashout & ~df.multi_board & df.hero_never_folded
               & (df.hero_collected <= 0.001) & (df.n_collectors == 1))
    df["cashout_to_hero"] = np.where(to_hero, df.pot_unaccounted, 0.0)
    df["net"] = (df.net + df.cashout_to_hero).round(2)
    df["net_bb"] = (df.net / df.bb).round(2)
    df["dt"] = pd.to_datetime(df.datetime, format="%Y/%m/%d %H:%M:%S")   # Chicago local time, as written

    n_raw = len(df)
    df = df.drop_duplicates("id").reset_index(drop=True)   # overlapping exports repeat hands
    df = df.sort_values("dt", kind="stable").drop(columns="datetime").reset_index(drop=True)
    return df, {"files": len(files), "blocks": n_raw, "dupes": n_raw - len(df)}


def half_up(x, digits):
    return float(Decimal(repr(x)).quantize(Decimal(1).scaleb(-digits), rounding=ROUND_HALF_UP))


def snapshots(df):
    # one row of stats per local calendar day of play, rebuilt from scratch every run
    cash = df[~df.is_bomb].assign(date=df.dt.dt.date)
    rows = []
    for day, g in cash.groupby("date"):
        rows.append({
            "date": day, "n": len(g),
            "vpip": round(g.vpip.mean() * 100, 1), "pfr": round(g.pfr.mean() * 100, 1),
            "threebet": round(g.three_bet.sum() / max(g.vsopen_opp.sum(), 1) * 100, 1),
            "cbet": round(g.cbet_flop.sum() / max(g.cbet_opp.sum(), 1) * 100, 1),
            "fold_to_cbet": round(g.fold_to_cbet.sum() / max(g.fcbet_opp.sum(), 1) * 100, 1),
            "af": round(g.pf_aggr.sum() / max(g.pf_calls.sum(), 1), 2),
            "wtsd": round(g.showdown[g.saw_flop].mean() * 100, 1) if g.saw_flop.any() else NA,
            # net_bb has two decimals: sum it in whole hundredths so a tie like 190.25 rounds up, not
            # down from 190.2499... float noise
            "bb100": half_up(int((g.net_bb * 100).round().sum()) / len(g), 1),
        })
    return pd.DataFrame(rows)


def stack_check(df):
    # If net is right, the next stack at the same table is this stack + net + any top-up. The
    # export's table name spans many physical tables, so "same table" is the hand-id prefix.
    v = df.assign(table_no=df.id // 100000).sort_values(["table_no", "dt"], kind="stable")
    v["resid"] = v.groupby("table_no").hero_stack.shift(-1) - (v.hero_stack + v.net)
    return v.dropna(subset=["resid"])


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--hands", default="hands")
    ap.add_argument("--out", default=".")
    args = ap.parse_args(argv)
    df, info = parse(args.hands)
    out = Path(args.out)
    df.to_csv(out / "coinpoker_hands.csv", index=False)
    daily = snapshots(df)
    daily.to_csv(out / "coinpoker_snapshots.csv", index=False)
    v = stack_check(df)
    big = v[v.resid < -0.02]
    print(f"Cashout hands: {int(df.is_cashout.sum())} total ({int((df.cashout_to_hero > 0).sum())} "
          f"heads-up Hero cashouts credited: +{df.cashout_to_hero.sum():.2f} T to net)")
    print(f"Wrote per-day trend table: {len(daily)} active days -> coinpoker_snapshots.csv")
    print(f"Read {info['files']} files, {info['blocks']} hand blocks; removed {info['dupes']} "
          f"duplicate id(s) -> {len(df)} unique hands.")
    print(f"Stack-delta validation on {len(v)} pairs: {100 * (v.resid.abs() < 0.02).mean():.1f}% exact, "
          f"{100 * (v.resid >= -0.02).mean():.1f}% explained by net + top-up.")
    if len(big):
        print(f"  Of the {len(big)} unexplained (negative) residuals, {100 * (big.net.abs() < 1).mean():.0f}% "
              f"have |net|<1 -> stack resets, not net errors.")
    print(f"Total net: {df.net.sum():.2f} T | rake: {df.rake.sum():.2f} T | splash fees: "
          f"{df.splash_fee.sum():.2f} T | bb/100: {df.net_bb.sum() / len(df) * 100:.2f}")


if __name__ == "__main__":
    main()
