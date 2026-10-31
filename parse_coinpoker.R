#!/usr/bin/env Rscript
# Parse CoinPoker cash hand histories (text) into a tidy per-hand CSV from Hero's view.
# Net is built from Hero's own contributions and collections, validated against the
# stack delta to the next hand at the same table. Output: coinpoker_hands.csv
suppressMessages({library(dplyr)})

# run from anywhere: Rscript parse_coinpoker.R
a <- grep("--file=", commandArgs(FALSE), value = TRUE)
if (length(a)) setwd(dirname(normalizePath(sub("--file=", "", a[1]))))

HH <- list.files("hands", pattern = "\\.txt$", full.names = TRUE)
lines <- unlist(lapply(HH, function(f) readLines(f, warn = FALSE, encoding = "UTF-8")))

# --- split into per-hand blocks ---------------------------------------------
starts <- grep("^CoinPoker Hand #", lines)
ends   <- c(starts[-1] - 1, length(lines))

num <- function(s, pat) {            # first capture group as numeric, currency-symbol safe
  m <- regmatches(s, regexec(pat, s))[[1]]
  if (length(m) >= 2) as.numeric(m[2]) else NA_real_
}

pos_label <- function(occ, btn, n) {
  if (n == 2) return(setNames(c("BTN", "BB"),
                              c(btn, occ[occ != btn])))   # heads-up: button is SB
  bi  <- which(occ == btn)
  ord <- c(occ[bi:length(occ)], occ[seq_len(bi - 1)])      # BTN, SB, BB, ..., CO
  labs <- rep(NA_character_, n)
  labs[1] <- "BTN"; if (n >= 2) labs[2] <- "SB"; if (n >= 3) labs[3] <- "BB"
  endlabs <- c("CO", "HJ", "UTG", "MP", "EP", "EP2")       # from the button backward
  rest <- if (n > 3) 4:n else integer(0)
  for (k in seq_along(rest)) labs[rest[length(rest) - k + 1]] <- endlabs[k]
  setNames(labs, ord)
}

