#!/usr/bin/env Rscript
# ---------------------------------------------------------------------------
# Hand-trajectory clustering: instead of pre-defining a handful of named lines (the existing
# "Betting lines" section buckets by literal bet/no-bet per street), let k-means find whatever
# groupings actually exist in a richer feature space - preflop role, position, multiway, bet size
# per street, call indicators, final made-hand strength, how far the hand went. This is UNSUPERVISED
# (grouping only, no outcome used to form clusters) so it isn't capped by the hidden-information
# ceiling that limited supervised prediction (opponent-research-scope memory) - net/bb100 per cluster
# is reported AFTER the fact, purely descriptively.
#
# Scope: cash hands with saw_flop & n_flop>=2 (clean single-board reconstruction). k=6, fixed seed.
# CAVEAT (stated, not hidden): cluster count and feature set are modeling choices, not discovered
# truths; small clusters can be noisy; this describes correlational shapes, not causation.
# Writes coinpoker_hand_clusters.csv (per-hand assignment) and coinpoker_hand_clusters_summary.csv.
# Run: Rscript hand_clusters.R
# ---------------------------------------------------------------------------
suppressWarnings(suppressMessages(library(dplyr)))
a <- grep("--file=", commandArgs(FALSE), value = TRUE)
if (length(a)) setwd(dirname(sub("--file=", "", a[1])))         
FEAT <- "coinpoker_features.csv"
if (!file.exists(FEAT)) system2("Rscript", "features_coinpoker.R")
K <- 6

d <- read.csv(FEAT, stringsAsFactors = FALSE)
d <- d[d$is_bomb != "TRUE" & d$is_bomb != TRUE, ]
d <- d[d$saw_flop == "TRUE" & !is.na(d$n_flop) & d$n_flop >= 2, ]
num0 <- function(x) { x <- suppressWarnings(as.numeric(x)); ifelse(is.na(x), 0, x) }
tf <- function(x) x == "TRUE" | x == TRUE

d$final_made <- ifelse(!is.na(d$made_river), d$made_river,
                 ifelse(!is.na(d$made_turn), d$made_turn, d$made_flop))

feat <- data.frame(
  pf_aggr        = as.numeric(tf(d$hero_pf_aggr)),
  oop            = as.numeric(tf(d$hero_first_flop)),
  multiway       = as.numeric(d$n_flop >= 3),
  flop_bet       = num0(d$flop_betpot),
  turn_bet       = num0(d$turn_betpot),
  river_bet      = num0(d$river_betpot),
  flop_call_ind  = as.numeric(num0(d$flop_call) > 0),
  turn_call_ind  = as.numeric(num0(d$turn_call) > 0),
  river_call_ind = as.numeric(num0(d$river_call) > 0),
  final_made     = num0(d$final_made),
  saw_turn_ind   = as.numeric(tf(d$saw_turn)),
  saw_river_ind  = as.numeric(tf(d$saw_river)),
  showdown_ind   = as.numeric(tf(d$showdown))
)

set.seed(42)
km <- kmeans(scale(feat), centers = K, nstart = 25, iter.max = 50)
d$cluster <- km$cluster

label_map <- list(
  pf_aggr        = c(lo = "preflop caller", hi = "preflop aggressor"),
  oop            = c(lo = "in position", hi = "out of position"),
  multiway       = c(lo = "heads-up pot", hi = "multiway pot"),
  flop_bet       = c(lo = "checks flop", hi = "bets flop"),
  turn_bet       = c(lo = "checks turn", hi = "bets turn"),
  river_bet      = c(lo = "checks river", hi = "bets river"),
  flop_call_ind  = c(lo = "doesn't call flop", hi = "calls flop"),
  turn_call_ind  = c(lo = "doesn't call turn", hi = "calls turn"),
  river_call_ind = c(lo = "doesn't call river", hi = "calls river"),
  final_made     = c(lo = "weak/no made hand", hi = "strong made hand"),
  saw_turn_ind   = c(lo = "folds by flop", hi = "reaches turn"),
  saw_river_ind  = c(lo = "folds by turn", hi = "reaches river"),
  showdown_ind   = c(lo = "wins/folds without showdown", hi = "goes to showdown")
)
pop_mean <- colMeans(feat); pop_sd <- apply(feat, 2, sd)

describe_cluster <- function(cl_id) {
  cm <- colMeans(feat[d$cluster == cl_id, , drop = FALSE])
  z <- (cm - pop_mean) / pop_sd
  top <- names(sort(abs(z), decreasing = TRUE))[1:4]
  parts <- sapply(top, function(nm) label_map[[nm]][ifelse(z[nm] >= 0, "hi", "lo")])
  paste(parts, collapse = ", ")
}

summ <- d %>% group_by(cluster) %>% summarise(
  n = n(), Net = round(sum(net), 1), `bb/100` = round(sum(net_bb) / n() * 100, 1), .groups = "drop"
) %>% arrange(desc(n))
summ$Description <- sapply(summ$cluster, describe_cluster)
summ <- summ[, c("cluster", "n", "Description", "Net", "bb/100")]

cat(sprintf("=== Hand-trajectory clusters (k=%d, %d hands with saw_flop & n_flop>=2) ===\n", K, nrow(d)))
print(summ, row.names = FALSE)
cat(sprintf("\nwithin-cluster SS / total SS = %.1f%% (lower = tighter clusters; some overlap is expected with %d mixed-type features)\n",
            100 * sum(km$withinss) / km$totss, ncol(feat)))

write.csv(summ, "coinpoker_hand_clusters_summary.csv", row.names = FALSE)
write.csv(d %>% select(id, dt, hero_cards, hero_pos, cluster, net, net_bb),
          "coinpoker_hand_clusters.csv", row.names = FALSE)
cat("wrote coinpoker_hand_clusters_summary.csv, coinpoker_hand_clusters.csv\n")
