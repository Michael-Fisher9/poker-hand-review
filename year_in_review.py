#!/usr/bin/env python3
"""Year-in-review: the fun stat card. Biggest pot, luckiest/unluckiest river, nemesis starting
hand, best hour/weekday, total fees paid. Pure fun, no leak-fixing agenda - a one-page shareable
summary of a genuinely interesting dataset. Writes a standalone styled coinpoker_year_in_review.html
(not part of the main dashboard). Run: python3 year_in_review.py
"""
import csv
import datetime
import os

from poker_eval import equity
import allin_ev

HERE = os.path.dirname(os.path.abspath(__file__))
FEAT = os.path.join(HERE, "coinpoker_features.csv")
OUT = os.path.join(HERE, "coinpoker_year_in_review.html")

DOW = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]


def isna(v):
    return v in ("NA", "", None)


def load_rows():
    with open(FEAT, newline="", encoding="utf-8") as f:
        rows = list(csv.DictReader(f))
    return [r for r in rows if r.get("is_bomb") != "TRUE"]


def fmt(cards):
    return cards.replace(" ", " ") if cards else ""


def main():
    rows = load_rows()
    n = len(rows)

    def parse_dt(s):
        try:
            return datetime.datetime.strptime(s, "%Y-%m-%d %H:%M:%S")
        except ValueError:
            return datetime.datetime.strptime(s, "%Y-%m-%d")

    dts = [parse_dt(r["dt"]) for r in rows]
    date_lo, date_hi = min(dts), max(dts)

    biggest_win = max(rows, key=lambda r: float(r["net"]))
    biggest_loss = min(rows, key=lambda r: float(r["net"]))

    # nemesis / best starting hand (min 15 hands played)
    by_hand = {}
    for r in rows:
        h = r.get("hand169")
        if isna(h):
            continue
        by_hand.setdefault(h, []).append(float(r["net"]))
    qualifying = {h: v for h, v in by_hand.items() if len(v) >= 15}
    nemesis = min(qualifying.items(), key=lambda kv: sum(kv[1]))
    best_hand = max(qualifying.items(), key=lambda kv: sum(kv[1]))

    # by hour / weekday
    by_hour = {}
    by_dow = {}
    for r, dt in zip(rows, dts):
        by_hour.setdefault(dt.hour, []).append(float(r["net"]))
        by_dow.setdefault(dt.weekday(), []).append(float(r["net"]))
    best_hour = max(by_hour.items(), key=lambda kv: sum(kv[1]))
    worst_hour = min(by_hour.items(), key=lambda kv: sum(kv[1]))
    best_dow = max(by_dow.items(), key=lambda kv: sum(kv[1]))

    total_rake = sum(float(r["hero_rake"]) for r in rows)
    total_splash = sum(float(r["hero_splash"]) for r in rows)

    # luckiest / unluckiest river (mirrors luck_ledger's river-card-luck component, per-hand)
    ai_hands = allin_ev.parse()
    exclude_ids = set(h["hid"] for h in ai_hands)
    river_luck = []
    for r in rows:
        if (r["showdown"] != "TRUE" or isna(r["villain_cards"]) or isna(r["flop"])
                or isna(r["turn_card"]) or isna(r["river_card"]) or r["n_flop"] != "2"
                or r["id"] in exclude_ids):
            continue
        hero = r["hero_cards"].split(); vill = r["villain_cards"].split()
        board4 = r["flop"].split() + [r["turn_card"]]
        river = r["river_card"]
        if len(hero) != 2 or len(vill) != 2 or len(board4) != 4:
            continue
        e_before = equity(hero, vill, board4)
        result = equity(hero, vill, board4 + [river])
        pot_net = float(r["pot"]) - float(r["rake"]) - float(r["splash_fee"])
        swing = (result - e_before) * pot_net
        river_luck.append((swing, r))
    luckiest = max(river_luck, key=lambda t: t[0]) if river_luck else None
    unluckiest = min(river_luck, key=lambda t: t[0]) if river_luck else None

    def hand_block(r, extra=""):
        return (f'<div class="hb"><span class="cards">{fmt(r["hero_cards"])}</span> '
                f'<span class="board">{fmt(r.get("flop","") or "")} {fmt(r.get("turn_card","") or "")} {fmt(r.get("river_card","") or "")}</span> '
                f'<span class="date">{r["dt"][:10]}</span>{extra}</div>')

    def stat_card(label, value, sub=""):
        return f'<div class="card"><div class="label">{label}</div><div class="value">{value}</div><div class="sub">{sub}</div></div>'

    cards_html = ""
    cards_html += stat_card("Hands played", f"{n:,}", f'{date_lo:%b %d, %Y} &ndash; {date_hi:%b %d, %Y}')
    cards_html += stat_card("Biggest pot won", f"${float(biggest_win['net']):+,.2f}",
                             hand_block(biggest_win))
    cards_html += stat_card("Biggest pot lost", f"${float(biggest_loss['net']):+,.2f}",
                             hand_block(biggest_loss))
    cards_html += stat_card("Nemesis starting hand", nemesis[0],
                             f"${sum(nemesis[1]):+,.2f} over {len(nemesis[1])} hands "
                             f"({sum(nemesis[1])/len(nemesis[1])*100/2:+.0f} bb/100-ish avg)")
    cards_html += stat_card("Best starting hand", best_hand[0],
                             f"${sum(best_hand[1]):+,.2f} over {len(best_hand[1])} hands")
    cards_html += stat_card("Best hour to play", f"{best_hour[0]:02d}:00",
                             f"${sum(best_hour[1]):+,.2f} over {len(best_hour[1])} hands")
    cards_html += stat_card("Worst hour to play", f"{worst_hour[0]:02d}:00",
                             f"${sum(worst_hour[1]):+,.2f} over {len(worst_hour[1])} hands")
    cards_html += stat_card("Best day of week", DOW[best_dow[0]],
                             f"${sum(best_dow[1]):+,.2f} over {len(best_dow[1])} hands")
    cards_html += stat_card("Fees paid", f"${total_rake + total_splash:,.2f}",
                             f"${total_rake:,.2f} rake + ${total_splash:,.2f} splash &mdash; the rakeback basis")
    if luckiest:
        cards_html += stat_card("Luckiest river", f"{luckiest[0]:+,.2f}", hand_block(luckiest[1]))
    if unluckiest:
        cards_html += stat_card("Unluckiest river (worst bad beat)", f"{unluckiest[0]:+,.2f}", hand_block(unluckiest[1]))

    html = f"""<!doctype html>
<html><head><meta charset="utf-8"><title>CoinPoker Year in Review</title>
<style>
  body {{ background: #14181c; color: #eef1f3; font-family: -apple-system, "Segoe UI", Helvetica, Arial, sans-serif;
          margin: 0; padding: 40px 20px; }}
  h1 {{ text-align: center; font-size: 28px; margin-bottom: 4px; }}
  .subtitle {{ text-align: center; color: #8a969e; margin-bottom: 36px; }}
  .grid {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(260px, 1fr)); gap: 16px; max-width: 1100px; margin: 0 auto; }}
  .card {{ background: #1e252b; border: 1px solid #2c363d; border-radius: 12px; padding: 18px 20px; }}
  .label {{ color: #8a969e; font-size: 12px; text-transform: uppercase; letter-spacing: 0.06em; margin-bottom: 6px; }}
  .value {{ font-size: 26px; font-weight: 700; color: #d9c48f; margin-bottom: 8px; }}
  .sub {{ color: #b7c0c6; font-size: 13px; line-height: 1.4; }}
  .hb {{ display: flex; gap: 10px; align-items: baseline; }}
  .cards {{ font-weight: 600; color: #eef1f3; }}
  .board {{ color: #8a969e; }}
  .date {{ color: #5f6b72; font-size: 12px; margin-left: auto; }}
  footer {{ text-align: center; color: #5f6b72; font-size: 12px; margin-top: 36px; }}
</style></head>
<body>
  <h1>&#9827; CoinPoker Year in Review &#9830;</h1>
  <div class="subtitle">{n:,} hands &middot; {date_lo:%b %d} &ndash; {date_hi:%b %d, %Y}</div>
  <div class="grid">{cards_html}</div>
  <footer>Generated by year_in_review.py &middot; regenerate with <code>python3 year_in_review.py</code></footer>
</body></html>"""
    with open(OUT, "w", encoding="utf-8") as f:
        f.write(html)
    print(f"wrote {OUT}")
    print(f"biggest win ${float(biggest_win['net']):+.2f} | biggest loss ${float(biggest_loss['net']):+.2f}")
    print(f"nemesis hand {nemesis[0]} (${sum(nemesis[1]):+.2f}/{len(nemesis[1])}) | best hand {best_hand[0]} (${sum(best_hand[1]):+.2f}/{len(best_hand[1])})")
    if luckiest:
        print(f"luckiest river {luckiest[0]:+.2f} | unluckiest river {unluckiest[0]:+.2f}")


if __name__ == "__main__":
    main()
