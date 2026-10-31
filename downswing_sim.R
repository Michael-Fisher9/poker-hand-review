#!/usr/bin/env Rscript
# ---------------------------------------------------------------------------
# Downswing-in-context simulator: three questions, one script.
#  1. Bootstrap: resample Hero's own per-hand results (i.i.d, since the session-log work found
#     no tilt/autocorrelation signature) into 5,000 simulated careers of the SAME length as the
#     real sample, and ask how often a max drawdown at least as big as the REAL one shows up by
#     chance alone. Answers "is a swing this size actually surprising for a player like me?"
#  2. Bayesian posterior on true winrate: normal-normal conjugate, mu ~ N(0, tau0^2) (a skeptical
#     prior centered at breakeven - stated, not hidden), likelihood = the sample mean/SE. Reports
#     P(true winrate > 0) overall and per stake, plus a sensitivity check under a much wider prior
#     (tau0=50) so the "how sure are we" claim isn't dressed up as prior-free.
#  3. Risk of ruin: classic drift-diffusion approximation RoR = exp(-2*mu*bankroll/sigma^2) (mu<=0
#     -> 1), swept over bankroll size (in buy-ins) using the posterior mean AND its 95% CI bounds,
#     so the curve shows how uncertain the winrate estimate makes the ruin estimate itself.
# Writes: coinpoker_downswing_sim.csv (bootstrap summary), coinpoker_bootstrap_dd.csv (the 5,000
# simulated drawdowns, for the histogram), coinpoker_winrate_posterior.csv, coinpoker_risk_of_ruin.csv.
# Run: Rscript downswing_sim.R
# ---------------------------------------------------------------------------
suppressWarnings(suppressMessages(library(dplyr)))
a <- grep("--file=", commandArgs(FALSE), value = TRUE)
if (length(a)) setwd(dirname(sub("--file=", "", a[1])))         
FEAT <- "coinpoker_features.csv"
if (!file.exists(FEAT)) system2("Rscript", "features_coinpoker.R")

d <- read.csv(FEAT, stringsAsFactors = FALSE)
d <- d[d$is_bomb != "TRUE" & d$is_bomb != TRUE, ]
d$dt <- as.POSIXct(d$dt)
d <- d[order(d$dt), ]
d$stake <- paste0(d$sb, "/", d$bb)
n <- nrow(d)
netbb <- d$net_bb

# ---- 1. bootstrap max-drawdown ----
cum <- cumsum(netbb)
actual_dd <- max(cummax(cum) - cum)
set.seed(1)
B <- 5000
sim_dd <- numeric(B)
for (i in seq_len(B)) {
  x <- sample(netbb, n, replace = TRUE)
  cx <- cumsum(x)
  sim_dd[i] <- max(cummax(cx) - cx)
}
pctile <- mean(sim_dd >= actual_dd)
cat(sprintf("=== 1. Bootstrap max-drawdown (%d reps, %d hands/rep) ===\n", B, n))
cat(sprintf("  your actual worst peak-to-trough swing: %.0f bb\n", actual_dd))
cat(sprintf("  a player with your exact hand-level return distribution hits a swing >= that\n"))
cat(sprintf("  in %.0f%% of simulated careers this long (median simulated worst swing: %.0f bb)\n\n",
            100 * pctile, median(sim_dd)))
write.csv(data.frame(n_hands = n, B = B, actual_dd_bb = round(actual_dd, 1),
                      median_sim_dd_bb = round(median(sim_dd), 1), percentile = round(pctile, 4)),
          "coinpoker_downswing_sim.csv", row.names = FALSE)
write.csv(data.frame(sim_dd_bb = round(sim_dd, 1)), "coinpoker_bootstrap_dd.csv", row.names = FALSE)

