"""Shared 5/7-card hand evaluator + equity calc, used by allin_ev.py and luck_ledger.py.
eval5/best7 return a comparable tuple (higher = better). equity() is exact for flop/turn
boards (or the river, need=0) and Monte Carlo for preflop (need=5).
"""
import itertools
import random
from collections import Counter

RANKS = "23456789TJQKA"
RV = {r: i + 2 for i, r in enumerate(RANKS)}


def eval5(cards):
    rs = sorted((RV[c[0]] for c in cards), reverse=True)
    suits = [c[1] for c in cards]
    flush = len(set(suits)) == 1
    cnt = Counter(rs); uniq = sorted(cnt, key=lambda r: (cnt[r], r), reverse=True)
    dr = sorted(set(rs), reverse=True)
    straight_hi = None
    if len(dr) >= 5:
        for i in range(len(dr) - 4):
            if dr[i] - dr[i + 4] == 4:
                straight_hi = dr[i]; break
    if straight_hi is None and set([14, 5, 4, 3, 2]).issubset(set(rs)):
        straight_hi = 5
    if flush and straight_hi: return (8, straight_hi)
    if cnt[uniq[0]] == 4: return (7, uniq[0], uniq[1])
    if cnt[uniq[0]] == 3 and cnt[uniq[1]] >= 2: return (6, uniq[0], uniq[1])
    if flush: return (5,) + tuple(rs)
    if straight_hi: return (4, straight_hi)
    if cnt[uniq[0]] == 3: return (3, uniq[0]) + tuple(r for r in rs if r != uniq[0])[:2]
    if cnt[uniq[0]] == 2 and cnt[uniq[1]] == 2:
        hi, lo = sorted([uniq[0], uniq[1]], reverse=True)
        return (2, hi, lo, max(r for r in rs if r != hi and r != lo))
    if cnt[uniq[0]] == 2: return (1, uniq[0]) + tuple(r for r in rs if r != uniq[0])[:3]
    return (0,) + tuple(rs)


def best7(cards):
    return max(eval5(list(c)) for c in itertools.combinations(cards, 5))


def equity(hero, vill, board, mc=20000):
    """P(hero wins) + 0.5*P(tie), given known hero+villain holes and a partial/empty board."""
    dead = set(hero + vill + board)
    deck = [r + s for r in RANKS for s in "cdhs" if r + s not in dead]
    need = 5 - len(board)
    if need == 0:
        h, v = best7(hero + board), best7(vill + board)
        return 1.0 if h > v else 0.0 if h < v else 0.5
    win = tie = tot = 0
    runouts = itertools.combinations(deck, need)
    if need >= 3:  # preflop: sample rather than enumerate C(47,5)
        runouts = (random.sample(deck, need) for _ in range(mc))
    for ro in runouts:
        b = board + list(ro)
        h, v = best7(hero + b), best7(vill + b)
        if h > v: win += 1
        elif h == v: tie += 1
        tot += 1
    return (win + tie / 2) / tot


def equity_vs_random(hole, board=(), mc=3000):
    """Raw hot/cold equity of `hole` vs one random opponent hand, given board (possibly empty).
    Used for card-luck: a pure function of the cards dealt, independent of what villain
    actually held or how the hand was played."""
    board = list(board)
    dead = set(hole) | set(board)
    deck = [r + s for r in RANKS for s in "cdhs" if r + s not in dead]
    win = tie = tot = 0
    for _ in range(mc):
        random.shuffle(deck)
        vill = deck[:2]
        need = 5 - len(board)
        ro = deck[2:2 + need]
        b = board + ro
        h, v = best7(hole + b), best7(vill + b)
        if h > v: win += 1
        elif h == v: tie += 1
        tot += 1
    return (win + tie / 2) / tot