parse_block <- function(L) {
  hdr <- L[1]
  id  <- num(hdr, "Hand #(\\d+)")
  paren <- regmatches(hdr, regexec("\\(([^)]+)\\)", hdr))[[1]][2]   # "₮0.05/₮0.10" or .../₮0.08
  stk <- as.numeric(regmatches(paren, gregexpr("[0-9.]+", paren))[[1]])
  sb  <- stk[1]; bb <- stk[2]; ante_hdr <- if (length(stk) >= 3) stk[3] else 0
  is_bomb <- grepl("BombPot", hdr)
  dt  <- regmatches(hdr, regexec("([0-9]{4}/[0-9]{2}/[0-9]{2} [0-9:]{8})", hdr))[[1]][2]
  table_id <- regmatches(L[2], regexec("Table '([^']+)'", L[2]))[[1]][2]
  n_max <- as.integer(num(L[2], "([0-9]+)-max"))
  btn   <- as.integer(num(L[2], "Seat #([0-9]+) is the button"))

  hole_i <- which(grepl("\\*\\*\\* HOLE CARDS", L))[1]
  seat_l <- grep("^Seat [0-9]+: .* in chips\\)", L[seq_len(hole_i)], value = TRUE)
  seats  <- as.integer(sub("^Seat ([0-9]+):.*", "\\1", seat_l))
  who    <- sub("^Seat [0-9]+: (\\S+) \\(.*", "\\1", seat_l)
  stacks <- as.numeric(sub(".*\\([^0-9]*([0-9.]+) in chips\\).*", "\\1", seat_l))
  hero_seat <- seats[who == "Hero"][1]
  hero_stack <- stacks[who == "Hero"][1]
  n_players <- length(seats)
  occ <- sort(seats)
  poslab <- pos_label(occ, btn, n_players)
  hero_pos <- unname(poslab[as.character(hero_seat)])
  name_pos <- setNames(unname(poslab[as.character(seats)]), who)   # player name -> position

  cards <- regmatches(L, regexec("Dealt to Hero \\[([^]]+)\\]", L))
  cards <- Filter(function(x) length(x) > 0, cards)
  hero_cards <- if (length(cards)) cards[[1]][2] else NA_character_

  # --- walk lines tracking Hero's committed chips per street ------------------
  committed <- 0; cstreet <- 0; ante <- 0; collected <- 0; returned <- 0
  street <- 0L; preflop_vpip <- FALSE; preflop_raise <- FALSE; folded_pre <- FALSE
  flop_occurred <- FALSE; turn_occurred <- FALSE; river_occurred <- FALSE
  fold_street <- NA_integer_; pf_aggr <- 0L; pf_calls <- 0L
  flop_call <- 0; turn_call <- 0; river_call <- 0   # amount Hero called facing a bet on each street
  # full pot accounting (all players) so we know the pot Hero faced on the river:
  pot_running <- 0; scommit <- numeric(0)
  flop_call_pot <- turn_call_pot <- river_pot <- NA_real_   # *_pot = pot just before Hero's call on that street
  hero_flop_bet <- NA_real_; hero_flop_pot <- NA_real_            # Hero's own bet + pot before it, per street
  hero_turn_bet <- NA_real_; hero_turn_pot <- NA_real_
  hero_river_bet <- NA_real_; hero_river_pot <- NA_real_
  # Whether Hero put in ANY aggressive action (bet/raise/all-in) per street. hero_*_bet
  # above captures only the *bets* verb, so a check-raise or river shove reads as no bet;
  # these flags catch that so "Hero checked the street" can be detected correctly downstream.
  hero_flop_aggr <- FALSE; hero_turn_aggr <- FALSE; hero_river_aggr <- FALSE
  body <- L   # walk the whole hand: antes & blinds are posted BEFORE *** HOLE CARDS ***
  for (ln in body) {
    if (grepl("\\*\\*\\* (FIRST |SECOND )?FLOP", ln)) { committed <- committed + cstreet; cstreet <- 0; street <- 1L; flop_occurred <- TRUE; scommit <- numeric(0); next }
    if (grepl("\\*\\*\\* (FIRST |SECOND )?TURN", ln))  { committed <- committed + cstreet; cstreet <- 0; street <- 2L; turn_occurred <- TRUE; scommit <- numeric(0); next }
    if (grepl("\\*\\*\\* (FIRST |SECOND )?RIVER", ln)) { committed <- committed + cstreet; cstreet <- 0; street <- 3L; river_occurred <- TRUE; scommit <- numeric(0); next }
    if (grepl("\\*\\*\\* (FIRST |SECOND )?SHOWDOWN", ln)) { committed <- committed + cstreet; cstreet <- 0; street <- 4L; scommit <- numeric(0); next }
    if (grepl("\\*\\*\\* SUMMARY", ln)) { committed <- committed + cstreet; cstreet <- 0; break }
    if (grepl("Hero collected", ln)) { collected <- collected + num(ln, "collected[^0-9]*([0-9.]+) from pot") }
    # pot accounting for EVERY player's action (tracks the running pot Hero is deciding against)
    am <- regmatches(ln, regexec("^(\\S+): (posts|bets|calls|raises|ALLIN|RETURN)", ln))[[1]]
    if (length(am) == 3) {
      nm <- am[2]; verb <- am[3]; cur <- unname(scommit[nm]); if (is.na(cur)) cur <- 0
      if (nm == "Hero" && verb %in% c("bets", "raises", "ALLIN")) {  # any Hero aggression this street
        if (street == 1L) hero_flop_aggr <- TRUE
        else if (street == 2L) hero_turn_aggr <- TRUE
        else if (street == 3L) hero_river_aggr <- TRUE
      }
      if (verb == "posts") {
        if (grepl("ante", ln)) pot_running <- pot_running + num(ln, "ante[^0-9]*([0-9.]+)")
        else { x <- num(ln, "blind[^0-9]*([0-9.]+)"); scommit[nm] <- x; pot_running <- pot_running + x }
      } else if (verb == "bets") { x <- num(ln, "bets[^0-9]*([0-9.]+)")
        if (nm == "Hero") {
          if (street == 1L && is.na(hero_flop_bet))  { hero_flop_bet  <- x; hero_flop_pot  <- pot_running }
          if (street == 2L && is.na(hero_turn_bet))  { hero_turn_bet  <- x; hero_turn_pot  <- pot_running }
          if (street == 3L && is.na(hero_river_bet)) { hero_river_bet <- x; hero_river_pot <- pot_running }
        }
        scommit[nm] <- cur + x; pot_running <- pot_running + x
      } else if (verb == "calls") { x <- num(ln, "calls[^0-9]*([0-9.]+)")
        if (nm == "Hero") {   # pot before Hero's first call on each street (incl the villain bet he faces)
          if (street == 1L && is.na(flop_call_pot)) flop_call_pot <- pot_running
          if (street == 2L && is.na(turn_call_pot)) turn_call_pot <- pot_running
          if (street == 3L && is.na(river_pot))     river_pot     <- pot_running
        }
        scommit[nm] <- cur + x; pot_running <- pot_running + x
      } else if (verb == "raises") { y <- num(ln, " to[^0-9]*([0-9.]+)"); pot_running <- pot_running + (y - cur); scommit[nm] <- y
      } else if (verb == "ALLIN") { x <- num(ln, "ALLIN[^0-9]*([0-9.]+)"); scommit[nm] <- cur + x; pot_running <- pot_running + x
      } else if (verb == "RETURN") { pot_running <- pot_running - num(ln, "RETURN[^0-9]*([0-9.]+)") }
    }
    if (grepl("^Hero: ", ln)) {
      if (grepl("posts ante", ln))             ante <- ante + num(ln, "ante[^0-9]*([0-9.]+)")
      else if (grepl("posts small blind", ln)) cstreet <- num(ln, "blind[^0-9]*([0-9.]+)")
      else if (grepl("posts big blind", ln))   cstreet <- num(ln, "blind[^0-9]*([0-9.]+)")
      else if (grepl("raises", ln))            { cstreet <- num(ln, " to[^0-9]*([0-9.]+)"); if (street == 0L) preflop_raise <- TRUE else pf_aggr <- pf_aggr + 1L }
      else if (grepl(": bets", ln))            { cstreet <- cstreet + num(ln, "bets[^0-9]*([0-9.]+)"); if (street >= 1L) pf_aggr <- pf_aggr + 1L }
      else if (grepl(": calls", ln))           { ca <- num(ln, "calls[^0-9]*([0-9.]+)"); cstreet <- cstreet + ca; if (street == 0L) preflop_vpip <- TRUE else pf_calls <- pf_calls + 1L; if (street == 1L) flop_call <- flop_call + ca; if (street == 2L) turn_call <- turn_call + ca; if (street == 3L) river_call <- river_call + ca }
      else if (grepl(": ALLIN", ln))           { cstreet <- cstreet + num(ln, "ALLIN[^0-9]*([0-9.]+)"); if (street == 0L) preflop_vpip <- TRUE else pf_aggr <- pf_aggr + 1L }
      else if (grepl(": RETURN", ln))          returned <- returned + num(ln, "RETURN[^0-9]*([0-9.]+)")
      else if (grepl(": folds", ln))           { if (is.na(fold_street)) fold_street <- street; if (street == 0L) folded_pre <- TRUE }
    }
  }
  saw_turn  <- turn_occurred  && (is.na(fold_street) || fold_street >= 2L)
  saw_river <- river_occurred && (is.na(fold_street) || fold_street >= 3L)
  if (preflop_raise) preflop_vpip <- TRUE
  total_in <- ante + committed
  net <- collected + returned - total_in
  # Hero saw the flop only if he didn't fold preflop; a real showdown shows a hand rank
  # ("... with Two Pair") in Hero's SUMMARY line (uncalled wins say only "won (X)").
  saw_flop <- flop_occurred && !folded_pre
  si <- which(grepl("\\*\\*\\* SUMMARY", L))
  hsum <- if (length(si)) grep("^Seat [0-9]+: Hero", L[si:length(L)], value = TRUE) else character(0)
  showdown <- length(hsum) > 0 && grepl(" with ", hsum[1])
  # Hero's made-hand rank at showdown, from the first "with <Rank>" in the SUMMARY line.
  sd_cat <- NA_character_
  if (showdown) {
    m <- regmatches(hsum[1], regexec(" with ([A-Za-z ]+?)(,| and|$)", hsum[1]))[[1]]
    if (length(m) >= 2) sd_cat <- trimws(m[2])
  }
  # The hand that beat (or lost to) Hero: strongest hand any OTHER player tabled at showdown.
  # When Hero loses, the winner must show, so this is what beat him.
  rkord <- c("High Card"=1,"One Pair"=2,"Two Pair"=3,"Three Of A Kind"=4,"Straight"=5,
             "Flush"=6,"Full House"=7,"Four Of A Kind"=8,"Straight Flush"=9)
  vsh <- regmatches(L, regexec("^(\\S+): shows \\[([^]]+)\\] \\(([A-Za-z ]+)\\)", L))
  vsh <- Filter(function(x) length(x) > 0 && x[2] != "Hero", vsh)
  villain_cat <- NA_character_; villain_cards <- NA_character_
  if (length(vsh)) {
    cats <- vapply(vsh, function(x) x[4], character(1))
    best <- which.max(rkord[cats])
    villain_cat <- cats[best]; villain_cards <- vsh[[best]][3]
  }

  # --- preflop action sequence (all players) for RFI / 3-bet / fold-to-3-bet --
  pf_end <- which(grepl("\\*\\*\\* (FIRST |SECOND )?(FLOP|SHOWDOWN|SUMMARY)", L))
  pf_end <- if (length(pf_end[pf_end > hole_i])) min(pf_end[pf_end > hole_i]) else length(L)
  pf <- if (!is.na(hole_i)) L[(hole_i + 1):(pf_end - 1)] else character(0)
  rc <- 0L; hero_first <- FALSE; hero_open_done <- FALSE; last_raiser_hero <- FALSE
  open_raise <- three_bet <- fold_to_3bet <- limp <- call_open <- FALSE
  rfi_opp <- vsopen_opp <- ftb_opp <- FALSE
  open_to <- NA_real_; opener_name <- NA_character_         # the first raiser Hero may 3-bet
  vsopen_pos <- NA_character_; tb_to_bb <- NA_real_; tb_ratio <- NA_real_   # opener seat + Hero 3-bet size
  for (ln in pf) {
    is_hero <- grepl("^Hero: ", ln)
    a_raise <- grepl(": raises", ln); a_call <- grepl(": calls", ln); a_fold <- grepl(": folds", ln)
    pname  <- sub("^(\\S+):.*", "\\1", ln)
    raise_to <- if (a_raise) suppressWarnings(as.numeric(sub(".*\\bto[^0-9]*([0-9.]+).*", "\\1", ln))) else NA_real_  # amount after "to" (skip currency glyph)
    if (is_hero) {
      if (!hero_first) { hero_first <- TRUE
        if (rc == 0L) rfi_opp <- TRUE else if (rc == 1L) { vsopen_opp <- TRUE; vsopen_pos <- unname(name_pos[opener_name]) } }
      if (a_raise)      { if (rc == 0L) { open_raise <- TRUE; hero_open_done <- TRUE }
                          else if (rc == 1L) { three_bet <- TRUE; tb_to_bb <- raise_to / bb
                                               tb_ratio <- if (!is.na(open_to) && open_to > 0) raise_to / open_to else NA_real_ } }
      else if (a_call)  { if (rc == 0L) limp <- TRUE else call_open <- TRUE }
      else if (a_fold)  { if (hero_open_done && rc >= 2L) fold_to_3bet <- TRUE }
    }
    if (a_raise) {
      if (rc == 0L) { open_to <- raise_to; opener_name <- pname }   # remember the opener
      rc <- rc + 1L; last_raiser_hero <- is_hero
    }
    if (hero_open_done && rc >= 2L) ftb_opp <- TRUE
  }
  hero_pf_aggr <- rc > 0L && last_raiser_hero          # Hero made the last preflop raise

  # --- flop c-bet / fold-to-c-bet ---------------------------------------------
  cbet_opp <- cbet_flop <- fcbet_opp <- fold_to_cbet <- FALSE
  flm <- which(grepl("\\*\\*\\* (FIRST |SECOND )?FLOP", L))
  if (saw_flop && length(flm)) {
    f0 <- flm[1]
    nxt <- which(grepl("\\*\\*\\*", L)); nxt <- nxt[nxt > f0]
    f1 <- if (length(nxt)) min(nxt) else length(L) + 1L
    bet_made <- FALSE; hero_acted_flop <- FALSE
    for (ln in L[(f0 + 1):(f1 - 1)]) {
      is_hero <- grepl("^Hero: ", ln)
      a_bet <- grepl(": bets", ln); a_raise <- grepl(": raises", ln); a_fold <- grepl(": folds", ln)
      if (is_hero && !hero_acted_flop) {
        hero_acted_flop <- TRUE
        if (hero_pf_aggr && !bet_made)  { cbet_opp <- TRUE; if (a_bet) cbet_flop <- TRUE }
        if (!hero_pf_aggr && bet_made)  { fcbet_opp <- TRUE; if (a_fold) fold_to_cbet <- TRUE }
      }
      if (a_bet || a_raise) bet_made <- TRUE
    }
  }

  # --- multiway vs heads-up + position proxy, from flop action order -----------
  # n_flop = distinct players who acted on the flop (2 = heads-up, 3+ = multiway).
  # hero_first_flop = Hero acts first on the flop => out of position (exact heads-up; strong proxy multiway).
  n_flop <- NA_integer_; hero_first_flop <- NA
  flm2 <- which(grepl("\\*\\*\\* (FIRST |SECOND )?FLOP", L))
  if (saw_flop && length(flm2)) {
    g0 <- flm2[1]; gn <- which(grepl("\\*\\*\\*", L)); gn <- gn[gn > g0]
    g1 <- if (length(gn)) min(gn) else length(L) + 1L
    fa <- character(0); first_a <- NA_character_
    for (ln in L[(g0 + 1):(g1 - 1)]) {
      am <- regmatches(ln, regexec("^(\\S+): (bets|checks|calls|raises|folds|ALLIN)", ln))[[1]]
      if (length(am) == 3) { if (is.na(first_a)) first_a <- am[2]; fa <- c(fa, am[2]) }
    }
    n_flop <- length(unique(fa)); hero_first_flop <- !is.na(first_a) && first_a == "Hero"
  }

  # --- board cards (single-board hands only; run-twice -> NA) ------------------
  multi_board <- any(grepl("\\*\\*\\* (FIRST|SECOND) (FLOP|TURN|RIVER)", L))
  # all collected (every player) + distinct collectors -> lets us spot equity-cashout hands later,
  # where a player's cashed equity leaves the pot but is NOT written as a "collected" line.
  coll_lines  <- grep("collected", L, value = TRUE)
  all_collected <- if (length(coll_lines)) sum(vapply(coll_lines, function(x) num(x, "collected[^0-9]*([0-9.]+)"), numeric(1))) else 0
  n_collectors  <- length(unique(sub("^(\\S+) collected.*", "\\1", coll_lines)))
  bget <- function(tag) {
    bl <- grep(paste0("^\\*\\*\\* ", tag, " \\*\\*\\*"), L, value = TRUE)
    if (multi_board || !length(bl)) return(NA_character_)
    br <- regmatches(bl[1], gregexpr("\\[([^]]+)\\]", bl[1]))[[1]]
    gsub("[][]", "", br[length(br)])     # last bracket = the new card(s) on that street
  }
  flop <- bget("FLOP"); turn_card <- bget("TURN"); river_card <- bget("RIVER")

  data.frame(
    id = id, datetime = dt, table_id = table_id, n_max = n_max, n_players = n_players,
    sb = sb, bb = bb, ante = ante_hdr, is_bomb = is_bomb,
    hero_seat = hero_seat, button_seat = btn, hero_pos = hero_pos,
    hero_cards = hero_cards, hero_stack = hero_stack,
    vpip = preflop_vpip, pfr = preflop_raise, saw_flop = saw_flop,
    showdown = showdown, invested = round(total_in, 2), collected = round(collected, 2),
    net = round(net, 2),
    rfi_opp = rfi_opp, open_raise = open_raise, vsopen_opp = vsopen_opp, three_bet = three_bet,
    vsopen_pos = vsopen_pos, tb_to_bb = round(tb_to_bb, 2), tb_ratio = round(tb_ratio, 2),
    ftb_opp = ftb_opp, fold_to_3bet = fold_to_3bet, limp = limp, call_open = call_open,
    saw_turn = saw_turn, saw_river = saw_river, hero_pf_aggr = hero_pf_aggr,
    cbet_opp = cbet_opp, cbet_flop = cbet_flop, fcbet_opp = fcbet_opp, fold_to_cbet = fold_to_cbet,
    pf_aggr = pf_aggr, pf_calls = pf_calls,
    sd_cat = sd_cat, flop_call = round(flop_call, 2), turn_call = round(turn_call, 2),
    river_call = round(river_call, 2),
    villain_cat = villain_cat, villain_cards = villain_cards,
    flop_call_pot = round(flop_call_pot, 2), turn_call_pot = round(turn_call_pot, 2),
    river_pot = round(river_pot, 2),
    hero_flop_bet = round(hero_flop_bet, 2), hero_flop_pot = round(hero_flop_pot, 2),
    hero_turn_bet = round(hero_turn_bet, 2), hero_turn_pot = round(hero_turn_pot, 2),
    hero_river_bet = round(hero_river_bet, 2), hero_river_pot = round(hero_river_pot, 2),
    hero_flop_aggr = hero_flop_aggr, hero_turn_aggr = hero_turn_aggr, hero_river_aggr = hero_river_aggr,
    n_flop = n_flop, hero_first_flop = hero_first_flop,
    all_collected = round(all_collected, 2), n_collectors = n_collectors,
    hero_collected = round(collected, 2), hero_never_folded = is.na(fold_street), multi_board = multi_board,
    flop = flop, turn_card = turn_card, river_card = river_card,
    stringsAsFactors = FALSE)
}

