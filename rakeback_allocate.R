#!/usr/bin/env Rscript
# ---------------------------------------------------------------------------
# Rakeback allocation: turns the exact-but-lumpy claim ledger (coinpoker_rakeback.csv, from
# simulate_hands.py, or your own export) into a per-hand estimate, so rakeback can be folded into net/bb100 same as any
# other result. Claims are triggered by hand at irregular intervals, so there's no per-hand ground truth - the allocation below is a MODEL, clearly
# separated from the ledger, which is EXACT.
#
# Method: sort claims by date, bucket hands into (previous claim's dt, this claim's dt] windows (first
# window = from the start of the hand data) using Hero's own contributed fees (rake+splash, the `fees`
# column - ALL hands, including bomb pots, since bombs still generate rake) as the presumed rakeback
# basis. The PER-WINDOW implied rate (claim $ / window fees) is wildly unstable (some windows have
# almost no fee volume, e.g. the brief micro-stake dips) - a single window's ratio isn't trustworthy.
# So the actual allocation uses ONE aggregate rate = total claimed / total fees across the whole
# claimed period, applied flat to every hand's own fees. This still conserves the grand total EXACTLY
# (sums back to the real claimed $), is far less noise-sensitive than a window-by-window rate, and the
# per-window rates are still written out as an audit trail showing why a flat rate is the honest choice.
#
# Hands after the LAST claim haven't been cashed out yet (still sitting in Rewards Balance) - not
# allocated, only ESTIMATED separately using the average implied rate from real windows, clearly
# labeled as a projection.
#
# Writes: coinpoker_rakeback_allocated.csv (id, allocated_rakeback - per hand, for downswing_sim.R to
# fold into the winrate posterior), coinpoker_rakeback_by_stake.csv, coinpoker_rakeback_windows.csv
# (audit trail: one row per claim window with its implied rate).
# Run: Rscript rakeback_allocate.R
# ---------------------------------------------------------------------------
suppressWarnings(suppressMessages(library(dplyr)))
a <- grep("--file=", commandArgs(FALSE), value = TRUE)
if (length(a)) setwd(dirname(sub("--file=", "", a[1])))         
FEAT <- "coinpoker_features.csv"; RB <- "coinpoker_rakeback.csv"
if (!file.exists(FEAT)) system2("Rscript", "features_coinpoker.R")
if (!file.exists(RB)) stop("No claim ledger: ", RB, " (simulate_hands.py writes a synthetic one)")

d <- read.csv(FEAT, stringsAsFactors = FALSE)
d$dt <- as.POSIXct(d$dt, tz = "America/Chicago")
d$stake <- paste0(d$sb, "/", d$bb)
rb <- read.csv(RB, stringsAsFactors = FALSE)
rb$dt <- as.POSIXct(rb$dt, tz = "America/Chicago")
rb <- rb[order(rb$dt), ]

# ---- windows: claim i covers (claim[i-1]$dt, claim[i]$dt], first window starts at -Inf ----
cuts <- c(as.POSIXct(-Inf, origin = "1970-01-01", tz = "America/Chicago"), rb$dt)
d$window <- findInterval(d$dt, cuts)   # 1..nrow(rb) for hands up to the last claim; nrow(rb)+1 = unclaimed
d$window[d$window > nrow(rb)] <- NA    # after the last claim - not allocated (see "unclaimed" below)

win_fees <- d %>% filter(!is.na(window)) %>% group_by(window) %>% summarise(fees = sum(fees), .groups = "drop")
rb$window <- seq_len(nrow(rb))
rb <- left_join(rb, win_fees, by = "window") %>% mutate(implied_rate = ifelse(fees > 0, amount / fees, NA))

# single aggregate rate (stable) instead of the noisy per-window rate (see header note)
claimed_fees_total <- sum(d$fees[!is.na(d$window)])
weighted_rate <- sum(rb$amount) / claimed_fees_total
d <- d %>% mutate(allocated_rakeback = ifelse(!is.na(window), fees * weighted_rate, 0))

# ---- unclaimed estimate (hands after the last claim; NOT added to net, purely a projection) ----
unclaimed <- d %>% filter(is.na(window))
unclaimed_fees <- sum(unclaimed$fees)
unclaimed_est <- weighted_rate * unclaimed_fees

cat(sprintf("=== Rakeback allocation ===\n"))
cat(sprintf("  %d claims, %s total, %s - %s\n", nrow(rb), scales::dollar(sum(rb$amount)),
            format(min(rb$dt), "%Y-%m-%d"), format(max(rb$dt), "%Y-%m-%d")))
cat(sprintf("  per-window implied rate: median %.0f%%, range [%.0f%%, %.0f%%] of that window's fees -\n",
            100 * median(rb$implied_rate, na.rm = TRUE), 100 * min(rb$implied_rate, na.rm = TRUE),
            100 * max(rb$implied_rate, na.rm = TRUE)))
cat("  TOO UNSTABLE to use directly (some windows have almost no fee volume) - using one aggregate rate instead:\n")
cat(sprintf("  aggregate rate: %.1f%% (total claimed / total fees across the whole claimed period)\n", 100 * weighted_rate))
cat(sprintf("  hands since last claim: %d, %s in fees -> ~%s estimated still unclaimed (projection, not in the ledger)\n",
            nrow(unclaimed), scales::dollar(unclaimed_fees), scales::dollar(unclaimed_est)))

by_stake <- d %>% group_by(stake) %>% summarise(
  hands = n(), fees = round(sum(fees), 2), rakeback = round(sum(allocated_rakeback), 2),
  net_before = round(sum(net), 1), net_after = round(sum(net) + sum(allocated_rakeback), 1),
  bb100_before = round(sum(net_bb) / n() * 100, 1),
  bb100_after = round(sum(net_bb + allocated_rakeback / bb) / n() * 100, 1), .groups = "drop"
) %>% arrange(desc(hands))
cat("\n"); print(as.data.frame(by_stake), row.names = FALSE)

overall <- data.frame(
  hands = nrow(d), fees = round(sum(d$fees), 2), rakeback = round(sum(d$allocated_rakeback), 2),
  unclaimed_est = round(unclaimed_est, 2),
  net_before = round(sum(d$net), 1), net_after = round(sum(d$net) + sum(d$allocated_rakeback), 1),
  bb100_before = round(sum(d$net_bb) / nrow(d) * 100, 1),
  bb100_after = round(sum(d$net_bb + d$allocated_rakeback / d$bb) / nrow(d) * 100, 1)
)
cat("\noverall:\n"); print(overall, row.names = FALSE)

write.csv(d %>% select(id, allocated_rakeback), "coinpoker_rakeback_allocated.csv", row.names = FALSE)
write.csv(by_stake, "coinpoker_rakeback_by_stake.csv", row.names = FALSE)
write.csv(rb %>% select(window, dt, amount, fees, implied_rate), "coinpoker_rakeback_windows.csv", row.names = FALSE)
write.csv(overall, "coinpoker_rakeback_overall.csv", row.names = FALSE)
cat("\nwrote coinpoker_rakeback_allocated.csv, coinpoker_rakeback_by_stake.csv, coinpoker_rakeback_windows.csv, coinpoker_rakeback_overall.csv\n")
