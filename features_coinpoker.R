#!/usr/bin/env Rscript
# features_coinpoker.R --------------------------------------------------------
# Derived-feature layer between parse_coinpoker.R and the dashboard.
#   coinpoker_hands.csv  (raw, one row/hand)  ->  coinpoker_features.csv (enriched)
# Adds: starting-hand classification, contributed fees, and the per-position
# RANGE MODEL (was previously computed inline in the Rmd / not computed at all).
# Storing these as columns means we compute once, can inspect/sort them outside a
# render, and can sanity-check the range model directly.
#
# Run from anywhere:  Rscript features_coinpoker.R
# (render_coinpoker.R runs this first; the Rmd self-heals by re-running it.)

suppressWarnings(suppressMessages({ library(dplyr); library(stringr) }))

# setwd to this file's dir when run as a script; otherwise leave the cwd alone.
.fa <- grep("--file=", commandArgs(FALSE), value = TRUE)
if (length(.fa)) setwd(dirname(normalizePath(sub("--file=", "", .fa[1]))))

rkmap  <- setNames(2:14, c(as.character(2:9), "T", "J", "Q", "K", "A"))
rkchar <- setNames(names(rkmap), rkmap)               # 14 -> "A", etc.

# ---- starting-hand features from "Ah Ac" -----------------------------------
parse_cards <- function(s) {
  p <- str_match(s, "([2-9TJQKA])(.) ([2-9TJQKA])(.)")
  r1 <- rkmap[p[, 2]]; r2 <- rkmap[p[, 4]]
  hi <- pmax(r1, r2); lo <- pmin(r1, r2)
  suited <- p[, 3] == p[, 5]; pair <- r1 == r2
  cat <- ifelse(pair, "Pocket pair", ifelse(suited, "Suited", "Offsuit"))
  premium  <- (pair & hi >= 10) | (hi == 14 & lo == 13)        # TT+, AK
  broadway <- !pair & hi >= 10 & lo >= 10
  grp <- ifelse(premium, "Premium (TT+, AK)",
         ifelse(pair, "Other pair",
         ifelse(broadway, "Broadway",
         ifelse(suited & (hi - lo) <= 3 & lo >= 5, "Suited connector",
         ifelse(suited, "Other suited", "Other offsuit")))))
  # canonical 169-hand label: "AA" / "AKs" / "AKo"
  hand169 <- ifelse(is.na(hi), NA_character_,
              ifelse(pair, paste0(rkchar[as.character(hi)], rkchar[as.character(hi)]),
                     paste0(rkchar[as.character(hi)], rkchar[as.character(lo)],
                            ifelse(suited, "s", "o"))))
  data.frame(hi, lo, suited, pair, cat, grp, hand169, stringsAsFactors = FALSE)
}

# ---- preflop hand strength: Chen formula -----------------------------------
# Transparent, well-known, editable. Ranks all 169 hands; we then call a hand
# "in range" for a seat if its strength percentile is within that seat's opening
# %. NOTE (v1 heuristic): this is a positional OPEN/defend baseline -- it does not
# yet model facing-action (open vs flat-vs-raise vs 3-bet vs blind-defend differ).
hi_pts <- function(r) ifelse(r == 14, 10, ifelse(r == 13, 8, ifelse(r == 12, 7,
                      ifelse(r == 11, 6, r / 2))))                # A10 K8 Q7 J6, else r/2
chen_score <- function(hi, lo, suited, pair) {
  s <- hi_pts(hi)
  # pairs: x2, min 5, PLUS a +2 set-mining bump -- raw Chen badly underrates small
  # pairs (22-55 all tie at 5, level with junk) even though 6-max plays them widely.
  s <- ifelse(pair, pmax(hi_pts(hi) * 2, 5) + 2, s)
  s <- ifelse(suited & !pair, s + 2, s)                          # suited +2
  gap <- ifelse(pair, 0L, hi - lo - 1L)                          # cards between
  pen <- ifelse(gap <= 0, 0, ifelse(gap == 1, 1, ifelse(gap == 2, 2, ifelse(gap == 3, 4, 5))))
  s <- ifelse(pair, s, s - pen)
  straighty <- !pair & (hi - lo) <= 2 & hi <= 11                 # 0/1-gap, both < Q
  s <- ifelse(straighty, s + 1, s)
  ceiling(s)                                                     # Chen rounds half up
}