hands <- lapply(seq_along(starts), function(i) parse_block(lines[starts[i]:ends[i]]))
df <- bind_rows(hands)

# pot / rake / splash fee from each block's SUMMARY line.
# "Splash Fee" is a house drop deducted from the pot just like rake (pot = collected + rake +
# splash), present on ~all hands. It doesn't affect Hero's net (collected is already post-fee),
# but it IS a fee Hero pays into, so we track it and report total fees = rake + splash.
summ <- function(i) {
  blk <- lines[starts[i]:ends[i]]
  s <- grep("Total pot", blk, value = TRUE)[1]
  sf <- num(s, "Splash Fee[^0-9]*([0-9.]+)")
  c(pot = num(s, "Total pot[^0-9]*([0-9.]+)"), rake = num(s, "Rake[^0-9]*([0-9.]+)"),
    splash_fee = if (is.na(sf)) 0 else sf)
}
sm <- t(vapply(seq_along(starts), summ, numeric(3)))
df$pot <- sm[, "pot"]; df$rake <- sm[, "rake"]; df$splash_fee <- sm[, "splash_fee"]

# --- equity cashout reconciliation ------------------------------------------
# When a player cashes out their all-in equity, that money LEAVES the pot but is not written as a
# "collected" line, so pot != rake + splash + sum(collected). The shortfall = the cashed equity.
# Credit it to Hero ONLY in the unambiguous case: single board, Hero committed and never folded,
# Hero collected nothing, and exactly one villain took the runout (heads-up) -> the missing money
# must be Hero's cashout. Multiway/ambiguous cashouts are flagged but not auto-credited.
df$pot_unaccounted <- round(pmax(df$pot - df$rake - df$splash_fee - df$all_collected, 0), 2)
df$is_cashout      <- df$pot_unaccounted > 0.02
df$cashout_to_hero <- ifelse(df$is_cashout & !df$multi_board & df$hero_never_folded &
                             df$hero_collected <= 0.001 & df$n_collectors == 1, df$pot_unaccounted, 0)
