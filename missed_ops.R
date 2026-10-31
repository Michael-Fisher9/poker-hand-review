#!/usr/bin/env Rscript
# ---------------------------------------------------------------------------
# Missed-opportunity finder (review tool in the leak-ledger family).
# Detectors:
#   1. river checked-through  -> missed VALUE (made hand checked down & won)
#                                missed BLUFF (air/busted given up & lost) in a spot w/ fold equity
#   2. river bet TOO SMALL     -> had two pair+ but bet <40% pot and got called (under-sized value)
#   3. turn checked monster    -> set+ on the turn checked (no bet, no call) & won (slow-played value)
# Reads coinpoker_features.csv; writes coinpoker_missed_ops.csv + prints a summary.
# $ columns are ROUGH, pool-calibrated estimates used only for RANKING/sorting.
# These are REVIEW CANDIDATES, not verdicts: the tool can't see board wetness, so a
# checked monster or a small value bet on a flushy/straighty board may be a fine play.
# "Checked-through" uses hero_*_aggr (catches check-raises/shoves hero_*_bet misses).
# Run: Rscript missed_ops.R   (self-heals features if absent)
# ---------------------------------------------------------------------------
suppressWarnings(suppressMessages(library(dplyr)))
a <- grep("--file=", commandArgs(FALSE), value = TRUE)
if (length(a)) setwd(dirname(sub("--file=", "", a[1])))
FEAT <- "coinpoker_features.csv"
if (!file.exists(FEAT)) system2("Rscript", "features_coinpoker.R")
d <- read.csv(FEAT, stringsAsFactors = FALSE)

tf  <- function(x) { y <- x == TRUE | x == "TRUE"; y[is.na(y)] <- FALSE; y }
num <- function(x) suppressWarnings(as.numeric(x))
rv  <- function(r) { m <- c(A=14,K=13,Q=12,J=11,T=10); ifelse(r %in% names(m), m[r], suppressWarnings(as.integer(r))) }

# pool-calibrated constants (measured from our own HHs)
POOL_FOLD_RIVER <- 0.60; VAL_CALL <- 1 - POOL_FOLD_RIVER; BET_FRAC <- 0.66
FE_BOARD <- c(paired = 0.53, `ace-on-board` = 0.52, `mid/low-noace` = 0.49)

board_class <- function(flop, turn, river) {
  cards <- unlist(strsplit(trimws(paste(flop, turn, river)), " "))
  cards <- cards[cards != "NA" & nchar(cards) >= 2]
  if (length(cards) < 3) return(NA_character_)
  ranks <- rv(substr(cards, 1, 1))
  if (any(table(ranks) >= 2)) return("paired")
  if (any(ranks == 14)) return("ace-on-board")
  "mid/low-noace"
}
bclass_v <- function(df) mapply(board_class, df$flop, df$turn_card, df$river_card)

# clean universe: single board, non-bomb
base <- d[!tf(d$is_bomb) & !tf(d$multi_board), ]
cols <- c("id","dt","hero_cards","flop","turn_card","river_card")

# ---- detector 1: river checked through -------------------------------------
det_checked_river <- function() {
  # checked-through = Hero put NO money in on the river: not a bet, not a raise/shove
  # (hero_river_aggr catches raises/all-ins that hero_river_bet misses), and not a call.
  m <- base[tf(base$saw_river) &
            (is.na(base$hero_river_bet) | num(base$hero_river_bet) == 0) &
            !tf(base$hero_river_aggr) &
            (is.na(base$river_call)     | num(base$river_call)     == 0) &
            tf(base$showdown), ]
  if (!nrow(m)) return(NULL)
  md  <- num(m$made_river); won <- num(m$collected) > num(m$invested)
  pot <- pmax(num(m$collected), 2 * num(m$invested), 0, na.rm = TRUE)
  board <- bclass_v(m)
  potype <- ifelse(tf(m$three_bet) | tf(m$fold_to_3bet), "3bet-pot", "single-raised")
  hu <- num(m$n_flop) <= 2   # bluffs only count heads-up: multiway needs EVERYONE to fold
  type <- rep(NA_character_, nrow(m))
  type[md >= 2 & won]                         <- "missed_value_strong"
  type[md == 1 & won]                         <- "missed_value_thin"
  type[md == 0 & tf(m$on_draw)  & !won & hu]  <- "missed_bluff_busted"
  type[md == 0 & !tf(m$on_draw) & !won & hu]  <- "missed_bluff_air"
  ok <- !is.na(type)
  m <- m[ok,]; md<-md[ok]; pot<-pot[ok]; board<-board[ok]; potype<-potype[ok]; type<-type[ok]
  fe <- ifelse(board %in% names(FE_BOARD), FE_BOARD[board], POOL_FOLD_RIVER)
  fe[potype == "3bet-pot"] <- pmax(fe[potype == "3bet-pot"] - 0.04, 0.30)
  bet <- BET_FRAC * pot
  ev <- ifelse(grepl("value", type), VAL_CALL * bet, fe * pot - (1 - fe) * bet)
  data.frame(m[, cols], board, line = paste0(ifelse(tf(m$hero_flop_bet>0)|tf(m$cbet_flop),"B","x"),
             ifelse(tf(m$hero_turn_bet>0),"B","x"), "x"), potype, street = "river",
             type, fold_eq = round(fe,2), pot = round(pot,2), est_ev = round(ev,2),
             stringsAsFactors = FALSE)[grepl("value", type) | ev > 0, ]
}