# Build the full 169-hand strength table -> percentile rank (0=AA strongest .. 1)
build_rank_table <- function() {
  rk <- 14:2
  rows <- list()
  for (i in seq_along(rk)) for (j in seq_along(rk)) {
    a <- rk[i]; b <- rk[j]
    if (a == b) { hi <- a; lo <- a; suited <- FALSE; pair <- TRUE;  lab <- paste0(rkchar[as.character(a)], rkchar[as.character(a)]) }
    else if (a > b) { hi <- a; lo <- b; suited <- TRUE;  pair <- FALSE; lab <- paste0(rkchar[as.character(a)], rkchar[as.character(b)], "s") }  # upper triangle = suited
    else { hi <- b; lo <- a; suited <- FALSE; pair <- FALSE; lab <- paste0(rkchar[as.character(b)], rkchar[as.character(a)], "o") }              # lower triangle = offsuit
    rows[[length(rows) + 1]] <- data.frame(hand169 = lab, score = chen_score(hi, lo, suited, pair), stringsAsFactors = FALSE)
  }
  tab <- distinct(bind_rows(rows))
  tab <- tab[order(-tab$score), ]
  # percentile by rank position (ties share the average position), normalized to (0,1]
  tab$rank_pct <- rank(-tab$score, ties.method = "average") / nrow(tab)
  tab
}

# Per-seat opening / defend width as a fraction of all hands. EDIT THESE to taste.
# Tighten UTG -> wide BTN; blinds get a wide "defend" allowance (they play far more
# than they'd open, so judging them by an RFI chart would over-flag them as loose).
POS_OPEN <- c(EP2 = 0.13, EP = 0.14, UTG = 0.15, MP = 0.20, HJ = 0.20,
              CO = 0.27, BTN = 0.46, SB = 0.42, BB = 0.58)

# ============================================================================
# POSTFLOP HAND-STRENGTH + DRAW ENGINE
# We parse all 7 cards (hole + 5 board) but never EVALUATED them postflop -- the
# only board logic lived inline in the Rmd as a crude 3-bucket flush/straight
# check. This is the real evaluator: it ranks Hero's made hand at each street and
# decomposes what a bet is "backed by" (made hand / draw / overcards / air), which
# is what the bluff taxonomy and the leak ledger both need.
#
# Key choice: Hero's category is the best 5-card hand that USES >=1 hole card.
# That stops a paired/straightened/flushed BOARD from masquerading as Hero having
# a hand (72o on KK5 is air, not "one pair"). Categories 0..8 below.
# ----------------------------------------------------------------------------
csplit <- function(s) if (is.na(s) || s == "") character(0) else str_extract_all(s, "[2-9TJQKA][cdhs]")[[1]]
crk <- function(c) unname(rkmap[substr(c, 1, 1)])
csu <- function(c) substr(c, 2, 2)
CATLAB <- c("air", "pair", "two pair", "trips", "straight", "flush", "full house", "quads", "straight flush")

# best category for an exactly-5-card hand
eval5 <- function(rk, su) {
  fl <- length(unique(su)) == 1
  ur <- unique(rk); if (14 %in% ur) ur <- c(ur, 1)
  st <- FALSE
  for (lo in 10:1) { if (all(lo:(lo + 4) %in% ur)) { st <- TRUE; break } }
  tb <- sort(table(rk), decreasing = TRUE)
  m1 <- tb[1]; m2 <- if (length(tb) >= 2) tb[2] else 0
  if (st && fl) return(8L)
  if (m1 == 4) return(7L)
  if (m1 == 3 && m2 >= 2) return(6L)
  if (fl) return(5L)
  if (st) return(4L)
  if (m1 == 3) return(3L)
  if (m1 == 2 && m2 == 2) return(2L)
  if (m1 == 2) return(1L)
  0L
}

# Hero's best made category using >=1 hole card, given >=5 total cards.
hero_cat <- function(hole, board) {
  cards <- c(hole, board); n <- length(cards)
  if (n < 5 || length(hole) < 1) return(NA_integer_)
  rk <- crk(cards); su <- csu(cards)
  hole_pos <- seq_along(hole)
  idx <- combn(n, 5); best <- 0L
  for (k in seq_len(ncol(idx))) {
    sel <- idx[, k]
    if (!any(sel %in% hole_pos)) next            # must use a hole card
    c5 <- eval5(rk[sel], su[sel]); if (c5 > best) best <- c5
  }
  best
}