df$net <- round(df$net + df$cashout_to_hero, 2)
cat(sprintf("Cashout hands: %d total (%d heads-up Hero cashouts credited: +%.2f T to net)\n",
            sum(df$is_cashout), sum(df$cashout_to_hero > 0), sum(df$cashout_to_hero)))

df$net_bb <- round(df$net / df$bb, 2)
df$dt <- as.POSIXct(df$datetime, format = "%Y/%m/%d %H:%M:%S", tz = "America/Chicago")

# --- de-duplicate overlapping exports by hand id (each CoinPoker Hand # is unique) ---
n_raw <- nrow(df)
df <- df %>% distinct(id, .keep_all = TRUE)
n_dup <- n_raw - nrow(df)

write.csv(df[order(df$dt), setdiff(names(df), "datetime")], "coinpoker_hands.csv", row.names = FALSE)

# --- trend snapshots: one row of stats per CALENDAR DAY of play ---------------
# Recomputed from scratch (over de-duplicated hands) every run, so it's inherently safe against
# overlapping uploads, multi-day uploads (each day is its own row) and empty days (just absent).
# Date is intrinsic to each hand, so trends don't depend on how the data was batched/uploaded.
# NB: as.Date(<POSIXct with an explicit tzone>) converts via UTC, which rolls evening Chicago
# hands into the next calendar day (a phantom +1 day) and desyncs these snapshot dates from the
# dashboard's cash frame (which reads dt with no tzone -> local). Force the hand's LOCAL day.
cdf <- df %>% filter(!is_bomb) %>% mutate(date = as.Date(dt, tz = "America/Chicago"))
daily <- cdf %>% group_by(date) %>% summarise(
  n = n(), vpip = round(mean(vpip) * 100, 1), pfr = round(mean(pfr) * 100, 1),
  threebet = round(sum(three_bet) / max(sum(vsopen_opp), 1) * 100, 1),
  cbet = round(sum(cbet_flop) / max(sum(cbet_opp), 1) * 100, 1),
  fold_to_cbet = round(sum(fold_to_cbet) / max(sum(fcbet_opp), 1) * 100, 1),
  af = round(sum(pf_aggr) / max(sum(pf_calls), 1), 2),
  wtsd = round(mean(showdown[saw_flop], na.rm = TRUE) * 100, 1),
  bb100 = round(sum(net_bb) / n() * 100, 1), .groups = "drop") %>% arrange(date)
