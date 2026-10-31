#!/usr/bin/env python3
"""Build leak_trainer.html: a spaced-repetition-style flashcard drill built entirely from
Hero's OWN flagged leak spots (coinpoker_missed_ops.csv, joined to coinpoker_features.csv for the
showdown outcome). Not solver spots, not generic theory - your own specific missed bets, replayed
blind. ToS-safe: pure "study away from the felt" on your own hand history, no live capture, no
opponent profiling. Excludes the `small_value_river` type (that's a sizing issue - Hero DID bet - so
the bet/check quiz mechanic doesn't fit it; those 27 spots are better reviewed in the dashboard's
"Missed opportunities" table).
Run: python3 build_leak_trainer.py
"""
import csv
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
MO = os.path.join(HERE, "coinpoker_missed_ops.csv")
FEAT = os.path.join(HERE, "coinpoker_features.csv")
OUT = os.path.join(HERE, "leak_trainer.html")

TYPE_LABEL = {
    "missed_value_strong": "Missed value (strong made hand)",
    "missed_value_thin": "Missed value (thin one pair)",
    "turn_monster_checked": "Slow-played a set+ on the turn",
    "missed_bluff_busted": "Gave up a busted draw",
    "missed_bluff_air": "Gave up air with fold equity",
}
CORRECT_ACTION = {  # what the detector says you should have done
    "missed_value_strong": "bet", "missed_value_thin": "bet", "turn_monster_checked": "bet",
    "missed_bluff_busted": "bet", "missed_bluff_air": "bet",
}


def isna(v):
    return v in ("NA", "", None)


