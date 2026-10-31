#!/usr/bin/env python3
"""
simulate_hands.py
=================
Write synthetic 6-max no-limit hold'em cash hands in CoinPoker's text export
format, so the whole pipeline and dashboard run without anyone's real history.

Every hand is played through PokerKit's engine with real cards, so pots, side
pots, uncalled bets and showdowns are exact. Players follow simple strategies
driven by hand strength: the preflop Chen score, then the made-hand rank on the
board. Hero's strategy has a few leaks planted on purpose (PROFILES["hero"]):
cold-calling too wide in position and folding too often to flop c-bets. The
dashboard should find them.

Hero's stack carries over from hand to hand at each table (the parser checks
each hand's net against the next stack), with a top-up to 100 bb when it falls
under 60 bb. Rake is 5% capped at 3 bb, taken only when a flop is dealt.

    python3 simulate_hands.py --hands 10000 --out hands --seed 7
"""
from __future__ import annotations

import argparse
import os
import random
import warnings
from datetime import datetime, timedelta

from pokerkit import Automation, Mode, NoLimitTexasHoldem, StandardHighHand

warnings.filterwarnings("ignore", message="A card being dealt")  # we deal from our own seeded deck
RANKS, SUITS = "23456789TJQKA", "cdhs"
STAKES = [  # small blind, big blind, ante, in cents; share of Hero's hands
    ((5, 10, 1), 0.55), ((10, 25, 3), 0.35), ((25, 50, 5), 0.10)]
AUTOMATIONS = (
    Automation.ANTE_POSTING, Automation.BET_COLLECTION, Automation.BLIND_OR_STRADDLE_POSTING,
    Automation.CARD_BURNING, Automation.HOLE_CARDS_SHOWING_OR_MUCKING, Automation.HAND_KILLING,
    Automation.CHIPS_PUSHING, Automation.CHIPS_PULLING, Automation.RUNOUT_COUNT_SELECTION,
)
POS6 = ["SB", "BB", "UTG", "HJ", "CO", "BTN"]

# Preflop thresholds are Chen scores (about 10+ is the top 5% of hands, 7+ the top 17%,
# 5+ the top third). Postflop numbers are probabilities.
PROFILES = {
    "hero": dict(open={"UTG": 8, "HJ": 7.5, "CO": 6.5, "BTN": 5, "SB": 6},
                 cold_call={"IP": 4, "OOP": 7},          # planted leak: flats junk in position
                 three_bet=9.5, three_bet_bluff=0.04, defend_bb=4.5, fold_to_3bet=0.55,
                 cbet=0.60, value_bet=0.80, bluff=0.10,
                 fold_to_cbet=0.70,                      # planted leak: overfolds the flop
                 call_pair=0.70, raise_strong=0.30),
    "fish": dict(open={"UTG": 4, "HJ": 4, "CO": 3.5, "BTN": 3, "SB": 3},
                 cold_call={"IP": 2, "OOP": 3}, three_bet=11, three_bet_bluff=0.01, defend_bb=1,
                 fold_to_3bet=0.25, cbet=0.40, value_bet=0.55, bluff=0.05,
                 fold_to_cbet=0.30, call_pair=0.92, raise_strong=0.10),
    "nit": dict(open={"UTG": 10, "HJ": 9.5, "CO": 9, "BTN": 8, "SB": 9},
                cold_call={"IP": 9, "OOP": 10}, three_bet=12, three_bet_bluff=0.0, defend_bb=8,
                fold_to_3bet=0.75, cbet=0.55, value_bet=0.70, bluff=0.03,
                fold_to_cbet=0.60, call_pair=0.55, raise_strong=0.25),
    "reg": dict(open={"UTG": 8, "HJ": 7, "CO": 6, "BTN": 4.5, "SB": 5.5},
                cold_call={"IP": 7, "OOP": 8.5}, three_bet=9, three_bet_bluff=0.05, defend_bb=4,
                fold_to_3bet=0.50, cbet=0.62, value_bet=0.80, bluff=0.12,
                fold_to_cbet=0.48, call_pair=0.72, raise_strong=0.35),
    "lag": dict(open={"UTG": 6.5, "HJ": 6, "CO": 5, "BTN": 3.5, "SB": 4.5},
                cold_call={"IP": 6, "OOP": 7.5}, three_bet=8, three_bet_bluff=0.10, defend_bb=3,
                fold_to_3bet=0.40, cbet=0.75, value_bet=0.85, bluff=0.20,
                fold_to_cbet=0.40, call_pair=0.75, raise_strong=0.40),
}
POOL = [("fish", 0.30), ("nit", 0.20), ("reg", 0.35), ("lag", 0.15)]
SYLL = ["ka", "ro", "mi", "ten", "za", "lu", "vo", "pex", "dri", "fen", "gal", "or", "bu", "sti", "nax"]