write.csv(daily, "coinpoker_snapshots.csv", row.names = FALSE)
cat(sprintf("Wrote per-day trend table: %d active days -> coinpoker_snapshots.csv\n", nrow(daily)))

# --- validation: net vs stack delta to next same-table hand -----------------
# If net is correct, next stack = this stack + net + a (non-negative) auto top-up. Heavy
# table-hopping/cash-outs (common when playing deep, multi-table) reset the stack between
# "consecutive" same-table hands and show up as big residuals -- those are NOT net errors:
# on such hands Hero's |net| is tiny while the stack jumps. We separate the two below.
# NB: the export's `table_id` field is collapsed (one value spans dozens of physical tables),
# so "same table" must use the hand-id prefix: table_no = id %/% 100000 (last 5 digits are a
# per-table hand counter). Grouping by table_id here compared unrelated tables and tanked the
# exact-match rate.
v <- df %>% mutate(table_no = id %/% 100000) %>% arrange(table_no, dt) %>% group_by(table_no) %>%
  mutate(resid = lead(hero_stack) - (hero_stack + net)) %>% ungroup() %>%
  filter(!is.na(resid))
big <- v %>% filter(resid < -0.02)
cat(sprintf("Read %d files, %d hand blocks; removed %d duplicate id(s) -> %d unique hands.\n",
            length(HH), n_raw, n_dup, nrow(df)))
cat(sprintf("Stack-delta validation on %d pairs: %.1f%% exact, %.1f%% explained by net + top-up.\n",
            nrow(v), 100 * mean(abs(v$resid) < 0.02), 100 * mean(v$resid >= -0.02)))
cat(sprintf("  Of the %d unexplained (negative) residuals, %.0f%% have |net|<1 -> stack resets\n  (cash-out/table-switch), not net errors. Median |net| there: %.2f T.\n",
            nrow(big), 100 * mean(abs(big$net) < 1), median(abs(big$net))))
cat(sprintf("Total net: %.2f T | rake: %.2f T | splash fees: %.2f T | total fees: %.2f T | bb/100: %.2f\n",
            sum(df$net), sum(df$rake), sum(df$splash_fee), sum(df$rake) + sum(df$splash_fee),
            sum(df$net_bb) / nrow(df) * 100))
