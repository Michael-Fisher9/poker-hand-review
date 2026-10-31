#!/usr/bin/env Rscript
# ---------------------------------------------------------------------------
# Table ecology: CoinPoker's table_id turns out to be a PERSISTENT lobby identity, not a one-off
# seating (one table name spans many sessions) -
# and each table_id maps to exactly one stake, so there's no stake-mixing confound within a table.
# That means "which specific table has been good for me" is an answerable, directly actionable
# question from Hero's own histories alone - no opponent profiling needed, table-level not player-level.
#
# Two outputs: (1) a direct per-table ranking by bb/100 (the actionable part - "table X has been
# good/bad"), and (2) a heavily-caveated look at whether table CHARACTER (avg pot size once a flop is
# seen, multiway rate, avg players) correlates with Hero's results there. Caveat on (2), stated loudly:
# only ~11 tables clear the hand-count floor, so any correlation coefficient at that n is closer to a
# hypothesis to keep an eye on than a proven relationship - don't oversell it.
#
# Writes coinpoker_table_ecology.csv. Run: Rscript table_ecology.R
# ---------------------------------------------------------------------------
suppressWarnings(suppressMessages(library(dplyr)))
a <- grep("--file=", commandArgs(FALSE), value = TRUE)
if (length(a)) setwd(dirname(sub("--file=", "", a[1])))         
FEAT <- "coinpoker_features.csv"
if (!file.exists(FEAT)) system2("Rscript", "features_coinpoker.R")
MIN_HANDS <- 30

d <- read.csv(FEAT, stringsAsFactors = FALSE)
d <- d[d$is_bomb != "TRUE" & d$is_bomb != TRUE, ]
d$stake <- paste0(d$sb, "/", d$bb)

sf <- d %>% filter(saw_flop == "TRUE", !is.na(n_flop))
sf_stats <- sf %>% group_by(table_id) %>%
  summarise(avg_pot_bb = mean(pot / bb, na.rm = TRUE),
            multiway_rate = mean(n_flop >= 3), .groups = "drop")

tbl <- d %>% group_by(table_id) %>%
  summarise(stake = dplyr::first(stake), n_hands = n(),
            avg_players = round(mean(n_players), 1),
            hero_vpip = round(mean(vpip == "TRUE" | vpip == TRUE), 3),
            net = round(sum(net), 1), bb100 = round(sum(net_bb) / n() * 100, 1),
            .groups = "drop") %>%
  filter(n_hands >= MIN_HANDS) %>%
  left_join(sf_stats, by = "table_id") %>%
  mutate(avg_pot_bb = round(avg_pot_bb, 1), multiway_rate = round(multiway_rate, 3)) %>%
  arrange(desc(bb100))

cat(sprintf("=== Table ecology (%d tables with >=%d hands, of %d total) ===\n\n",
            nrow(tbl), MIN_HANDS, length(unique(d$table_id))))
print(as.data.frame(tbl), row.names = FALSE)

if (nrow(tbl) >= 5) {
  cp <- suppressWarnings(cor(tbl$avg_pot_bb, tbl$bb100))
  cm <- suppressWarnings(cor(tbl$multiway_rate, tbl$bb100))
  ca <- suppressWarnings(cor(tbl$avg_players, tbl$bb100))
  cat(sprintf("\n--- table character vs bb/100 (n=%d tables - DESCRIPTIVE ONLY, not a proven relationship) ---\n", nrow(tbl)))
  cat(sprintf("  cor(avg pot size in bb, bb/100)   = %+.2f\n", cp))
  cat(sprintf("  cor(multiway rate, bb/100)        = %+.2f\n", cm))
  cat(sprintf("  cor(avg players seated, bb/100)   = %+.2f\n", ca))
  cat("  (at this n, treat any of these as a hypothesis to keep watching, not a settled finding)\n")
}
write.csv(tbl, "coinpoker_table_ecology.csv", row.names = FALSE)
cat("\nwrote coinpoker_table_ecology.csv\n")