def chen(c1: str, c2: str) -> float:
    """Chen formula for a two-card starting hand."""
    pts = {"A": 10, "K": 8, "Q": 7, "J": 6, "T": 5}
    r1, r2 = sorted([c1[0], c2[0]], key=RANKS.index, reverse=True)
    s = pts.get(r1, (RANKS.index(r1) + 2) / 2)
    if r1 == r2:
        return max(5, s * 2)
    if c1[1] == c2[1]:
        s += 2
    gap = RANKS.index(r1) - RANKS.index(r2) - 1
    s -= [0, 1, 2, 4][min(gap, 3)] if gap < 4 else 5
    if gap <= 1 and RANKS.index(r1) < RANKS.index("Q"):
        s += 1
    return s


def made_strength(hole: str, board: list[str]) -> int:
    """Hand rank (0 high card .. 8 straight flush) that the hole cards add over the board alone."""
    rank = list(StandardHighHand.from_game(hole, "".join(board)).entry.label.__class__).index(
        StandardHighHand.from_game(hole, "".join(board)).entry.label)
    counts = sorted([sum(c[0] == r for c in board) for r in {c[0] for c in board}], reverse=True)
    board_rank = 3 if counts[0] >= 3 else 2 if counts[:2] == [2, 2] else 1 if counts[0] == 2 else 0
    return rank if rank > board_rank else 0


def money(cents: int) -> str:
    return "₮" + (f"{cents / 100:.2f}".rstrip("0").rstrip("."))


def position(idx: int, n: int) -> str:
    """PokerKit index (0 = small blind) to a position label."""
    if idx < 2:
        return POS6[idx]
    return POS6[6 - (n - idx)]


def label(hole: str, board: list[str]) -> str:
    return StandardHighHand.from_game(hole, "".join(board)).entry.label.value.title()


class Table:
    def __init__(self, rng: random.Random, name: str, stake: tuple[int, int, int]):
        self.rng, self.name, self.stake = rng, name, stake
        self.hero_stack = 100 * stake[1]
        self.hero_fees = 0   # rake Hero paid, in cents, for the rakeback ledger
        self.truth = []      # (hand id, Hero net, VPIP, saw flop): the known answers the tests check
        self.button = rng.randint(1, 6)
        self.number = rng.randint(1000, 9999)   # hand ids are number * 100000 + a per-table counter
        self.counter = rng.randint(1, 50000)
        self.seats = {s: self._new_player() for s in range(1, 7)}
        self.hero_seat = rng.randint(1, 6)
        self.seats[self.hero_seat] = ("Hero", "hero")

    def _new_player(self):
        name = "".join(self.rng.choice(SYLL) for _ in range(self.rng.randint(2, 3)))
        name += str(self.rng.randint(1, 999)) if self.rng.random() < 0.6 else ""
        kind = self.rng.choices([k for k, _ in POOL], [w for _, w in POOL])[0]
        return (name, kind)

    def churn(self):
        for s in self.seats:
            if s != self.hero_seat and self.rng.random() < 0.03:
                self.seats[s] = self._new_player()