# Draw / overcard decomposition at a street with cards to come (flop/turn).
# fd = 4-flush incl a hole card; sdraw = "oesd"(>=2 completing ranks)/"gut"(1)/"none";
# overs = hole cards strictly above the top board rank (live overcards).
draw_info <- function(hole, board) {
  all <- c(hole, board)
  rk <- crk(all); su <- csu(all)
  hsu <- csu(hole); hrk <- crk(hole); brk <- crk(board)
  fd <- any(vapply(c("c", "d", "h", "s"), function(s) sum(su == s) == 4 && any(hsu == s), logical(1)))
  present  <- unique(c(rk,  if (14 %in% rk)  1 else integer(0)))
  hpresent <- unique(c(hrk, if (14 %in% hrk) 1 else integer(0)))
  comp <- integer(0)
  for (r in 1:14) {
    if (r %in% present) next
    pr2 <- c(present, r)
    for (lo in 1:10) { w <- lo:(lo + 4); if (all(w %in% pr2) && r %in% w && any(w %in% hpresent)) { comp <- c(comp, r); break } }
  }
  sdraw <- if (length(unique(comp)) >= 2) "oesd" else if (length(comp) == 1) "gut" else "none"
  overs <- if (length(brk)) sum(hrk > max(brk)) else 0L
  list(fd = fd, sdraw = sdraw, overs = as.integer(overs))
}

# What a bluff (no made hand, cat 0) is backed by, given draw info + street.
# River has no cards to come -> "ace-high" if an overcard-equivalent, else "air".
backing_of <- function(made, fd, sdraw, overs, is_river) {
  if (is.na(made) || made >= 1) return(NA_character_)   # has a pair+ -> not a bluff
  if (!is_river) {
    if (fd && sdraw != "none") return("combo draw")
    if (fd) return("flush draw")
    if (sdraw == "oesd") return("open-ender")
    if (sdraw == "gut") return("gutshot")
    if (overs >= 2) return("two overcards")
    if (overs == 1) return("one overcard")
    return("air")
  }
  if (overs >= 1) return("ace/over-high") else return("air")
}

