# CoinPoker analysis — data dictionary & definitions

Purpose: pin down every **custom** term we use, what it is computed from, what it is *meant* to
capture, and where it can mislead. Standard poker/stats terms used in their ordinary sense
(preflop raise, big blind, fold, mean) are **not** listed. The entries below are the ones where we
made a modelling choice — those are the ones that can quietly bake in a false assumption.

Honesty rules this doc follows:
- If a definition is a **choice** (a threshold, a heuristic, a proxy), it says so.
- "Captures" = the strategic thing we *want* it to mean. "Limits / confounders" = why it may not.
- A leak label is a **hypothesis** (aggregate −EV association), never a proven cause of a given loss.

Source of truth for the code: `parse_coinpoker.R` (raw → `coinpoker_hands.csv`),
`features_coinpoker.R` (derived cols → `coinpoker_features.csv`), `coinpoker_dashboard.Rmd` (analysis).

---

## 1. Results & money

| Term | Defined as | Captures | Limits / confounders / relationships |
|---|---|---|---|
| `net` | `collected + uncalled RETURN − (ante + Σ per-street committed) + cashout_to_hero` | Hero's chips won/lost in the hand | Relies on parsing **every** action correctly. Validated vs next-hand stack delta: 49.5% exact, ~75% = net + non-negative top-up; the rest are table-hopping/cash-out **stack resets** (median \|net\| 0.08), not errors. Cashout credit is partial (see §6). |
| `net_bb` | `net / bb` | Stake-normalized result | A big blind at 50NL is not skill-equivalent to one at 10NL; pooling stakes in bb assumes it is. |
| **bb/100 (overall)** | `Σ net_bb / hands × 100` | Win rate | High variance (per-hand SD ~80–100 bb/100). At our sample, every stake's 95% CI still straddles 0. |
| **bb/100 (per bucket)** | same formula on a **subset** | Relative comparison *within* a cut | **NOT comparable to the overall rate.** Buckets selected by outcome are inflated by construction (e.g. "won preflop", "saw a flop"). Read across buckets, not against the headline. |
| `fees` (`hero_rake`+`hero_splash`) | whole-pot Rake+Splash × `fee_share`, `fee_share = invested/pot` | Hero's contributed fees / rakeback basis | Contribution-weighting is an assumption (the standard one). Whole-pot rake would overstate ~5–6×. Splash Fee is a house drop alongside rake; `collected` is already post-fee so fees don't change `net`. |
| `is_cashout` | `pot − rake − splash − Σ(all collected) > 0.02` | Hand used the all-in equity cashout | The cashed equity leaves the pot but is **not** written as a `collected` line, so the pot fails to reconcile — that shortfall = the cashout. |
| `cashout_to_hero` | `pot_unaccounted`, credited **only** if single-board, Hero never folded, Hero collected 0, exactly one villain collected | Hero's cashed equity (added back to `net`) | **Conservative on purpose.** Multiway/ambiguous cashouts are flagged but **not** credited, so Hero's net is still very slightly understated. We cannot detect a hidden equity-% *haircut* (would need an equity calc on known all-ins); gross accounting shows **no** extra fee. |

## 2. Preflop (denominators matter)

| Term | Defined as | Captures | Limits / confounders |
|---|---|---|---|
| `vpip` | Hero voluntarily put chips in preflop (call/raise), **excluding** forced blinds/antes | Entry frequency | BombPots excluded (forced action). A blind that checks its option is not VPIP. |
| `pfr` | Hero raised preflop | Preflop aggression | — (standard) |
| `rfi_opp` | Hero is first voluntary actor with **0** prior raises (pot unopened) | "Could I open/steal?" denominator | — |
| `open_raise` / open% | raised when `rfi_opp`; open% = `open_raise / rfi_opp` | Steal/open frequency | — |
| `vsopen_opp` | Hero faces **exactly one** prior raise | "Could I 3-bet/flat?" denominator | A second raise before Hero (a 3-bet) is excluded — this is strictly the single-raise spot. |
| `three_bet` / **3-bet%** | raised facing one raise; **3-bet% = `three_bet / vsopen_opp`** | 3-bet frequency | **Denominator is faced-an-open, not all hands.** Comparing this 3-bet% to a "% of all hands" stat elsewhere would be wrong. |
| `ftb_opp`/`fold_to_3bet` | Hero opened, then faced a re-raise | Fold-to-3-bet | Small samples; stabilizes slowly. |
| `vsopen_pos` | seat of the **first** raiser Hero faced | Who you're 3-betting/flatting into | Only the first raiser; squeeze/multi-raise structure simplified. |
| `tb_to_bb` / `tb_ratio` | Hero 3-bet size in bb / as a multiple of the open | 3-bet sizing | `tb_ratio` NA if the open size didn't parse; ignores stack depth and antes (which change ideal sizing). |