def play(table: Table, hand_id: int, when: datetime) -> list[str]:
    rng = table.rng
    sb, bb, ante = table.stake
    # seats empty now and then: 3 to 6 players, Hero always in
    occupied = [s for s in sorted(table.seats) if s == table.hero_seat or rng.random() > 0.08]
    if len(occupied) < 3:
        occupied = sorted(table.seats)
    while table.button not in occupied:
        table.button = table.button % 6 + 1
    b = occupied.index(table.button)
    order = occupied[b + 1:] + occupied[:b + 1]   # PokerKit order: SB, BB, ..., BTN
    n = len(order)
    names = [table.seats[s][0] for s in order]
    kinds = [table.seats[s][1] for s in order]
    stacks = [table.hero_stack if nm == "Hero" else bb * rng.randint(40, 250) for nm in names]
    state = NoLimitTexasHoldem.create_state(AUTOMATIONS, False, ante, (sb, bb), bb, stacks, n,
                                            mode=Mode.CASH_GAME)
    deck = [r + s for r in RANKS for s in SUITS]
    rng.shuffle(deck)
    holes, board = [None] * n, []
    lines = [f"CoinPoker Hand #{hand_id}: NLH ({money(sb)}/{money(bb)}/{money(ante)}) "
             f"{when:%Y/%m/%d %H:%M:%S} CDT",
             f"Table '{table.name}' 6-max Seat #{table.button} is the button"]
    lines += [f"Seat {s}: {nm} ({money(st)} in chips)" for s, nm, st in sorted(zip(order, names, stacks))]
    lines += [f"{nm}: posts ante {money(ante)}" for nm in names]
    lines += [f"{names[0]}: posts small blind {money(sb)}", f"{names[1]}: posts big blind {money(bb)}"]
    lines.append("*** HOLE CARDS ***")

    contrib = [ante + (sb if i == 0 else bb if i == 1 else 0) for i in range(n)]
    street_in = [sb, bb] + [0] * (n - 2)
    returned = [0] * n
    folded_on = [None] * n
    voluntary = [False] * n
    pf_raiser, raises_pf, street_agg = None, 0, {}

    def close_street():
        top = sorted(street_in, reverse=True)
        if len(top) > 1 and top[0] > top[1]:
            i = street_in.index(top[0])
            back = top[0] - top[1]
            returned[i] += back
            lines.append(f"{names[i]}: RETURN {money(back)}")

    while state.status:
        if state.can_deal_hole():
            i = state.hole_dealee_index
            if holes[i] is None:
                holes[i] = deck.pop() + deck.pop()
                lines.append(f"Dealt to {names[i]}" + (f" [{holes[i][:2]} {holes[i][2:]}]" if names[i] == "Hero" else ""))
            state.deal_hole(holes[i][:2] if len(state.hole_cards[i]) == 0 else holes[i][2:])
            continue
        if state.can_deal_board():
            close_street()
            street_in = [0] * n
            k = 3 if not board else 1
            new = [deck.pop() for _ in range(k)]
            state.deal_board("".join(new))
            if k == 3:
                lines.append(f"*** FLOP *** [{' '.join(new)}]")
            else:
                lines.append(f"*** {'TURN' if len(board) == 3 else 'RIVER'} *** [{' '.join(board)}] [{new[0]}]")
            board += new
            continue
        if state.actor_index is None:
            break
        i, street = state.actor_index, state.street_index
        p = PROFILES[kinds[i]]
        pos = position(i, n)
        to_call = state.checking_or_calling_amount
        pot = state.total_pot_amount
        can_raise = state.can_complete_bet_or_raise_to()
        lo = state.min_completion_betting_or_raising_to_amount if can_raise else 0
        hi = state.max_completion_betting_or_raising_to_amount if can_raise else 0
        before = state.stacks[i]
        max_bet = max(state.bets)

        def act(kind, target=None):
            nonlocal pf_raiser, raises_pf
            if kind == "raise" and can_raise:
                target = max(lo, min(hi, int(target)))
                if target >= hi * 0.85:
                    target = hi
                mine = state.bets[i]
                state.complete_bet_or_raise_to(target)
                added = target - mine
            elif kind == "fold" and to_call > 0:
                state.fold()
                folded_on[i] = street
                return
            else:
                kind = "call"
                added = state.check_or_call().amount
            # read amounts from the action, not the stack: the last action of a hand
            # also pays the pot out in the same step
            contrib[i] += added
            street_in[i] += added
            if street == 0 and added > 0:
                voluntary[i] = True
            if before - added == 0 and added > 0:
                lines.append(f"{names[i]}: ALLIN {money(added)}")
            elif kind == "raise":
                if max_bet == 0:
                    lines.append(f"{names[i]}: bets {money(added)}")
                else:
                    lines.append(f"{names[i]}: raises {money(target - max_bet)} to {money(target)}")
            elif added == 0:
                lines.append(f"{names[i]}: checks")
            else:
                lines.append(f"{names[i]}: calls {money(added)}")
            if kind == "raise":
                street_agg[street] = i
                if street == 0:
                    pf_raiser, raises_pf = i, raises_pf + 1

        def act_fold():
            lines.append(f"{names[i]}: folds") if to_call > 0 else None
            act("fold")

        if street == 0:
            score = chen(holes[i][:2], holes[i][2:])
            ip = pos in ("CO", "BTN")
            if raises_pf == 0:
                if pos == "BB":
                    if can_raise and score >= p["open"]["UTG"] + 1:
                        act("raise", 4 * bb)
                    else:
                        act("call")
                elif score >= p["open"].get(pos, 99) and can_raise:
                    act("raise", (3 if pos != "SB" else 3.5) * bb)
                elif score >= p["cold_call"]["IP" if ip else "OOP"] + 2 and rng.random() < 0.3:
                    act("call")                                   # limp
                else:
                    act_fold()
            elif raises_pf == 1:
                if can_raise and (score >= p["three_bet"] or rng.random() < p["three_bet_bluff"]):
                    act("raise", 3 * max_bet if ip else 3.8 * max_bet)
                elif score >= (p["defend_bb"] if pos == "BB" else p["cold_call"]["IP" if ip else "OOP"]):
                    act("call")
                else:
                    act_fold()
            else:
                if score >= 11 and can_raise and raises_pf < 3:
                    act("raise", 2.4 * max_bet)
                elif score >= 9 or (i == pf_raiser and rng.random() > p["fold_to_3bet"]):
                    act("call")
                else:
                    act_fold()
            continue

        strength = made_strength(holes[i], board)
        if to_call == 0:
            if strength >= 2 and rng.random() < p["value_bet"]:
                act("raise", pot * rng.uniform(0.55, 0.8))
            elif strength == 1 and rng.random() < (p["cbet"] if i == pf_raiser and street == 1 else 0.45):
                act("raise", pot * rng.uniform(0.4, 0.66))
            elif street == 1 and i == pf_raiser and rng.random() < p["cbet"] * 0.8:
                act("raise", pot * rng.uniform(0.3, 0.5))        # c-bet with air
            elif rng.random() < p["bluff"]:
                act("raise", pot * rng.uniform(0.5, 0.9))
            else:
                act("call")                                       # check
            continue

        facing_cbet = street == 1 and street_agg.get(1) == pf_raiser and pf_raiser != i
        price = to_call / max(pot, 1)
        if strength >= 2:
            act("raise", 3 * max_bet) if rng.random() < p["raise_strong"] else act("call")
        elif strength == 1:
            stay = p["call_pair"] - 0.25 * max(0.0, price - 0.5)
            if facing_cbet:
                stay = max(stay, 1 - p["fold_to_cbet"] + 0.25)
            act("call") if rng.random() < stay else act_fold()
        else:
            stay = (1 - p["fold_to_cbet"]) * 0.7 if facing_cbet else p["bluff"] * 0.8
            act("call") if rng.random() < stay else act_fold()

    close_street()
    live = [i for i in range(n) if folded_on[i] is None]
    payoffs = list(state.payoffs)
    collected = [payoffs[i] + contrib[i] - returned[i] for i in range(n)]
    pot_total = sum(contrib) - sum(returned)
    rake = min(round(pot_total * 0.05), 3 * bb) if board else 0
    # take the rake from whoever collected, in proportion
    won = sum(c for c in collected if c > 0)
    cuts = [round(rake * c / won) if c > 0 else 0 for c in collected]
    if won:
        cuts[max(range(n), key=lambda j: collected[j])] += rake - sum(cuts)
    collected = [c - x for c, x in zip(collected, cuts)]
    showdown = len(live) > 1
    full = board + [deck.pop() for _ in range(5 - len(board))] if showdown and len(board) < 5 else board
    if showdown:
        lines.append("*** SHOWDOWN ***")
        for j in live:
            lines.append(f"{names[j]}: shows [{holes[j][:2]} {holes[j][2:]}] ({label(holes[j], full)})")
            if collected[j] > 0:
                lines.append(f"{names[j]} collected {money(collected[j])} from pot")
    else:
        j = live[0]
        lines.append(f"{names[j]} collected {money(collected[j])} from pot")
    lines += ["*** SUMMARY ***", f"Total pot {money(pot_total)} | Rake {money(rake)} | Splash Fee ₮0",
              "Hand was run once"]
    if full:
        lines.append(f"Board [ {' '.join(full)} ]")
    lines.append(f"Game ended: {when + timedelta(seconds=rng.randint(25, 90)):%Y/%m/%d %H:%M:%S} CDT")
    streets = ["before Flop", "on the Flop", "on the Turn", "on the River"]
    for j, s in sorted(enumerate(order), key=lambda x: x[1]):
        if folded_on[j] is not None:
            tail = " (didn't bet)" if folded_on[j] == 0 and not voluntary[j] else ""
            lines.append(f"Seat {s}: {names[j]} folded {streets[folded_on[j]]}{tail}")
        elif showdown:
            res = f"won ({money(collected[j])})" if collected[j] > 0 else "lost"
            lines.append(f"Seat {s}: {names[j]} showed [{holes[j][:2]} {holes[j][2:]}] and {res} with {label(holes[j], full)}")
        else:
            lines.append(f"Seat {s}: {names[j]} won ({money(collected[j])})")

    h = names.index("Hero")
    table.hero_stack = stacks[h] + payoffs[h] - cuts[h]
    if table.hero_stack < 60 * bb:
        table.hero_stack = 100 * bb
    table.button = order[0] if n > 1 else table.button   # button moves to the old small blind
    table.churn()
    table.hero_fees += cuts[h]
    table.truth.append((hand_id, (payoffs[h] - cuts[h]) / 100, int(voluntary[h]),
                        int(bool(board) and folded_on[h] != 0)))
    return lines + ["", "", ""]