# Per-hand postflop features for every hand that saw a flop. Returns a frame keyed
# by id; the rest of the table left-joins to it (NA where no flop was seen).
postflop_features <- function(h) {
  sf <- which(h$saw_flop == 1 & !is.na(h$flop) & nchar(h$hero_cards) >= 4)
  n <- length(sf)
  out <- data.frame(id = h$id[sf],
    made_flop = NA_integer_, made_turn = NA_integer_, made_river = NA_integer_,
    fl_fd = FALSE, fl_sdraw = "none", fl_overs = 0L,
    tn_fd = FALSE, tn_sdraw = "none", tn_overs = 0L,
    on_draw = FALSE, hit_draw = FALSE,
    flop_betpot = NA_real_, turn_betpot = NA_real_, river_betpot = NA_real_,
    flop_bluff = FALSE, turn_bluff = FALSE, river_bluff = FALSE,
    flop_backing = NA_character_, turn_backing = NA_character_, river_backing = NA_character_,
    vagg_before_turn = FALSE, vagg_before_river = FALSE,
    stringsAsFactors = FALSE)
  for (j in seq_len(n)) {
    i <- sf[j]
    hole <- csplit(h$hero_cards[i]); fl <- csplit(h$flop[i])
    tn <- csplit(h$turn_card[i]); rv <- csplit(h$river_card[i])
    if (length(hole) < 2 || length(fl) < 3) next
    fb <- c(fl); tb <- c(fl, tn); full <- c(fl, tn, rv)
    mf <- hero_cat(hole, fb)
    mt <- if (length(tn)) hero_cat(hole, tb) else NA_integer_
    mr <- if (length(rv)) hero_cat(hole, full) else NA_integer_
    out$made_flop[j] <- mf; out$made_turn[j] <- mt; out$made_river[j] <- mr
    df <- draw_info(hole, fb)
    out$fl_fd[j] <- df$fd; out$fl_sdraw[j] <- df$sdraw; out$fl_overs[j] <- df$overs
    dt <- if (length(tn)) draw_info(hole, tb) else list(fd = FALSE, sdraw = "none", overs = 0L)
    out$tn_fd[j] <- dt$fd; out$tn_sdraw[j] <- dt$sdraw; out$tn_overs[j] <- dt$overs
    # draw that wasn't already a made straight/flush on the flop, and whether it got there
    made_fl_sf <- !is.na(mf) && mf >= 4
    drew <- (df$fd || df$sdraw != "none" || (length(tn) > 0 && (dt$fd || dt$sdraw != "none"))) && !made_fl_sf
    out$on_draw[j] <- drew
    out$hit_draw[j] <- drew && !is.na(mr) && mr >= 4
    # bet-size buckets (bet / pot at that street)
    if (!is.na(h$hero_flop_bet[i])  && h$hero_flop_bet[i]  > 0 && !is.na(h$hero_flop_pot[i])  && h$hero_flop_pot[i]  > 0) out$flop_betpot[j]  <- round(h$hero_flop_bet[i]  / h$hero_flop_pot[i], 3)
    if (!is.na(h$hero_turn_bet[i])  && h$hero_turn_bet[i]  > 0 && !is.na(h$hero_turn_pot[i])  && h$hero_turn_pot[i]  > 0) out$turn_betpot[j]  <- round(h$hero_turn_bet[i]  / h$hero_turn_pot[i], 3)
    if (!is.na(h$hero_river_bet[i]) && h$hero_river_bet[i] > 0 && !is.na(h$hero_river_pot[i]) && h$hero_river_pot[i] > 0) out$river_betpot[j] <- round(h$hero_river_bet[i] / h$hero_river_pot[i], 3)
    # bluff = aggressive bet with no made hand (cat 0) at that street
    fbet <- !is.na(h$hero_flop_bet[i])  && h$hero_flop_bet[i]  > 0
    tbet <- !is.na(h$hero_turn_bet[i])  && h$hero_turn_bet[i]  > 0
    rbet <- !is.na(h$hero_river_bet[i]) && h$hero_river_bet[i] > 0
    out$flop_bluff[j]  <- fbet && !is.na(mf) && mf == 0
    out$turn_bluff[j]  <- tbet && !is.na(mt) && mt == 0
    out$river_bluff[j] <- rbet && !is.na(mr) && mr == 0
    out$flop_backing[j]  <- if (out$flop_bluff[j])  backing_of(mf, df$fd, df$sdraw, df$overs, FALSE) else NA_character_
    out$turn_backing[j]  <- if (out$turn_bluff[j])  backing_of(mt, dt$fd, dt$sdraw, dt$overs, FALSE) else NA_character_
    out$river_backing[j] <- if (out$river_bluff[j]) backing_of(mr, FALSE, "none", as.integer(sum(crk(hole) > 11)), TRUE) else NA_character_
    # villain aggression on an earlier street (proxy: Hero faced/called a bet then)
    fc <- !is.na(h$flop_call[i]) && h$flop_call[i] > 0
    tc <- !is.na(h$turn_call[i]) && h$turn_call[i] > 0
    out$vagg_before_turn[j]  <- fc
    out$vagg_before_river[j] <- fc || tc
  }
  out
}