# ---- 2. Bayesian posterior on true winrate (bb/100), normal-normal conjugate ----
post_est <- function(x, tau0) {
  nn <- length(x); mu_hat <- mean(x) * 100; se <- sd(x) * 100 / sqrt(nn)
  post_var <- 1 / (1 / tau0^2 + 1 / se^2)
  post_mean <- post_var * (mu_hat / se^2)
  ci <- 1.96 * sqrt(post_var)
  p_win <- 1 - pnorm(0, post_mean, sqrt(post_var))
  data.frame(n = nn, raw_bb100 = round(mu_hat, 1), se_bb100 = round(se, 1),
             post_bb100 = round(post_mean, 1), ci_lo = round(post_mean - ci, 1),
             ci_hi = round(post_mean + ci, 1), p_winner = round(p_win, 3), tau0 = tau0)
}
groups <- split(netbb, d$stake)
TAU0 <- 8   # skeptical prior sd (bb/100) - regulars mostly live in a +-8-ish band; stated, not hidden
rows <- lapply(names(groups), function(s) cbind(stake = s, post_est(groups[[s]], TAU0)))
overall <- cbind(stake = "overall", post_est(netbb, TAU0))
wr <- rbind(overall, do.call(rbind, rows))
wide_check <- post_est(netbb, 50)   # sensitivity: near-uninformative prior
cat("=== 2. Bayesian posterior on true winrate (bb/100), skeptical prior N(0, 8^2) ===\n")
print(wr, row.names = FALSE)
cat(sprintf("\n  sensitivity check (near-flat prior N(0,50^2)): posterior %.1f bb/100 [%.1f, %.1f], P(winner)=%.0f%%\n",
            wide_check$post_bb100, wide_check$ci_lo, wide_check$ci_hi, 100 * wide_check$p_winner))
cat("  (the skeptical prior pulls estimates toward 0 more; both are shown so the conclusion\n   isn't silently prior-dependent)\n\n")
write.csv(wr, "coinpoker_winrate_posterior.csv", row.names = FALSE)

# ---- 2b. Same posterior, with rakeback folded in (if coinpoker_rakeback_allocated.csv exists) ----
RB <- "coinpoker_rakeback_allocated.csv"
has_rakeback <- file.exists(RB)
if (has_rakeback) {
  rb_alloc <- read.csv(RB, stringsAsFactors = FALSE)
  d <- left_join(d, rb_alloc, by = "id")
  d$allocated_rakeback[is.na(d$allocated_rakeback)] <- 0
  netbb_adj <- netbb + d$allocated_rakeback / d$bb
  groups_adj <- split(netbb_adj, d$stake)
  rows_adj <- lapply(names(groups_adj), function(s) cbind(stake = s, post_est(groups_adj[[s]], TAU0)))
  overall_adj <- cbind(stake = "overall", post_est(netbb_adj, TAU0))
  wr_adj <- rbind(overall_adj, do.call(rbind, rows_adj))
  cat("=== 2b. Same posterior, WITH rakeback folded in (see rakeback_allocate.R - modeled, not exact per-hand) ===\n")
  print(wr_adj, row.names = FALSE)
  cat(sprintf("\n  overall P(winner): %.0f%% without rakeback -> %.0f%% with it folded in\n\n",
              100 * overall$p_winner, 100 * overall_adj$p_winner))
  write.csv(wr_adj, "coinpoker_winrate_posterior_rakeback.csv", row.names = FALSE)
} else {
  cat("(no coinpoker_rakeback_allocated.csv - run rakeback_allocate.R for a with-rakeback posterior)\n\n")
}

# ---- 3. Risk of ruin (drift-diffusion approximation) ----
mu_bb_per_hand <- overall$post_bb100 / 100
sigma_bb_per_hand <- sd(netbb)
mu_lo <- overall$ci_lo / 100; mu_hi <- overall$ci_hi / 100
ror <- function(mu, sigma, bankroll_bb) if (mu <= 0) 1 else exp(-2 * mu * bankroll_bb / sigma^2)
buyins <- c(10, 20, 30, 50, 100, 150)
rr <- data.frame(
  buyins = rep(buyins, 3),
  scenario = rep(c("pessimistic (CI low)", "central (posterior mean)", "optimistic (CI high)"), each = length(buyins)),
  bankroll_bb = rep(buyins * 100, 3),
  ror_pct = c(sapply(buyins * 100, ror, mu = mu_lo, sigma = sigma_bb_per_hand),
              sapply(buyins * 100, ror, mu = mu_bb_per_hand, sigma = sigma_bb_per_hand),
              sapply(buyins * 100, ror, mu = mu_hi, sigma = sigma_bb_per_hand)) * 100
)
if (has_rakeback) {
  mu_adj <- overall_adj$post_bb100 / 100
  rr <- rbind(rr, data.frame(buyins = buyins, scenario = "central + rakeback", bankroll_bb = buyins * 100,
                              ror_pct = sapply(buyins * 100, ror, mu = mu_adj, sigma = sigma_bb_per_hand) * 100))
}
cat("=== 3. Risk of ruin (bankroll in 100bb buy-ins) ===\n")
print(rr %>% mutate(ror_pct = round(ror_pct, 1)), row.names = FALSE)
write.csv(rr, "coinpoker_risk_of_ruin.csv", row.names = FALSE)
