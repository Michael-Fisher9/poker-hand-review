# poker-hand-review

Turns a player's own online poker hand histories into a single-page review: results by stake and table, positional and postflop tendencies, a luck-versus-decisions breakdown, a downswing simulator, a Bayesian estimate of the true win rate, and a ledger of where losses come from.

Hand histories record what happened, in text meant for people. Most of the work is reconstruction: the pot at every decision, what each bet cost relative to the pot, who was the preflop aggressor, which hands were all-in with cards to come. Every number on the page is built from that reconstruction. The input format is CoinPoker's cash-game export. The repository ships with a generator for synthetic hands in that format, so it runs without anyone's real history.

## Run it

Needs R (dplyr, ggplot2, plotly, scales, stringr, tidyr, rmarkdown) and Python 3.10+.

```
python -m venv .venv && .venv/bin/pip install -r requirements.txt
.venv/bin/python simulate_hands.py --hands 10000 --out hands
Rscript render_coinpoker.R            # about 2.5 minutes; --quick skips the luck ledger
```

```
Read 50 files, 10000 hand blocks; removed 0 duplicate id(s) -> 10000 unique hands.
Stack-delta validation on 9898 pairs: 99.1% exact, 100.0% explained by net + top-up.
Done -> coinpoker_dashboard.html
```

![Dashboard overview, synthetic data](docs/overview.png)

## What comes out

- `coinpoker_hands.csv`: one row per hand from Hero's view (position, cards, invested, collected, net, preflop and postflop flags, pot at each decision). `DATA_DICTIONARY.md` defines every column.
- `coinpoker_features.csv`: derived fields (starting-hand class, opening-range model, leak tags, a train/test split by day).
- `coinpoker_dashboard.html`: the review, about 20 sections.
- Side tools: `leak_trainer.html` (flashcards built from missed spots), `coinpoker_year_in_review.html`, and `allin_ev.py` (all-in equity against what was actually won).

| | |
|---|---|
| ![Downswing simulator](docs/downswing.png) | ![Starting-hand grid](docs/hand-grid.png) |
| ![Leak ledger](docs/leak.png) | |

## How it works

`parse_coinpoker.R` splits the export into hands and walks each one line by line, tracking every player's chips committed per street, so the pot Hero faced at each call or bet is exact rather than estimated. `features_coinpoker.R` adds the hand classes and leak tags. Each analysis script writes its own CSV:

| Script | Question |
|---|---|
| `downswing_sim.R` | Is the worst drawdown unusual? Bootstrap of 5,000 careers, a normal-prior posterior on the win rate, risk of ruin |
| `luck_ledger.py` | How much of the deepest drawdown is cards, all-in results and river cards, and how much is left for decisions? |
| `counterfactual_replay.R` | What would simple rules (fold loose hands, cap hands per session, stop-loss) have done on the same hands? |
| `hand_clusters.R` | What hand shapes emerge from k-means on street-by-street action, without seeing results? |
| `rng_audit.R` | Does the dealt distribution look like a fair deck? Chi-square on ranks, suits and cards |
| `rakeback_allocate.R` | Rakeback is claimed in lumps at irregular times; how much belongs to each hand and stake? |
| `missed_ops.R`, `table_ecology.R` | Bets not made; results by table |
| `session_analysis.R` | Does play change in the hands after a big loss? |

`render_coinpoker.R` runs all of it and knits `coinpoker_dashboard.Rmd`.

The pipeline is moving to Python a stage at a time. `parse_coinpoker.py` is done; a test checks it against the R parser column by column.

## Why it's built this way

- **The parser is checked against the stack, not just itself.** Each hand's net plus any top-up should equal the stack at the next hand at the same table. That check runs on every parse and is printed with the totals.
- **Synthetic hands with known answers.** `simulate_hands.py` plays each hand through PokerKit's engine with real cards, so pots, side pots, uncalled bets and showdowns are exact, then writes it in the export format. It also records Hero's true net, VPIP and flops seen, and the test suite checks that the R parser recovers all three on every hand, to the cent.
- **Planted leaks.** Hero's simulated strategy cold-calls too wide in position and folds too often to flop continuation bets. The dashboard should flag both, and it does: VPIP 27% against PFR 13%, button VPIP 45%, fold to c-bet 59%.
- **Uncertainty on every headline number.** Win rates are reported with a posterior interval and a probability of being a long-run winner, because 10,000 hands is not enough to separate a small edge from noise.
- **Descriptions are computed, not typed.** Every sentence that states a result is generated from the data on the page, and the guidance beside each chart describes what to look for rather than what it found.
- **The deepest drawdown is found, not chosen.** The luck ledger's window runs from the peak to the trough of the largest fall in cumulative net; `--window-start` and `--window-end` override it.
- **The train/test split is by day.** The last 15% of hands, cut on a day boundary so hands from one session don't straddle it, are held out from the leak definitions.

## Limits

- Opponents are only seen at showdown, so their tendencies come from the hands they showed, which skews toward strong ones.
- Leak tags are heuristics on one player's hands, not a solver comparison. A hand can carry several tags; the attribution view assigns each losing hand to one.
- The synthetic players follow simple strategies driven by hand strength. They exercise the pipeline; they don't play like people.
- Only the CoinPoker cash-game format is parsed. Other sites need their own parser that writes the same `coinpoker_hands.csv` columns.

## License

MIT. Not affiliated with CoinPoker. The repository contains no real hand histories.