add_features <- function(h) {
  h <- cbind(h, parse_cards(h$hero_cards))
  if (is.null(h$splash_fee)) h$splash_fee <- 0
  h$fee_share   <- pmin(h$invested / pmax(h$pot, 0.01), 1)
  h$hero_rake   <- h$rake       * h$fee_share
  h$hero_splash <- h$splash_fee * h$fee_share
  h$fees        <- h$hero_rake + h$hero_splash

  rt <- build_rank_table()
  h$hand_rank_pct <- rt$rank_pct[match(h$hand169, rt$hand169)]
  h$pos_open_pct  <- unname(POS_OPEN[as.character(h$hero_pos)])
  h$in_open_range <- !is.na(h$hand_rank_pct) & !is.na(h$pos_open_pct) &
                     h$hand_rank_pct <= h$pos_open_pct
  # range_dir: how each hand relates to the seat's baseline range.
  #   loose  = voluntarily played a hand OUTSIDE the range (inflates VPIP, the leak)
  #   passed = folded an in-range hand when first-in/unopened (too tight -> the BTN steal leak)
  #   in     = voluntarily played an in-range hand (standard)
  #   NA     = folded out-of-range, or a facing-action fold we don't judge in v1
  vp <- h$vpip == 1
  h$range_dir <- ifelse(vp & !h$in_open_range, "loose",
                 ifelse(!vp & h$rfi_opp == 1 & h$in_open_range, "passed",
                 ifelse(vp & h$in_open_range, "in", NA_character_)))

  # ---- postflop engine (made hand / draws / bluff backing), joined by id -----
  # match-based join keeps h's row order exactly (merge would reorder).
  pf <- postflop_features(h)
  m  <- match(h$id, pf$id)
  for (col in setdiff(names(pf), "id")) h[[col]] <- pf[[col]][m]

  # ---- leak tags (per-hand hypotheses; see DATA_DICTIONARY section 8) ---------
  z <- function(x) !is.na(x) & x          # logical that treats NA as FALSE
  sd1   <- h$sd_cat %in% c("One Pair", "High Card")
  h$lk_loose_entry   <- h$range_dir %in% "loose"
  h$lk_skipped_steal <- h$range_dir %in% "passed"
  # "light 3-bet" CORRECTED (review 2026-06-21): old version tagged EVERY 3-bet vs
  # UTG/CO (112/120 in-range, 29 premiums) and wrongly drove the loss story. A *light*
  # 3-bet must be (a) out of our own opening range AND (b) vs a genuinely tight/early
  # opener (CO is ~27% wide -> dropped). On this sample the corrected set is ~14 hands,
  # net POSITIVE -> NOT a leak, so it is excluded from the ledger & primary attribution.
  tight_open         <- c("EP2", "EP", "UTG", "MP", "HJ")
  h$lk_light_3bet    <- z(h$three_bet == 1) & !z(h$in_open_range) & h$vsopen_pos %in% tight_open
  h$lk_paid_river    <- z(h$river_call > 0) & sd1
  h$lk_busted_sd     <- z(h$showdown == 1) & z(h$on_draw) & !z(h$hit_draw) & sd1
  no_hero_bet        <- !z(h$hero_flop_bet > 0) & !z(h$hero_turn_bet > 0) & !z(h$hero_river_bet > 0)
  # loose_passive requires actually seeing a flop IP (review 2026-06-21): hero_first_flop
  # is NA with no flop, and !z(NA)=TRUE wrongly tagged 122/179 no-flop hands as "IP passive".
  h$lk_loose_passive <- h$range_dir %in% "loose" & z(h$saw_flop == 1) &
                        !z(h$hero_first_flop == 1) & no_hero_bet
  # under-bluff isn't a realized-loss leak per hand; tracked separately as a count
  h$lk_air_bet       <- z(h$flop_bluff) | z(h$turn_bluff) | z(h$river_bluff)

  # ---- primary attribution: assign each LOSING hand its single dominant leak --
  # Priority = most proximal to where the chips were lost (river call > busted draw
  # taken to showdown > passive loose play > loose entry). skipped_steal is opportunity
  # cost (folds, ~no realized loss) so it is NOT in the loss waterfall.
  loss <- z(h$net < 0)
  # light_3bet excluded: corrected def is ~breakeven, not a loss driver (see above).
  prio <- list(
    c("paid_river",    "lk_paid_river"),
    c("busted_sd",     "lk_busted_sd"),
    c("loose_passive", "lk_loose_passive"),
    c("loose_entry",   "lk_loose_entry"))
  h$primary_leak <- NA_character_
  for (p in prio) {
    take <- loss & is.na(h$primary_leak) & z(h[[p[2]]])
    h$primary_leak[take] <- p[1]
  }

  # ---- WIN attribution: where each WINNING hand's chips came from --------------
  # Unlike leaks, winning hands PARTITION cleanly (every net>0 hand gets exactly one
  # source) so this sums to 100% of winnings. The value is the MIX: repeatable skill
  # (fold equity, value betting) vs soft-game/variance (villains paying you, draws in).
  # made_final = best made category at the furthest street reached (handles all-ins
  # that went to showdown before the river).
  h$made_final <- ifelse(!is.na(h$made_river), h$made_river,
                  ifelse(!is.na(h$made_turn),  h$made_turn,  h$made_flop))
  won  <- z(h$net > 0)
  sd   <- z(h$showdown == 1)
  aggr <- z(h$hero_flop_bet > 0) | z(h$hero_turn_bet > 0) | z(h$hero_river_bet > 0) | z(h$pfr == 1)
  h$win_source <- NA_character_
  h$win_source[won & sd & z(h$made_final >= 4)]            <- "big_hand"        # straight/flush+
  h$win_source[won & sd & h$made_final %in% c(2, 3)]       <- "strong_made"     # two pair / trips / set
  h$win_source[won & sd & z(h$made_final == 1)]            <- "one_pair"        # top-pair-type value
  h$win_source[won & sd & z(h$made_final == 0)]            <- "showdown_nopair" # ace-high / villain mucked worse
  h$win_source[won & is.na(h$win_source) & aggr]           <- "fold_equity"     # won with no showdown, by betting
  h$win_source[won & is.na(h$win_source)]                  <- "preflop_other"   # won uncontested / residual

  # ---- train / test split ------------------------------------------------------
  # Chronological holdout: the most recent days are the TEST set (~15% of hands), the
  # rest is TRAIN/discovery. Fit & tune leak/EV definitions on train; confirm on test.
  # NOTE: descriptive dashboard stats use ALL hands -- this split governs only the
  # definition-fitting / model-eval layer. Split on a day boundary (not random hands)
  # so correlated within-session hands don't leak across the split.
  days <- sort(unique(as.Date(h$dt)))
  share <- cumsum(table(factor(as.Date(h$dt), levels = days))) / nrow(h)
  TEST_CUTOFF <- days[which(share >= 0.85)[1] + 1]          # first day after 85% of hands
  if (is.na(TEST_CUTOFF)) TEST_CUTOFF <- max(days)
  h$split <- ifelse(as.Date(h$dt) >= TEST_CUTOFF, "test", "train")
  h
}