def write(out_dir: str, total: int, seed: int, start="2026-03-02", days=84,
          rakeback_csv: str | None = "coinpoker_rakeback.csv", rakeback_rate=0.30,
          truth_csv: str | None = None) -> int:
    rng = random.Random(seed)
    os.makedirs(out_dir, exist_ok=True)
    written, owed, claims, truth = 0, 0.0, [], []
    day0 = datetime.fromisoformat(start)
    play_days = sorted(rng.sample(range(days), int(days * 0.6)))
    per_day = total // len(play_days)
    for d in play_days:
        stake = rng.choices([s for s, _ in STAKES], [w for _, w in STAKES])[0]
        n_tables = rng.choice([1, 2, 2, 3])
        start_t = day0 + timedelta(days=d, hours=rng.choice([12, 18, 19, 20, 21]), minutes=rng.randint(0, 59))
        tables = [Table(rng, f"{rng.choice(['Aurora', 'Basalt', 'Cobalt', 'Delta', 'Ember', 'Fjord'])} {rng.randint(1, 40)}",
                        stake) for _ in range(n_tables)]
        out = []
        for k in range(per_day + rng.randint(-per_day // 3, per_day // 3)):
            t = tables[k % n_tables]
            t.counter += 1
            out += play(t, t.number * 100000 + t.counter, start_t + timedelta(seconds=70 * (k // n_tables)))
            written += 1
        with open(os.path.join(out_dir, f"synthetic_{(day0 + timedelta(days=d)):%Y%m%d}.txt"), "w",
                  encoding="utf-8") as f:
            f.write("\n".join(out))
        truth += [row for t in tables for row in t.truth]
        # rakeback accrues per hand but is claimed by hand, on irregular days
        owed += sum(t.hero_fees for t in tables) * rakeback_rate / 100
        if owed > 1 and rng.random() < 0.35:
            end = start_t + timedelta(seconds=70 * (k // n_tables) + rng.randint(600, 7200))
            claims.append((f"{end:%Y-%m-%d %H:%M:%S}", round(owed, 2), len(claims) + 1))
            owed = 0.0
    if rakeback_csv:
        with open(rakeback_csv, "w", newline="") as f:
            f.write("dt,amount,transfer,msg_id\n")
            for dt, amt, k in claims:
                f.write(f"{dt},{amt:.2f},Rewards Balance to Cash Balance,synthetic-{k:03d}\n")
    if truth_csv:
        with open(truth_csv, "w", newline="") as f:
            f.write("id,net,vpip,saw_flop\n")
            f.writelines(f"{i},{n:.2f},{v},{sf}\n" for i, n, v, sf in truth)
    return written


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description="Synthetic CoinPoker-format hand histories")
    ap.add_argument("--hands", type=int, default=10000)
    ap.add_argument("--out", default="hands")
    ap.add_argument("--seed", type=int, default=7)
    ap.add_argument("--truth", default=None, help="also write Hero's true net, VPIP and flops seen per hand")
    a = ap.parse_args()
    print(f"{write(a.out, a.hands, a.seed, truth_csv=a.truth):,} hands -> {a.out}/")
