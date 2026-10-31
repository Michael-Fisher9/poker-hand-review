#!/usr/bin/env python3
"""All-in EV: for every hand where Hero got all-in with cards to come and it showed
down (both hands known), compute Hero's EQUITY at the all-in point and compare it to
what he actually won. Separates skill (were you a favorite?) from luck (did it hold?).

Only clean HEADS-UP all-ins (exactly 2 shown, no side pots) are used. Equity is exact
for flop/turn all-ins; Monte-Carlo (20k) for preflop. Reads the raw exports directly.
Run: python3 allin_ev.py
"""
import glob, os, re, random
from poker_eval import equity

HERE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "hands")

def parse():
    seen = set(); out = []
    for f in glob.glob(HERE + "/*.txt"):
        for blk in re.split(r"(?=CoinPoker Hand #)", open(f, encoding="utf-8", errors="ignore").read()):
            m = re.search(r"Hand #(\d+)", blk)
            if not m or m.group(1) in seen: continue
            seen.add(m.group(1))
            if "Dealt to Hero" not in blk or "*** SUMMARY" not in blk: continue
            shows = re.findall(r"^(\S+): shows \[([^\]]+)\]", blk, re.M)
            shown = {n: c.split() for n, c in shows}
            if len(shown) != 2 or "Hero" not in shown: continue      # clean HU showdown
            # street of the all-in
            cur = "pre"; allin_street = None
            for ln in blk.splitlines():
                if ln.startswith("*** "):
                    cur = "flop" if "FLOP" in ln else "turn" if "TURN" in ln else "river" if "RIVER" in ln else cur
                if re.match(r"^\S+: ALLIN", ln): allin_street = cur
            if allin_street not in ("pre", "flop", "turn"): continue   # need cards to come
            def brd(tag):
                mm = re.search(r"\*\*\* " + tag + r" \*\*\*[^\n]*\[([^\]]+)\]", blk)
                return mm.group(1).split() if mm else []
            board = {"pre": [], "flop": brd("FLOP"), "turn": brd("FLOP") + brd("TURN")}[allin_street]
            vill = next(n for n in shown if n != "Hero")
            if len(shown["Hero"]) != 2 or len(shown[vill]) != 2: continue
            pot = re.search(r"Total pot ₮([\d.]+)", blk); rake = re.search(r"Rake ₮([\d.]+)", blk)
            sf = re.search(r"Splash Fee ₮([\d.]+)", blk)
            pot = float(pot.group(1)) if pot else 0
            fee = (float(rake.group(1)) if rake else 0) + (float(sf.group(1)) if sf else 0)
            hero_coll = sum(float(x) for x in re.findall(r"^Hero collected ₮([\d.]+)", blk, re.M))
            dt = re.search(r"(\d{4}/\d\d/\d\d)", blk)
            out.append(dict(hid=m.group(1), day=dt.group(1) if dt else "", street=allin_street,
                            hero=shown["Hero"], vill=shown[vill], board=board,
                            pot=pot - fee, collected=hero_coll))
    return out

def main():
    hands = parse()
    print(f"clean HU all-in-with-cards-to-come showdowns: {len(hands)}\n")
    tot_eq = tot_exp = tot_act = 0.0; got_in_good = 0
    per = {}
    for h in hands:
        e = equity(h["hero"], h["vill"], h["board"])
        exp = e * h["pot"]                 # equity share of the (post-fee) pot
        tot_eq += e; tot_exp += exp; tot_act += h["collected"]
        if e > 0.5: got_in_good += 1
        d = h["day"][:7]                   # by month
        p = per.setdefault(d, [0, 0.0, 0.0]); p[0] += 1; p[1] += exp; p[2] += h["collected"]
    n = len(hands)
    print(f"avg Hero equity when all-in : {100*tot_eq/n:.1f}%   (got it in as a favorite: {got_in_good}/{n} = {100*got_in_good/n:.0f}%)")
    print(f"EXPECTED to collect (equity): ${tot_exp:.0f}")
    print(f"ACTUALLY collected          : ${tot_act:.0f}")
    print(f"ALL-IN LUCK (actual-expected): ${tot_act-tot_exp:+.0f}   ({'ran BELOW' if tot_act<tot_exp else 'ran ABOVE'} equity)\n")
    for d, (c, exp, act) in sorted(per.items()):
        print(f"  {d:18} n={c:3}  expected ${exp:6.0f}  actual ${act:6.0f}  luck ${act-exp:+6.0f}")

if __name__ == "__main__":
    random.seed(1); main()