# ============================================================================
# VALUE ATTRIBUTION -- TIER 1 (objective, immediate-odds, per decision)
# Result attribution asks "where did the money land?"; this asks "was the decision
# +EV at the price, regardless of the runout?" -- so a losing draw call at a great
# price scores GOOD and a winning bet that needed an impossible fold scores BAD.
# Two objective decision types (no villain range needed):
#   draw_call  : facing a bet on a DRAW -> required equity (pot odds) vs draw equity
#   bluff/semibluff bet : Hero bets with no made hand -> breakeven fold% (with the
#                          draw equity as a backstop that lowers the bar)
# We deliberately store the THEORETICAL ev, never the realized net -- splitting a
# hand's result across its decisions is exactly the result-attribution trap.
# Made-hand river bluff-catches need villain range -> deferred to Tier 3.
# ----------------------------------------------------------------------------
draw_outs <- function(fd, sdraw) {
  fl <- ifelse(fd, 9L, 0L)
  st <- ifelse(sdraw == "oesd", 8L, ifelse(sdraw == "gut", 4L, 0L))
  ifelse(fd & st > 0, fl + st - 2L, fl + st)   # combo: ~2 shared completing cards
}

build_decisions <- function(h) {
  z <- function(x) !is.na(x) & x
  # ---- draw calls (flop one card to the turn = 47 unseen; turn->river = 46) ---
  # Draw-call value: we do NOT bracket rule-of-2/rule-of-4 (rule-of-4 is not a true
  # ceiling -- implied odds live above it, so "-EV at rule-of-4" wouldn't mean "mistake").
  # The objective quantity for a draw is the IMPLIED-ODDS BREAKEVEN: given the price and
  # one-card equity, how much MORE must you win when you hit to make the call +EV.
  #   forward EV (one card, terminal):  win -> +P,  lose -> -C
  #   immediate breakeven equity:       req = C/(P+C)
  #   priced_now (no implied odds needed) when eq >= req
  #   else solve eq*(P + X) - (1-eq)*C = 0  ->  X = (1-eq)*C/eq - P  (extra $ when hit)
  # req_implied_x = X / C expresses it as a multiple of the call ("win >= 2.3x your call
  # in later bets"). This is conservative: it ignores free-river equity and busted-draw
  # fold equity, both of which only LOWER the real bar. We attach hit/net so the dashboard
  # can calibrate the bar against what actually got extracted when the draw hit.
  mk_call <- function(street, call, pot, fd, sdraw, unseen) {
    outs <- draw_outs(fd, sdraw)
    sel  <- z(call > 0) & !is.na(pot) & z(outs > 0)
    if (!any(sel)) return(NULL)
    C  <- call[sel]; P <- pot[sel]
    eq  <- outs[sel] / unseen
    req <- C / (P + C)
    ev  <- (eq - req) * (P + C)
    x   <- (1 - eq) * C / eq - P
    data.frame(id = h$id[sel], split = h$split[sel], street = street, decision = "draw_call",
               size = round(C, 2), pot_before = round(P, 2), outs = outs[sel],
               equity = round(eq, 3), req_equity = round(req, 3),
               ev = round(ev, 2), good = eq >= req,
               req_implied = round(x, 2), req_implied_x = round(x / C, 2),
               hit = z(h$hit_draw[sel]), net = round(h$net[sel], 2),
               stringsAsFactors = FALSE)
  }
  # ---- bluff / semibluff bets: breakeven fold% (semibluff equity lowers it) ----
  mk_bet <- function(street, bet, pot, is_bluff, fd, sdraw, unseen) {
    sel <- z(bet > 0) & !is.na(pot) & z(is_bluff)
    if (!any(sel)) return(NULL)
    b <- bet[sel]; P <- pot[sel]
    outs <- if (is.null(unseen)) rep(0L, length(b)) else draw_outs(fd, sdraw)[sel]
    eq <- if (is.null(unseen)) 0 else outs / unseen           # equity when called (river: 0)
    W  <- eq * (P + 2 * b) - b                                # EV when called
    f_be <- (b - eq * (P + 2 * b)) / (P + b - eq * (P + 2 * b))   # = -W/(P-W); pure bluff -> b/(P+b)
    data.frame(id = h$id[sel], split = h$split[sel], street = street,
               decision = ifelse(outs > 0, "semibluff_bet", "bluff_bet"),
               size = round(b, 2), pot_before = round(P, 2), outs = outs,
               eq_when_called = round(eq, 3),
               breakeven_fold = round(pmin(pmax(f_be, 0), 1), 3),
               stringsAsFactors = FALSE)
  }
  calls <- rbind(
    mk_call("flop", h$flop_call, h$flop_call_pot, h$fl_fd, h$fl_sdraw, 47),
    mk_call("turn", h$turn_call, h$turn_call_pot, h$tn_fd, h$tn_sdraw, 46))
  bets <- rbind(
    mk_bet("flop", h$hero_flop_bet,  h$hero_flop_pot,  h$flop_bluff,  h$fl_fd, h$fl_sdraw, 47),
    mk_bet("turn", h$hero_turn_bet,  h$hero_turn_pot,  h$turn_bluff,  h$tn_fd, h$tn_sdraw, 46),
    mk_bet("river", h$hero_river_bet, h$hero_river_pot, h$river_bluff, FALSE,   "none",     NULL))
  list(calls = calls, bets = bets)
}