## 3. Range model — the most assumption-heavy block (all custom)

| Term | Defined as | Captures | Limits / confounders |
|---|---|---|---|
| `hand169` | canonical class, e.g. `AKs`,`AKo`,`77` | Hand identity ignoring exact suits | — |
| `chen` score | Chen formula **+ a custom +2 set-mining bump for pairs** | Static preflop hand strength | Chen is a heuristic: it **underrates** suited connectors/suited aces; the +2 pair bump is **our** adjustment, not standard. Ignores stack depth, rake, and opponents entirely. |
| `hand_rank_pct` | percentile of `chen` over all 169 hands | Where a hand ranks | Ties share averaged rank. |
| `POS_OPEN` / `pos_open_pct` | per-seat opening **width** (editable vector; UTG .15 → BTN .46, blinds wide) | How wide a seat "should" play | A **single number per seat**, hand-set by us (not solver-derived). Blinds get a wide "defend" allowance so an RFI chart doesn't over-flag them. |
| `in_open_range` | `hand_rank_pct ≤ pos_open_pct` | Is this a baseline-playable hand here | **Positional OPEN baseline only.** Does **not** model facing-action: open vs flat-vs-raise vs 3-bet vs blind-defend are different ranges. So an "in-range" hand can be a correct *fold* facing a raise, and an "out-of-range" hand can be a correct *call/3-bet*. |
| `range_dir = loose` | `vpip & !in_open_range` | Played a hand outside the seat's open baseline (what inflates VPIP) | "Loose" = **outside the positional OPEN baseline**, NOT "definitely a mistake." Some loose tags are legitimate calls/3-bets the model doesn't know about (facing-action not modelled). Directional, not a verdict. |
| `range_dir = passed` | `folded & rfi_opp & in_open_range` | Folded an openable hand first-in (skipped steal / too tight) | Cleanest "too tight" signal because `rfi_opp` = unopened pot. Could still be a correct fold vs a specific read, but in an unopened pot that's rare. |
| `range_dir = in` / `NA` | in-range voluntary / (folded out-of-range or a facing-action fold we don't judge) | Standard play / not judged | NA hands are deliberately **not** scored — don't read NA as "fine". |

## 4. Postflop

| Term | Defined as | Captures | Limits / confounders |
|---|---|---|---|
| `saw_flop` | flop occurred **and** Hero didn't fold preflop | Hero actually reached the flop | Hero-specific (not just "a flop came"). |
| `cbet_opp`/`cbet_flop` | Hero was preflop aggressor & first c-bet chance; bet = cbet | C-bet frequency | First-action heuristic; multiway c-bet spots are noisier. |
| `fcbet_opp`/`fold_to_cbet` | Hero faced a c-bet; folded | Fold-to-c-bet | Small per-position samples. |
| Postflop **AF** | `pf_aggr / pf_calls` = (postflop bets+raises) / (postflop calls) | Aggression factor | A ratio; a few calls in the denominator swing it. |
| `n_flop` | distinct players who **acted** on the flop (2=HU, 3+=MW) | Heads-up vs multiway | Players who folded before acting aren't counted. |
| `hero_first_flop` | Hero acts first on the flop ⇒ OOP | In/out of position | **Exact heads-up; a proxy multiway** (first-to-act ≈ OOP but isn't always the worst seat). |
| `flop_call`/`turn_call`/`river_call` (+`*_pot`) | $ Hero called facing a bet that street; `*_pot` = pot just before that call | Calling volume + pot-relative size | Sizing buckets (≤⅓, ½, full, overbet) come from `call/(pot−call)`. |

## 5. Showdown

| Term | Defined as | Captures | Limits / confounders |
|---|---|---|---|
| `showdown` | Hero's SUMMARY line contains " with <Rank>" | A **real** showdown | Uncalled wins print "won (X)" only and are correctly excluded. |
| `sd_cat` | Hero's made-hand rank at showdown | What you showed down | Showdown hands only. |
| `villain_cat`/`villain_cards` | **strongest** hand any *other* player tabled | "What beats you" | **Selection bias**: only observed when a villain shows — which skews toward hands you lost/called. NOT a random sample of villain holdings; don't read it as their range. |
| WTSD / W$SD | went to showdown given saw flop / won $ at showdown | Showdown frequency / success | Denominators differ; small-day samples noisy. |

## 6. Draws & board reconstruction (single-board hands only)

| Term | Defined as | Captures | Limits / confounders |
|---|---|---|---|
| `has_flush`/`has_straight` | Hero uses ≥1 hole card in a made 5-card flush/straight on the board | Made flush/straight | Doesn't enumerate full 7-card best hand for pairs/trips. |
| `draw_here` | 4-flush or 4-straight (gutshot **or** open-ended) using a hole card | On a draw | **Gutshot weighted same as OESD**; ignores backdoors, overcards, combo draws — so draw strength is flattened. |
| `on_draw` | `draw_here` on flop or turn AND not already made on the flop | Was drawing | Single-board only (run-it-twice → excluded). |
| `hit` | made a flush/straight by the river | Draw got there | Only flush/straight count as "hit" — a draw that **pairs** and wins isn't flagged hit. |
| **busted-draw river bet** (dashboard "are you bluffing more?") | `hero_river_bet > 0 & on_draw & !hit` | Bet the river with a busted draw — **counts whether called or folded** | **Lower bound on bluffing.** Excludes pure-air bluffs (no draw); a *successful* bluff shows as "won, no showdown" so shown-down counts undercount badly. NB: distinct from the stored `river_bluff` column (§6b = *any* no-made-hand river bet); this is the draw-specific subset. |

## 6b. Postflop hand-strength engine (`features_coinpoker.R`, stored columns)

We parse all 7 cards but historically never *evaluated* them postflop. This engine does, as stored
per-hand columns (computed for every hand that saw a flop). It supersedes the crude inline `made_str`.

| Column | Defined as | Captures | Limits / confounders |
|---|---|---|---|
| `made_flop` / `made_turn` / `made_river` | integer 0–8 = Hero's best 5-card category (0 air, 1 pair, 2 two-pair, 3 trips, 4 straight, 5 flush, 6 full house, 7 quads, 8 str-flush) **that uses ≥1 hole card** | Hero's actual made hand at each street | The hole-card requirement is deliberate: a paired/flushed **board** Hero doesn't share scores 0, not "one pair." Validated **100% exact vs `sd_cat`** on 331 showdowns. |
| `fl_fd`,`fl_sdraw`,`fl_overs` (and `tn_*`) | flush-draw flag; straight-draw `oesd`(≥2 completing ranks)/`gut`(1)/`none`; live overcards (hole ranks above top board card) | What a non-made hand draws to | `oesd` lumps true open-enders with double-gutters; overcards counted only when unpaired. |
| `*_betpot` | Hero's bet ÷ pot at that street | Bet sizing | NA unless Hero bet that street. |
| `flop_bluff`/`turn_bluff`/`river_bluff` | Hero bet that street **with `made_*==0`** (no pair+ using a hole card) | A genuine no-made-hand bet | This is the bluff **primitive** (broader than the §6 busted-draw view, which is the draw-specific subset shown in the "are you bluffing more?" table). |
| `*_backing` | for a bluff bet: `combo/flush/open-ender/gutshot/two-overcards/one-overcard/air` (river: `ace/over-high` vs `air`) | What equity is behind the bluff | Decomposition only defined when the bet is a bluff (else NA). |
| `on_draw` / `hit_draw` | engine versions of §6 `on_draw`/`hit` (draw on flop/turn not already made; reached flush/straight by river) | Was drawing / got there | Now **stored** (was inline). Same single-board limit. |
| `vagg_before_turn` / `vagg_before_river` | proxy: Hero faced/called a villain bet on an earlier street | Villain showed prior-street aggression | A *proxy* — Hero calling a bet implies a villain bet; misses checks-behind lines and Hero-folds. |

## 7. Benchmarks & bands (chosen targets, not laws)

| Term | Defined as | Limits / confounders |
|---|---|---|
| Reg ranges (VPIP 22–27, PFR 18–22, 3-bet 7–12, C-bet 50–65, F2cb 40–55, AF 2–3.5, WTSD 24–28) | "A winning 6-max reg" ballpark, **set by us**, editable in `progress-calc` | Not from a specific solver/DB; **one band across all stakes** (micros legitimately play looser). Targets, not truth. |
| `vpip_ideal` (positional) | rough per-seat VPIP targets for the trend bars | Hand-set; blinds intentionally broad. |
| Day snapshot | one row per calendar day, days **<50 hands dropped** | A "day" mixes stakes/tables; single-day postflop rates are noisy → out-of-band **warnings restricted to preflop stats** (VPIP/PFR/3-bet). |

## 8. Leak terms (inputs to the leak ledger)

A **leak** here = a per-hand condition we've *associated* with −EV from aggregate P&L. Each is a
**hypothesis**, not a proven cause of any single loss. Definitions:

All are now **stored columns** in `features_coinpoker.R` (`lk_*` booleans) plus a `primary_leak`:

| Leak column | Per-hand condition | Known confounder |
|---|---|---|
| `lk_loose_entry` | `range_dir == "loose"` | facing-action not modelled (§3) |
| `lk_skipped_steal` | `range_dir == "passed"` | could be a correct fold vs a read; **opportunity cost (folds), not a realized loss** → excluded from the attribution waterfall |
| `lk_light_3bet` | `three_bet & !in_open_range & vsopen_pos ∈ {EP2,EP,UTG,MP,HJ}` (genuinely light 3-bet vs an *early* opener) | **CORRECTED 2026-06-21** (review). Old def `three_bet & vsopen_pos ∈ {UTG,CO}` tagged every 3-bet there (112/120 in-range, 29 premiums) and falsely topped the loss story; CO opens ~27% (not tight). Corrected set ≈14 hands, **net positive → not a leak**, so **excluded from both ledger views and from `primary_leak`** (kept as a column for reference only). |
| `lk_paid_river` | `river_call > 0 & sd_cat ∈ {One Pair, High Card}` | sometimes a correct bluff-catch |
| `lk_busted_sd` | `showdown & on_draw & !hit_draw & sd_cat ∈ {One Pair, High Card}` | single-board only |
| `lk_loose_passive` | `range_dir=="loose" & saw_flop & !hero_first_flop & no Hero bet` | **FIXED 2026-06-21** (review): added `saw_flop` — `hero_first_flop` is NA with no flop, and `!NA`-as-FALSE wrongly tagged 122/179 no-flop hands as "IP passive". IP/OOP is a first-to-act proxy, noisy multiway. |
| `lk_air_bet` | `flop_bluff | turn_bluff | river_bluff` (bet near-air postflop) | not a clean *realized-loss* leak (semibluffs win too) → independent view only, not in the waterfall |

`primary_leak` (char, set only on **losing** hands): each loss assigned its single most-proximal leak by
priority `paid_river > busted_sd > loose_passive > loose_entry`. `NA` when a loss carries no named leak
(= unattributed variance).

**Double-counting (now implemented).** One hand can carry several `lk_*` tags, so the ledger shows two
views: **(1) independent** (each leak summed alone; overlapping, does **not** sum to net) and **(2)
attribution** (`primary_leak`, one dominant leak per losing hand, sums cleanly). The attribution view
covers only a *minority* of losing-hand dollars; the rest is unnamed variance — never present either view
as if it explains the whole result. `lk_skipped_steal`, `lk_air_bet`, and `lk_light_3bet` are **not** in
the attribution waterfall.

## 9. Value attribution — Tier 1 (`coinpoker_decisions.csv`, built by `build_decisions()`)

**Result** attribution (the leak ledger, §8) sorts hands by how they *finished*. **Value** attribution asks
whether a decision was correctly priced *when made*, using only the price and Hero's equity — no villain
read. One row per scoreable decision; `split` carries the train/test tag. We store **theoretical** quantities
only (never the realized net split across a hand's decisions — that's the result-attribution trap), plus the
hand's `hit`/`net` so the dashboard can *calibrate* the theory against outcomes.

| Decision | Column | Defined as |
|---|---|---|
| `draw_call` (flop→turn 47 unseen, turn→river 46) | `equity` | one-card equity `outs / unseen`; outs from `draw_outs()` (flush 9, OESD 8, gutshot 4, combo −2 shared) |
| | `req_equity` | immediate breakeven `C / (P + C)` — `C`=call, `P`=pot before the call (`*_call_pot`) |
| | `ev` | forward immediate EV `(equity − req_equity)·(P + C)` (win +P, lose −C) |
| | `good` | `equity ≥ req_equity` — "**priced now**", needs no implied odds |
| | `req_implied` | extra $ to win when you hit, to break even: `X = (1−e)·C/e − P` (negative ⇒ already priced) |
| | `req_implied_x` | `req_implied / C` — the implied-odds bar **as a multiple of the call** |
| | `hit`, `net` | did the draw reach a straight+ by the river (`hit_draw`); whole-hand `net` (for calibration only — *not* forward-isolated) |
| `bluff_bet` / `semibluff_bet` | `breakeven_fold` | fold % needed to profit: `(b − e·(P+2b)) / (P + b − e·(P+2b))`; `= b/(P+b)` for pure air, **lower** for a semibluff (its equity `e` when called) |

**Why no rule-of-2/rule-of-4 bracket.** An earlier plan was to bracket a draw call between one-card and
two-card odds. Rejected: rule-of-4 is **not** an upper bound on a draw's EV — implied odds sit *above* it,
so "−EV at rule-of-4" wouldn't mean "mistake." The assumption-free quantity is the **implied-odds breakeven**
(`req_implied_x`), which we then check against realized hit-rate and extraction. `req_implied_x` is
**conservative**: it ignores free-river equity and busted-draw fold equity, both of which only lower the real
bar. Likewise `breakeven_fold` for semibluffs ignores later-street barreling — the real bar is lower still.
Made-hand river bluff-catches need a villain range → deferred to Tier 3.

## 10. Luck ledger (`coinpoker_luck_ledger.csv`, built by `luck_ledger.py`)

Decomposes a window's **actual net** into three distinct, non-circular luck components plus a
residual. Reuses the shared evaluator in `poker_eval.py` (also used by `allin_ev.py`). Standalone —
not run automatically by `render_coinpoker.R` (takes ~1-3 min); run `python3 luck_ledger.py`
to refresh. The window is the deepest drawdown in cumulative net, from its peak to its trough, found
from the data; `--window-start` and `--window-end` override it.

| Component | Defined as | Notes / caveats |
|---|---|---|
| `card_luck` | `(mean equity-vs-random in window − mean equity-vs-random overall) × slope × n_hands`. Equity-vs-random is the raw hot/cold win% of a hand169 class against one random opponent hand with no board (`poker_eval.equity_vs_random`), computed once per class (169-class symmetry — suits don't matter) and cached. `slope` = the empirical $/equity-point from an OLS regression of `net` on dealt equity across the **entire** sample (own data, not assumed) | Comparing window-mean to overall-mean (not to a fixed 50%) cancels Monte-Carlo estimation noise between the two, since both use the same per-class cache. Near-zero means "you were dealt a normal mix of cards" — a real, checkable answer to "were the cards just bad." |
| `allin_luck` | Same logic as `allin_ev.py`: equity at a clean HU all-in with cards to come, vs actual collected, summed over the window | Excludes multiway/uncalled all-ins (same scope as `allin_ev.py`). |
| `river_card_luck` | For clean HU showdowns (`n_flop==2`) that were **not** already in the all-in set: exact equity right before the river card falls (board = flop+turn) vs the actual showdown result, monetized against the final pot (`pot − rake − splash_fee`) | **Approximation, flagged not hidden**: uses the *final* pot as "money at risk to that card," though some of that pot arrived via river betting made *after* the card was already public. Treat as directional, not exact accounting. |
| `residual` | `actual_net − (card_luck + allin_luck + river_card_luck)` | NOT "skill" by itself — everything the other three don't capture: bet-sizing, fold/call decisions, unmodeled variance (e.g. flop/turn-only pots that never reach a clean HU showdown). |

Both `window="downswing"` (inside the window) and `window="baseline"` (outside it) rows are written, so the
dashboard can show the downswing stretch in the context of what came before. This is a **different cut**
from the leak ledger (§8) — the leak ledger attributes *named leak* dollars within losing hands; the luck
ledger attributes *all* window dollars (won and lost hands) to luck-vs-residual. They can disagree on
"how much is leak/skill" and that's expected — they're answering different questions.

## 11. Downswing simulator (`downswing_sim.R` — three CSVs)

Wired into `render_coinpoker.R` (fast, ~2s). Three independent questions on the same per-hand
`net_bb` series (bomb pots excluded), all in `bb/100` unless noted:

| Artifact | Method | What it answers |
|---|---|---|
| `coinpoker_downswing_sim.csv` + `coinpoker_bootstrap_dd.csv` | Resample `net_bb` i.i.d. (with replacement) into 5,000 simulated careers of the **same length** as the real sample; compute each replicate's max peak-to-trough drawdown (in bb); compare to the actual observed drawdown | "Is a swing this size surprising for a player with my exact hand-level return distribution?" i.i.d. resampling is justified by the session-log finding of no tilt/autocorrelation signature (own hands are close to exchangeable). |
| `coinpoker_winrate_posterior.csv` | Normal-normal conjugate: prior `mu ~ N(0, tau0^2)` with **tau0 = 8 bb/100** (a stated, skeptical prior — regulars mostly live in roughly that band), likelihood = sample mean/SE per stake and overall. Reports posterior mean, 95% credible interval, and `P(true winrate > 0)`. A sensitivity check under a much wider prior (tau0=50) is printed to console (not in the CSV) so the conclusion is visibly prior-dependent, not asserted as prior-free. | "How sure are we this is/isn't a winning player/stake, given how little data we have?" — the honest, uncertainty-carrying version of a plain average. |
| `coinpoker_risk_of_ruin.csv` | Classic drift-diffusion approximation `RoR = exp(-2*mu*bankroll_bb / sigma^2)` (mu ≤ 0 ⇒ RoR = 1), swept over bankroll size (in 100bb buy-ins) at three `mu`: the posterior mean and its 95% CI bounds | Bankroll-sizing consequence of the winrate uncertainty above — one clean answer instead of picking a single point estimate and pretending it's certain. |

**Caveats (stated, not hidden):** the ruin formula is a continuous-time approximation (ignores table
limits, rebuys, and a finite playing horizon) and treats `sigma` as fixed at its overall estimate. The
bootstrap and posterior both assume hands are exchangeable within the resampled window — true across
the whole sample per the session-log analysis, but a real regime change (moving up in stakes, a big
strategy shift) would violate it and isn't detected here.

## 12. RNG fairness audit (`rng_audit.R` -> `coinpoker_rng_audit.csv`)

Different question from §3's "Card luck" (which asks whether the user ran good/bad on premium
hands vs their fixed combinatorial rate). This asks whether **CoinPoker's shuffle itself** looks
uniform: chi-square goodness-of-fit on rank (13-way), suit (4-way), and specific card (52-way)
frequency, separately for hole cards and (single-board) community cards, plus binomial tests on the
pocket-pair rate (expect 3/51) and suited rate (expect 12/51). Wired into `render_coinpoker.R`
(<1s). **Multiple-comparisons note, stated in the report itself:** with ~8 tests at alpha=0.05,
~0.4 "significant" hits are expected from a perfectly fair deck by chance alone — a single low
p-value is not evidence of bias, only a majority of tests clearing the bar would be.

## 13. Counterfactual replay (`counterfactual_replay.R` -> 2 CSVs)

Re-runs the actual hand history under four mechanical policies. Wired into `render_coinpoker.R`.

| Policy | Mechanism | Validity |
|---|---|---|
| A: fold loose SB hands | Any SB hand with `range_dir=="loose"` gets `net` replaced by `-(ante) - sb` (the blind Hero would still post) instead of the real result | Clean counterfactual — independent per-hand substitution, no lookahead. Inherits `range_dir`'s caveat (§3): "loose" isn't a verdict, facing-action isn't modeled. |
| B: fold all loose hands | Same substitution, any position (BB uses `-bb` instead of `-sb`; non-blind seats use `0`) | Same validity note as A. |
| C: session hand-cap | Sessionized the same way as `session_analysis.R` (>30-min gap); any hand past the `HAND_CAP`th (default 150) in its session gets `net` replaced by `0` | Arithmetically exact for "what if I'd logged off there" (an unplayed hand nets exactly $0). NOT a proven real-time rule — hindsight replay on sessions whose outcome is already known. |
| D: stop-loss | Within each session, once the running cumulative `net` first drops below `-STOP_LOSS_BI` (default 3) buy-ins (`100 * bb`), every hand from the *next* one onward in that session is zeroed | Same hindsight caveat as C. The hand that crosses the threshold keeps its real result (you can't know to quit before seeing it). |

**Why C and D are compared side by side:** if session-length losses were driven by chasing (tilt),
a stop-loss should recover most of the gap; if driven by fatigue/volume regardless of results, a
flat hand-cap should recover more. Comparing the two `delta_vs_actual` values is itself the
diagnostic — this script doesn't declare a winner, the numbers do.

## 14. Hand-trajectory clustering (`hand_clusters.R` -> 2 CSVs)

Unsupervised k-means (`k=6`, seed fixed, `nstart=25`) over a 13-feature vector per hand (preflop
role, position, multiway, bet-size-as-%-pot per street, call indicators, final made-hand strength via
`coalesce(made_river, made_turn, made_flop)`, and how far the hand went), scaled before clustering.
Scope: cash hands with `saw_flop & n_flop>=2` (clean single-board reconstruction). Cluster
**membership never uses the hand's outcome** — `net`/`net_bb` are joined in only for the summary
table, after clustering, so this isn't capped by the hidden-information ceiling that limited
supervised prediction (see [[opponent-research-scope]] equivalent finding in this repo's memory).
Wired into `render_coinpoker.R`. Auto-generated cluster descriptions pick the 4 features with the
largest `|cluster mean − population mean| / population sd`, so two correlated proxies for the same
underlying fact (e.g. "checks flop" and "calls flop") can both surface — read as one signal, not two.

**Caveats (stated, not hidden):** `k=6` and the feature list are modeling choices, not a ground truth
partition; small clusters are noisier; this is descriptive/correlational, not a causal claim about
which trajectory to choose. In practice the clusters have consistently landed on the same leaks/
strengths already documented elsewhere (value river bets, calling down to showdown) — a useful
independent cross-check, not a claim of new discovery.

## 15. Table ecology (`table_ecology.R` -> `coinpoker_table_ecology.csv`)

In CoinPoker exports `table_id` is a **persistent lobby identity**: one table name spans many
sessions and maps to exactly one stake, so there is no stake-mixing confound. That makes
table-level history a direct readout that needs no opponent tracking. Wired into
`render_coinpoker.R`. Scope: tables with ≥30 hands.

| Column | Defined as |
|---|---|
| `avg_players` | mean `n_players` (seats occupied) across all hands at that table |
| `hero_vpip` | Hero's own VPIP at that table only |
| `avg_pot_bb` | mean `pot/bb` among **`saw_flop`** hands only (excludes trivial preflop-only pots) |
| `multiway_rate` | fraction of `saw_flop` hands with `n_flop >= 3` |
| `net`, `bb100` | Hero's own results at that table |

**Caveat, stated loudly:** the correlation of table character (`avg_pot_bb`, `multiway_rate`,
`avg_players`) against `bb100` is computed across a few dozen tables at most — too few for a trustworthy
correlation coefficient, printed to console as descriptive/hypothesis-generating only, never
promoted to a claimed relationship. The **per-table ranking itself** (not the correlation) is the
actionable part: these are specific, revisitable tables, so "table X has been a losing venue" is a
direct fact about Hero's history there, not an inference.

## 16. Rakeback allocation (`rakeback_allocate.R` — 4 CSVs)

Rakeback accrues per hand but is claimed by hand, at irregular intervals, as lump transfers from
a rewards balance. The input is a claim ledger, `coinpoker_rakeback.csv` (dt, amount, transfer,
msg_id), one row per claim: the **exact ledger**. `simulate_hands.py` writes a synthetic one at a
30% rate; with real data it comes from the site's transfer confirmations. Wired into
`render_coinpoker.R` before `downswing_sim.R` (which optionally folds the result in).

**`rakeback_allocate.R`** — turns the lumpy claim ledger into per-hand/per-stake numbers:
- Buckets every hand (including bomb pots — they still generate rake) into `(previous claim's dt,
  this claim's dt]` windows via `findInterval`; the first window starts at the beginning of the hand
  data. Hands after the last claim are unclaimed (not yet real money).
- The **per-window implied rate** (claim $ / that window's contributed fees) is highly unstable —
  it can swing from single digits to over 1000% — because some windows have almost no fee volume.
  **Not used directly**, but written to `coinpoker_rakeback_windows.csv` as an audit trail showing
  why.
- The actual allocation uses **one aggregate rate = total claimed / total fees across the whole
  claimed period**, applied flat to every hand's own `fees`. This conserves the grand total
  **exactly** (sums back to the real claimed $) and is far less noise-sensitive.
- `coinpoker_rakeback_allocated.csv` (id, allocated_rakeback) — per-hand, joined by `downswing_sim.R`.
- `coinpoker_rakeback_by_stake.csv` — fees/rakeback/net/bb100 before vs after, by stake.
- `coinpoker_rakeback_overall.csv` — same, aggregated, plus `unclaimed_est` (fees since the last
  claim × the aggregate rate — a **projection**, not yet real money, reported separately).

**Caveats (stated loudly, not hidden):**
- The **overall total adjustment is exact** — any per-hand proportional allocation method sums back
  to the real claimed $, so "net before → net after" and the overall bb/100 shift are trustworthy
  regardless of allocation method.
- The **stake-level (and hand-level) split is a model**, not measured — it assumes rakeback tracks
  Hero's own contributed fees at a constant rate over the claimed period. The wild swing in per-window
  rates hints the real mechanism might not be a strict fee-percentage (could include VIP tier/promo
  components) — so read the by-stake table as illustrative of *where* the money likely came from, not
  as exact.
- `downswing_sim.R`'s rakeback-adjusted Bayesian posterior (`coinpoker_winrate_posterior_rakeback.csv`)
  and the "central + rakeback" risk-of-ruin scenario both use this modeled per-hand allocation, so they
  inherit the same caveat — a genuine, meaningful lift to P(winner), not a claim of exact precision.

---

*Maintenance: when a new derived term is added in code, add a row here in the same turn. The leak
ledger reads these definitions directly, so a change here is a change to the scoreboard.*
