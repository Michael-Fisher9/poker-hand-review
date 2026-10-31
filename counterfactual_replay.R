#!/usr/bin/env Rscript
# ---------------------------------------------------------------------------
# Counterfactual replay: re-run Hero's actual hand history under simple mechanical policies and
# compare the alternate bankroll curve to what actually happened.
#
# Policies A/B (fold loose hands) are CLEAN counterfactuals: each hand's outcome is replaced
# independently using only information available at the moment of the fold decision (the hand's own
# range classification), so there's no lookahead and no interaction between hands. The "cost" of a
# hypothetical fold is the blind/ante Hero would still have posted (0 for non-blind seats), not 0
# outright - this matters, folding the SB isn't free.
#
# Policies C/D (session hand-cap, stop-loss) are arithmetically exact for "what if I'd logged off
# right there" (unplayed hands net exactly $0 - that's what not playing means), but they are NOT
# proof that quitting-on-a-signal would work prospectively: this is hindsight replay on sessions
# whose outcome we already know, not a real-time rule tested on unseen sessions. The session-log
# (session_analysis.R, `ended_reason` column) is what will eventually settle whether long-session
# losses are fatigue or chasing - that's the causal question this script can't answer.
#
# Writes coinpoker_counterfactual.csv (one row per policy: actual vs counterfactual net/bb100) and
# coinpoker_counterfactual_curves.csv (per-hand cumulative bb for each policy, for the chart).
# Run: Rscript counterfactual_replay.R
# ---------------------------------------------------------------------------
suppressWarnings(suppressMessages(library(dplyr)))
a <- grep("--file=", commandArgs(FALSE), value = TRUE)
if (length(a)) setwd(dirname(sub("--file=", "", a[1])))         
FEAT <- "coinpoker_features.csv"
if (!file.exists(FEAT)) system2("Rscript", "features_coinpoker.R")

HAND_CAP <- 150       # session hand-cap policy (matches the "long sessions lose" cutoff finding)
STOP_LOSS_BI <- 3     # stop-loss policy, in 100bb buy-ins

d <- read.csv(FEAT, stringsAsFactors = FALSE)
d <- d[d$is_bomb != "TRUE" & d$is_bomb != TRUE, ]
d$dt <- as.POSIXct(d$dt, tz = "America/Chicago")
d <- d[order(d$dt), ]
d$idx <- seq_len(nrow(d))
d$session <- cumsum(c(Inf, as.numeric(diff(d$dt), units = "mins")) > 30)
d$ante[is.na(d$ante)] <- 0

fold_cost <- -d$ante - ifelse(d$hero_pos == "SB", d$sb, ifelse(d$hero_pos == "BB", d$bb, 0))

# ---- Policy A/B: fold loose hands (position-aware open-range baseline, DATA_DICTIONARY §3) ----
is_loose <- !is.na(d$range_dir) & d$range_dir == "loose"
d$net_A <- ifelse(is_loose & d$hero_pos == "SB", fold_cost, d$net)
d$net_B <- ifelse(is_loose, fold_cost, d$net)

# ---- Policy C: session hand-cap ----
d <- d %>% group_by(session) %>% mutate(seq_in_session = row_number()) %>% ungroup()
d$net_C <- ifelse(d$seq_in_session > HAND_CAP, 0, d$net)

# ---- Policy D: stop-loss at STOP_LOSS_BI buy-ins ----
apply_stoploss <- function(sess_df) {
  thresh <- -STOP_LOSS_BI * 100 * sess_df$bb[1]
  cum <- cumsum(sess_df$net)
  quit_after <- which(cum < thresh)[1]
  if (is.na(quit_after) || quit_after >= nrow(sess_df)) return(sess_df$net)
  c(sess_df$net[seq_len(quit_after)], rep(0, nrow(sess_df) - quit_after))
}
d <- d %>% arrange(session, idx)
d$net_D <- unlist(lapply(split(d, d$session), apply_stoploss))
d <- d %>% arrange(idx)

# ---- summary ----
bb100 <- function(net_col, bbcol = d$bb) sum(net_col / bbcol * 100) / length(net_col)
summarize_policy <- function(net_col, label) {
  data.frame(policy = label, net = round(sum(net_col), 1), bb100 = round(bb100(net_col), 1),
             delta_vs_actual = round(sum(net_col) - sum(d$net), 1))
}
summ <- rbind(
  summarize_policy(d$net, "actual"),
  summarize_policy(d$net_A, sprintf("A: fold loose SB hands")),
  summarize_policy(d$net_B, sprintf("B: fold all loose hands")),
  summarize_policy(d$net_C, sprintf("C: cap sessions at %d hands", HAND_CAP)),
  summarize_policy(d$net_D, sprintf("D: stop-loss at %d buy-ins/session", STOP_LOSS_BI))
)
cat("=== Counterfactual replay ===\n")
print(summ, row.names = FALSE)
cat(sprintf("\n(n=%d non-bomb hands, %d sessions, HAND_CAP=%d, STOP_LOSS_BI=%d)\n",
            nrow(d), length(unique(d$session)), HAND_CAP, STOP_LOSS_BI))
write.csv(summ, "coinpoker_counterfactual.csv", row.names = FALSE)

curves <- d %>% transmute(idx, actual = cumsum(net_bb),
                           A = cumsum(net_A / bb), B = cumsum(net_B / bb),
                           C = cumsum(net_C / bb), D = cumsum(net_D / bb))
write.csv(curves, "coinpoker_counterfactual_curves.csv", row.names = FALSE)
cat("wrote coinpoker_counterfactual.csv, coinpoker_counterfactual_curves.csv\n")