# ---- runner ----------------------------------------------------------------
if (!interactive()) {
  in_csv  <- "coinpoker_hands.csv"
  out_csv <- "coinpoker_features.csv"
  h <- read.csv(in_csv, stringsAsFactors = FALSE)
  h <- add_features(h)
  write.csv(h, out_csv, row.names = FALSE)   # default na="NA" matches the parser's CSV
  cash <- h[h$is_bomb == FALSE | h$is_bomb == "False" | h$is_bomb == 0, , drop = FALSE]
  cat(sprintf("features: %d hands -> %s (%d cols)\n", nrow(h), out_csv, ncol(h)))
  cat("range_dir (cash hands):\n"); print(table(cash$range_dir, useNA = "ifany"))
  cat(sprintf("in_open_range among voluntary cash hands: %.1f%%\n",
              100 * mean(cash$in_open_range[cash$vpip == 1], na.rm = TRUE)))

  # ---- validate the evaluator against the parser's showdown category ----------
  # sd_cat is Hero's SHOWN hand (standard 7-card, can play the board); made_river
  # requires a hole card. They should agree on most non-board-play hands.
  sdmap <- c("High Card" = 0, "One Pair" = 1, "Two Pair" = 2, "Three Of A Kind" = 3,
             "Straight" = 4, "Flush" = 5, "Full House" = 6, "Four Of A Kind" = 7)
  v <- cash[cash$showdown == 1 & !is.na(cash$made_river) & cash$sd_cat %in% names(sdmap), ]
  if (nrow(v)) {
    agree <- mean(v$made_river == sdmap[v$sd_cat])
    under <- mean(v$made_river <  sdmap[v$sd_cat])   # we say weaker -> board played it
    cat(sprintf("\nevaluator vs sd_cat (%d showdowns): %.1f%% exact, %.1f%% we-rank-lower (board-play discount)\n",
                nrow(v), 100 * agree, 100 * under))
  }
  tf <- function(x) !is.na(x) & x
  cat("\nbluff backing (river bets with no made hand):\n")
  print(table(cash$river_backing[tf(cash$river_bluff)], useNA = "no"))
  cat("\nbluff backing (flop bets with no made hand):\n")
  print(table(cash$flop_backing[tf(cash$flop_bluff)], useNA = "no"))
  cat("\nleak tags (cash, count | net):\n")
  for (lk in c("lk_loose_entry","lk_skipped_steal","lk_light_3bet","lk_paid_river","lk_busted_sd","lk_loose_passive","lk_air_bet")) {
    sel <- tf(cash[[lk]])
    cat(sprintf("  %-18s n=%-5d net=%+9.2f\n", lk, sum(sel), sum(cash$net[sel], na.rm = TRUE)))
  }
  cat("\nprimary_leak (losing cash hands, count | net):\n")
  print(tapply(cash$net, cash$primary_leak, function(x) sprintf("n=%d net=%.0f", length(x), sum(x))))
  cat("\nwin_source (winning cash hands, count | net):\n")
  print(tapply(cash$net, cash$win_source, function(x) sprintf("n=%d net=%.0f", length(x), sum(x))))
  cat(sprintf("total winnings: %.0f | total losses: %.0f | net: %.0f\n",
              sum(cash$net[cash$net > 0]), sum(cash$net[cash$net < 0]), sum(cash$net)))

  # ---- value attribution Tier 1: per-decision objective EV --------------------
  dec <- build_decisions(cash)
  dec_csv <- "coinpoker_decisions.csv"
  schema <- c("id","split","street","decision","size","pot_before","outs","equity","req_equity",
              "ev","good","req_implied","req_implied_x","hit","net","breakeven_fold","eq_when_called")
  allcall <- transform(dec$calls, breakeven_fold = NA_real_, eq_when_called = NA_real_)
  allbet  <- transform(dec$bets, equity = dec$bets$eq_when_called, req_equity = NA_real_,
                       ev = NA_real_, good = NA, req_implied = NA_real_, req_implied_x = NA_real_,
                       hit = NA, net = NA_real_)
  combined <- rbind(allcall[, schema], allbet[, schema])
  write.csv(combined, dec_csv, row.names = FALSE)
  cat(sprintf("\nvalue attribution: %d decisions -> %s\n", nrow(combined), dec_csv))
  for (sp in c("train", "test")) {
    dc <- dec$calls[dec$calls$split == sp, ]
    if (nrow(dc)) {
      need <- dc[!dc$good, ]
      hd <- dc[!duplicated(dc$id), ]   # hand-level for realized economics
      cat(sprintf("  [%s] draw calls n=%d  priced-now %.0f%%  | need implied odds: median %.1fx the call (range %.1f-%.1f)\n",
          sp, nrow(dc), 100 * mean(dc$good),
          median(need$req_implied_x), quantile(need$req_implied_x, .25), quantile(need$req_implied_x, .75)))
      cat(sprintf("           realized: hit %.0f%% (avg one-card eq %.0f%%) | net when hit %+.2f, when miss %+.2f, all %+.2f\n",
          100 * mean(hd$hit), 100 * mean(dc$equity),
          mean(hd$net[hd$hit]), mean(hd$net[!hd$hit]), sum(hd$net)))
    }
    db <- dec$bets[dec$bets$split == sp, ]
    if (nrow(db)) cat(sprintf("  [%s] bluff/semibluff bets n=%d  median breakeven-fold %.0f%%  (semibluffs %d)\n",
        sp, nrow(db), 100 * median(db$breakeven_fold), sum(db$decision == "semibluff_bet")))
  }
}
