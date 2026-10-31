#!/usr/bin/env Rscript
# ---------------------------------------------------------------------------
# RNG fairness audit: is the deck itself dealt uniformly? Different question from the existing
# "Card luck" dashboard section (which asks "did YOU run good/bad on premium hands vs the fixed
# combinatorial rate"). This asks the lower-level question a crypto-site skeptic actually has: does
# the shuffle look like a fair 52-card deck at all, across rank, suit, and specific-card frequency,
# for both hole cards and board cards? With ~12k hands this is a real, if modest, sample size.
# Multiple-comparisons note: at alpha=0.05 and ~9 independent-ish tests, ~0-1 "significant" hits are
# EXPECTED even from a perfectly fair deck - the report says so explicitly rather than overclaiming
# on any single low p-value.
# Writes coinpoker_rng_audit.csv. Run: Rscript rng_audit.R
# ---------------------------------------------------------------------------
a <- grep("--file=", commandArgs(FALSE), value = TRUE)
if (length(a)) setwd(dirname(sub("--file=", "", a[1])))         
FEAT <- "coinpoker_features.csv"
if (!file.exists(FEAT)) system2("Rscript", "features_coinpoker.R")

RANKS <- c("2","3","4","5","6","7","8","9","T","J","Q","K","A")
SUITS <- c("c","d","h","s")
DECK <- as.vector(outer(RANKS, SUITS, paste0))

d <- read.csv(FEAT, stringsAsFactors = FALSE)
d <- d[d$is_bomb != "TRUE" & d$is_bomb != TRUE, ]

split_cards <- function(x) unlist(strsplit(x[!is.na(x) & x != "NA" & x != ""], " "))

hole <- split_cards(d$hero_cards)
board <- split_cards(c(d$flop[d$multi_board == "FALSE" | d$multi_board == FALSE],
                        d$turn_card[d$multi_board == "FALSE" | d$multi_board == FALSE],
                        d$river_card[d$multi_board == "FALSE" | d$multi_board == FALSE]))

rank_test <- function(cards, label) {
  obs <- table(factor(substr(cards, 1, 1), levels = RANKS))
  ct <- suppressWarnings(chisq.test(as.integer(obs)))
  list(label = label, statistic = ct$statistic, df = length(RANKS) - 1, p = ct$p.value, n = length(cards))
}
suit_test <- function(cards, label) {
  obs <- table(factor(substr(cards, 2, 2), levels = SUITS))
  ct <- suppressWarnings(chisq.test(as.integer(obs)))
  list(label = label, statistic = ct$statistic, df = length(SUITS) - 1, p = ct$p.value, n = length(cards))
}
specific_test <- function(cards, label) {
  obs <- table(factor(cards, levels = DECK))
  ct <- suppressWarnings(chisq.test(as.integer(obs)))
  list(label = label, statistic = ct$statistic, df = length(DECK) - 1, p = ct$p.value, n = length(cards))
}

tests <- list(
  rank_test(hole, "hole card rank (13 categories)"),
  suit_test(hole, "hole card suit (4 categories)"),
  specific_test(hole, "hole card, specific (52 categories)"),
  rank_test(board, "board card rank (13 categories)"),
  suit_test(board, "board card suit (4 categories)"),
  specific_test(board, "board card, specific (52 categories)")
)

pair_n <- sum(d$pair, na.rm = TRUE); pair_tot <- sum(!is.na(d$pair))
suited_n <- sum(d$suited, na.rm = TRUE); suited_tot <- sum(!is.na(d$suited))
pair_bt <- binom.test(pair_n, pair_tot, p = 3/51)
suited_bt <- binom.test(suited_n, suited_tot, p = 12/51)

cat(sprintf("=== RNG fairness audit (%d non-bomb hands) ===\n\n", nrow(d)))
cat(sprintf("%-38s %8s %4s %8s %6s\n", "test", "chi-sq", "df", "p-value", "n"))
for (t in tests)
  cat(sprintf("%-38s %8.2f %4d %8.3f %6d\n", t$label, t$statistic, t$df, t$p, t$n))
cat(sprintf("%-38s %8s %4s %8.3f %6d   (expect %.4f, observed %.4f)\n",
            "pocket pair rate (binomial)", "-", "-", pair_bt$p.value, pair_tot, 3/51, pair_n/pair_tot))
cat(sprintf("%-38s %8s %4s %8.3f %6d   (expect %.4f, observed %.4f)\n",
            "suited rate (binomial)", "-", "-", suited_bt$p.value, suited_tot, 12/51, suited_n/suited_tot))

n_sig <- sum(sapply(tests, function(t) t$p < 0.05)) + (pair_bt$p.value < 0.05) + (suited_bt$p.value < 0.05)
cat(sprintf("\n%d of %d tests significant at alpha=0.05 (with %d tests, ~%.1f are expected by chance alone\n",
            n_sig, length(tests) + 2, length(tests) + 2, 0.05 * (length(tests) + 2)))
cat(ifelse(n_sig <= 1, "even from a perfectly fair deck) - no evidence of a biased shuffle.\n",
           "even from a perfectly fair deck) - more hits than chance alone predicts; worth a second look with more hands.\n"))

out <- do.call(rbind, lapply(tests, function(t) data.frame(test = t$label, statistic = round(t$statistic, 2),
                                                             df = t$df, p_value = round(t$p, 4), n = t$n)))
out <- rbind(out,
  data.frame(test = "pocket pair rate (binomial)", statistic = NA, df = NA, p_value = round(pair_bt$p.value, 4), n = pair_tot),
  data.frame(test = "suited rate (binomial)", statistic = NA, df = NA, p_value = round(suited_bt$p.value, 4), n = suited_tot))
write.csv(out, "coinpoker_rng_audit.csv", row.names = FALSE)