def main():
    with open(MO, newline="", encoding="utf-8") as f:
        mo = [r for r in csv.DictReader(f) if r["type"] in TYPE_LABEL]
    with open(FEAT, newline="", encoding="utf-8") as f:
        feat = {r["id"]: r for r in csv.DictReader(f)}

    cards = []
    for r in mo:
        fr = feat.get(r["hand_id"], {})
        net = fr.get("net")
        cards.append(dict(
            id=r["hand_id"], dt=r["dt"], hero=r["hero_cards"],
            flop=r["flop"], turn=r["turn_card"], river=r["river_card"],
            street=r["street"], line=r["line"], potype=r["potype"],
            type=r["type"], label=TYPE_LABEL[r["type"]],
            est_ev=round(float(r["est_ev"]), 1), fold_eq=r["fold_eq"], pot=round(float(r["pot"]), 1),
            net=round(float(net), 1) if net not in (None, "NA", "") else None,
            sd_cat=fr.get("sd_cat") if not isna(fr.get("sd_cat")) else None,
            villain_cat=fr.get("villain_cat") if not isna(fr.get("villain_cat")) else None,
            villain_cards=fr.get("villain_cards") if not isna(fr.get("villain_cards")) else None,
        ))

    data_json = json.dumps(cards)
    type_options = "".join(
        f'<label><input type="checkbox" class="tf" value="{k}" checked> {v} ({sum(1 for c in cards if c["type"]==k)})</label>'
        for k, v in TYPE_LABEL.items()
    )

    html = """<!doctype html>
<html><head><meta charset="utf-8"><title>Leak Trainer</title>
<style>
  :root { --bg:#14181c; --panel:#1e252b; --border:#2c363d; --ink:#eef1f3; --muted:#8a969e;
          --gold:#d9c48f; --green:#1f4e79; --red:#a8432f; }
  body { background: var(--bg); color: var(--ink); font-family: -apple-system,"Segoe UI",Helvetica,Arial,sans-serif;
         margin:0; padding: 30px 16px 60px; }
  h1 { text-align:center; margin-bottom:4px; font-size:24px; }
  .sub { text-align:center; color:var(--muted); margin-bottom:22px; font-size:13px; }
  #setup { max-width:520px; margin:0 auto 24px; background:var(--panel); border:1px solid var(--border);
           border-radius:12px; padding:18px 20px; }
  #setup label { display:block; font-size:13px; margin:6px 0; color:var(--ink); }
  #setup .row { display:flex; justify-content:center; gap:12px; margin-top:14px; }
  button { background: var(--gold); border:none; border-radius:8px; padding:10px 18px; font-size:14px;
           font-weight:600; cursor:pointer; color:#14181c; }
  button.secondary { background:transparent; border:1px solid var(--border); color:var(--ink); }
  button:disabled { opacity:0.4; cursor:default; }
  #deck { max-width:560px; margin:0 auto; display:none; }
  .progress { text-align:center; color:var(--muted); font-size:12px; margin-bottom:10px; }
  .score { text-align:center; color:var(--gold); font-size:13px; margin-bottom:16px; }
  .card { background:var(--panel); border:1px solid var(--border); border-radius:14px; padding:24px; text-align:center; }
  .meta { color:var(--muted); font-size:12px; margin-bottom:14px; }
  .cards-row { font-size:30px; letter-spacing:4px; margin:10px 0; }
  .board-row { font-size:24px; letter-spacing:6px; color:var(--muted); margin:10px 0 18px; }
  .suit-h, .suit-d { color: var(--red); } .suit-s, .suit-c { color: var(--ink); }
  .line-info { font-size:13px; color:var(--muted); margin-bottom:20px; }
  .answer-row { display:flex; gap:14px; justify-content:center; margin:18px 0 8px; }
  .answer-row button { flex:1; max-width:160px; padding:14px; font-size:16px; }
  #reveal { display:none; text-align:left; margin-top:18px; padding-top:18px; border-top:1px dashed var(--border); }
  #reveal .verdict { font-size:15px; font-weight:700; margin-bottom:8px; }
  #reveal .verdict.agree { color: var(--green); } #reveal .verdict.disagree { color: var(--red); }
  #reveal p { font-size:13px; color:var(--ink); line-height:1.5; margin:4px 0; }
  #reveal .outcome { color:var(--muted); }
  .next-row { margin-top:18px; }
  footer { text-align:center; color:#5f6b72; font-size:11px; margin-top:30px; }
</style></head>
<body>
  <h1>&#9827; Leak Trainer &#9830;</h1>
  <div class="sub">Your own flagged spots, replayed blind. Bet or check &mdash; then see what actually happened.</div>

  <div id="setup">
    __TYPE_OPTIONS__
    <div class="row">
      <button id="start">Start drill</button>
    </div>
    <div id="best" style="text-align:center;color:#8a969e;font-size:12px;margin-top:10px;"></div>
  </div>

  <div id="deck">
    <div class="progress" id="progress"></div>
    <div class="score" id="scoreline"></div>
    <div class="card">
      <div class="meta" id="meta"></div>
      <div class="cards-row" id="herocards"></div>
      <div class="board-row" id="boardcards"></div>
      <div class="line-info" id="lineinfo"></div>
      <div class="answer-row" id="answers">
        <button id="betBtn">Bet</button>
        <button id="checkBtn">Check</button>
      </div>
      <div id="reveal">
        <div class="verdict" id="verdict"></div>
        <p id="detail"></p>
        <p class="outcome" id="outcome"></p>
      </div>
      <div class="next-row">
        <button class="secondary" id="nextBtn" style="display:none;">Next card &rarr;</button>
      </div>
    </div>
  </div>

  <footer>Built from coinpoker_missed_ops.csv + coinpoker_features.csv &middot; regenerate with <code>python3 build_leak_trainer.py</code></footer>

<script>
const CARDS = __DATA_JSON__;
const SUIT = {s:"&spades;", h:"&hearts;", d:"&diams;", c:"&clubs;"};
function cardHtml(c) {
  if (!c) return "";
  const r = c[0], s = c[1];
  return `<span class="suit-${s}">${r}${SUIT[s]}</span>`;
}
function cardsHtml(str) {
  if (!str) return "";
  return str.trim().split(" ").map(cardHtml).join(" ");
}
function money(x) { return (x < 0 ? "-$" : "+$") + Math.abs(x).toFixed(2); }

let deck = [], idx = 0, correct = 0, answered = 0;

function loadBest() {
  const hist = JSON.parse(localStorage.getItem("leakTrainerHistory") || "[]");
  if (hist.length) {
    const last = hist[hist.length - 1];
    document.getElementById("best").textContent =
      `Last run: ${last.pct}% agreed with the detector (${last.correct}/${last.total}) across ${hist.length} run(s)`;
  }
}
loadBest();

document.getElementById("start").addEventListener("click", () => {
  const active = Array.from(document.querySelectorAll(".tf:checked")).map(cb => cb.value);
  deck = CARDS.filter(c => active.includes(c.type));
  for (let i = deck.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [deck[i], deck[j]] = [deck[j], deck[i]];
  }
  if (!deck.length) { alert("Pick at least one leak type."); return; }
  idx = 0; correct = 0; answered = 0;
  document.getElementById("setup").style.display = "none";
  document.getElementById("deck").style.display = "block";
  showCard();
});

function showCard() {
  const c = deck[idx];
  document.getElementById("progress").textContent = `Card ${idx + 1} / ${deck.length}`;
  document.getElementById("scoreline").textContent = answered
    ? `Agreed with the detector on ${correct}/${answered} so far (${Math.round(100 * correct / answered)}%)`
    : "";
  document.getElementById("meta").textContent =
    `${c.potype} pot · ${c.street} · line "${c.line}" · ${c.dt.slice(0, 10)}`;
  document.getElementById("herocards").innerHTML = cardsHtml(c.hero);
  const board = [c.flop, c.turn, c.river].filter(Boolean).join(" ");
  document.getElementById("boardcards").innerHTML = cardsHtml(board);
  document.getElementById("lineinfo").textContent =
    "You're on this board with a bet available. What do you do?";
  document.getElementById("reveal").style.display = "none";
  document.getElementById("nextBtn").style.display = "none";
  document.getElementById("answers").querySelectorAll("button").forEach(b => b.disabled = false);
}

function answer(choice) {
  const c = deck[idx];
  answered++;
  const agree = choice === "bet";
  if (agree) correct++;
  document.getElementById("answers").querySelectorAll("button").forEach(b => b.disabled = true);
  const v = document.getElementById("verdict");
  v.className = "verdict " + (agree ? "agree" : "disagree");
  v.textContent = agree
    ? "You bet. That matches what the detector flags as the leak fix here."
    : "You checked. That's what actually happened here too — same leak.";
  document.getElementById("detail").innerHTML =
    `<b>${c.label}</b> &middot; est. value left on the table: <b>${money(c.est_ev)}</b>` +
    (c.fold_eq ? ` &middot; est. fold equity ${Math.round(c.fold_eq * 100)}%` : "");
  let outcome = `You actually checked here. `;
  if (c.net !== null) {
    outcome += `Hand result: ${money(c.net)}.`;
    if (c.sd_cat) outcome += ` You showed down ${c.sd_cat}.`;
    if (c.villain_cat) outcome += ` Villain showed ${c.villain_cat}${c.villain_cards ? " (" + c.villain_cards.replace(" ", " ") + ")" : ""}.`;
  }
  document.getElementById("outcome").textContent = outcome;
  document.getElementById("reveal").style.display = "block";
  document.getElementById("nextBtn").style.display = "inline-block";
  document.getElementById("scoreline").textContent =
    `Agreed with the detector on ${correct}/${answered} so far (${Math.round(100 * correct / answered)}%)`;
}

document.getElementById("betBtn").addEventListener("click", () => answer("bet"));
document.getElementById("checkBtn").addEventListener("click", () => answer("check"));
document.getElementById("nextBtn").addEventListener("click", () => {
  idx++;
  if (idx >= deck.length) {
    const pct = Math.round(100 * correct / answered);
    const hist = JSON.parse(localStorage.getItem("leakTrainerHistory") || "[]");
    hist.push({ date: new Date().toISOString().slice(0, 10), correct, total: answered, pct });
    localStorage.setItem("leakTrainerHistory", JSON.stringify(hist));
    document.getElementById("deck").innerHTML =
      `<div class="card"><div class="verdict agree">Deck complete!</div>` +
      `<p>You bet in ${correct}/${answered} flagged spots (${pct}%). ` +
      `These are all real hands where you actually checked — a higher number here means you'd fix ` +
      `more of your own historical leak today than you did at the time.</p>` +
      `<div class="row" style="margin-top:16px;"><button onclick="location.reload()">Run again</button></div></div>`;
    return;
  }
  showCard();
});
</script>
</body></html>"""
    html = html.replace("__TYPE_OPTIONS__", type_options).replace("__DATA_JSON__", data_json)
    with open(OUT, "w", encoding="utf-8") as f:
        f.write(html)
    print(f"wrote {OUT} ({len(cards)} cards)")


if __name__ == "__main__":
    main()