# ---- detector 2: river bet too small for value -----------------------------
det_small_value <- function() {
  r <- base[!is.na(base$hero_river_bet) & num(base$hero_river_bet) > 0 &
            num(base$made_river) >= 2 & tf(base$showdown) &
            !is.na(base$hero_river_pot) & num(base$hero_river_pot) > 0, ]
  if (!nrow(r)) return(NULL)
  frac <- num(r$hero_river_bet) / num(r$hero_river_pot)
  r <- r[frac < 0.40, ]; frac <- frac[frac < 0.40]
  if (!nrow(r)) return(NULL)
  pot <- num(r$hero_river_pot)
  ev  <- (BET_FRAC - frac) * pot * VAL_CALL          # extra value a 2/3 bet would extract
  data.frame(r[, cols], board = bclass_v(r),
             line = paste0(ifelse(tf(r$hero_flop_bet>0)|tf(r$cbet_flop),"B","x"),
                           ifelse(tf(r$hero_turn_bet>0),"B","x"), "b"),
             potype = ifelse(tf(r$three_bet)|tf(r$fold_to_3bet),"3bet-pot","single-raised"),
             street = "river", type = "small_value_river", fold_eq = NA_real_,
             pot = round(pot,2), est_ev = round(ev,2), stringsAsFactors = FALSE)
}

# ---- detector 3: turn set+ checked (slow-played value) ---------------------
det_turn_monster <- function() {
  t <- base[tf(base$saw_turn) & num(base$made_turn) >= 3 &
            (is.na(base$hero_turn_bet) | num(base$hero_turn_bet) == 0) &
            !tf(base$hero_turn_aggr) &
            (is.na(base$turn_call)     | num(base$turn_call)     == 0) &
            num(base$collected) > num(base$invested), ]
  if (!nrow(t)) return(NULL)
  pot <- pmax(num(t$collected), 2 * num(t$invested), 0, na.rm = TRUE)
  ev  <- VAL_CALL * BET_FRAC * pot * 0.5            # half-weight: turn check is sometimes correct
  data.frame(t[, cols], board = bclass_v(t),
             line = paste0(ifelse(tf(t$hero_flop_bet>0)|tf(t$cbet_flop),"B","x"), "x_"),
             potype = ifelse(tf(t$three_bet)|tf(t$fold_to_3bet),"3bet-pot","single-raised"),
             street = "turn", type = "turn_monster_checked", fold_eq = NA_real_,
             pot = round(pot,2), est_ev = round(ev,2), stringsAsFactors = FALSE)
}

ops <- bind_rows(det_checked_river(), det_small_value(), det_turn_monster())
names(ops)[names(ops) == "id"] <- "hand_id"
ops <- ops[order(-ops$est_ev), ]
write.csv(ops, "coinpoker_missed_ops.csv", row.names = FALSE)

# ---- summary ----------------------------------------------------------------
cat(sprintf("\nFlagged missed opportunities: %d -> coinpoker_missed_ops.csv\n\n", nrow(ops)))
ops %>% group_by(street, type) %>%
  summarise(n = n(), est_ev = round(sum(est_ev),1), .groups = "drop") %>%
  arrange(desc(est_ev)) %>% as.data.frame() %>% print(row.names = FALSE)
cat(sprintf("\nrough EV left on table: VALUE ~$%.0f | BLUFF ~$%.0f | total ~$%.0f\n",
    sum(ops$est_ev[grepl("value|monster", ops$type)]),
    sum(ops$est_ev[grepl("bluff", ops$type)]), sum(ops$est_ev)))
cat("\n--- top 12 to review ---\n")
for (i in seq_len(min(12, nrow(ops)))) { r <- ops[i,]
  cat(sprintf("  %-7s | %s %s %s | %-13s %-21s %s ~$%.1f\n",
      r$hero_cards, r$flop, r$turn_card, r$river_card, r$board, r$type, substr(r$dt,1,10), r$est_ev))
}
