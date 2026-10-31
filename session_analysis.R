#!/usr/bin/env Rscript
# ---------------------------------------------------------------------------
# Session analysis + a self-annotation loop.
# 1. Detects play sessions from hand timestamps (>30-min gap = new session).
# 2. Writes coinpoker_sessions.csv with the OBJECTIVE columns pre-filled and
#    EMPTY subjective columns (sleep_hrs, energy_1to5, tilt_1to5, notes) for you
#    to annotate. Re-running MERGES: your annotations are preserved and only new
#    sessions get appended (like the opponent-study append-only stores).
# 3. Prints objective signatures (length effect, within-session drift, post-loss),
#    and — once you've annotated a few sessions — the correlation of sleep/energy/
#    tilt with results. The point: turn "I felt different" into something testable.
# Run: Rscript session_analysis.R
# ---------------------------------------------------------------------------
suppressWarnings(suppressMessages(library(dplyr)))
a <- grep("--file=", commandArgs(FALSE), value = TRUE)
if (length(a)) setwd(dirname(sub("--file=", "", a[1])))         
FEAT <- "coinpoker_features.csv"; OUT <- "coinpoker_sessions.csv"
if (!file.exists(FEAT)) system2("Rscript", "features_coinpoker.R")
tf <- function(x) { y <- x == TRUE | x == "TRUE"; y[is.na(y)] <- FALSE; y }
num <- function(x) suppressWarnings(as.numeric(x))

d <- read.csv(FEAT, stringsAsFactors = FALSE)
d <- d[!tf(d$is_bomb), ]
d$t <- as.POSIXct(d$dt, tz = "America/Chicago"); d <- d[order(d$t), ]
d$session <- cumsum(c(Inf, as.numeric(diff(d$t), units = "mins")) > 30)

# ---- objective per-session table ----
obj <- d %>% group_by(session) %>% summarise(
  session_id  = format(min(t), "%Y-%m-%d %H:%M"),
  date        = format(min(t), "%Y-%m-%d"),
  start       = format(min(t), "%H:%M"),
  hands       = n(),
  mins        = round(as.numeric(difftime(max(t), min(t), units = "mins"))),
  net         = round(sum(net), 1),
  bb100       = round(100 * mean(net_bb), 1),
  vpip        = round(100 * mean(tf(vpip))),
  wsd         = round(100 * mean(collected[tf(showdown)] > invested[tf(showdown)])),
  .groups = "drop") %>% filter(hands >= 20) %>% select(-session)

# ---- merge with existing annotations (preserve subjective columns) ----
# ended_reason directly breaks the length↔result confound: "quit_winning" / "quit_stuck"
# (chasing) / "tired" / "out_of_time" tells us WHY a session ran long.
SUBJ <- c("sleep_hrs", "energy_1to5", "tilt_1to5", "ended_reason", "notes")
if (file.exists(OUT)) {
  old <- read.csv(OUT, stringsAsFactors = FALSE)
  keep <- old[, c("session_id", intersect(SUBJ, names(old))), drop = FALSE]
  obj <- merge(obj, keep, by = "session_id", all.x = TRUE)
}
for (c in SUBJ) if (!c %in% names(obj)) obj[[c]] <- NA
obj <- obj[order(obj$session_id), ]
write.csv(obj, OUT, row.names = FALSE)
cat(sprintf("wrote %d sessions -> %s  (annotate the %s columns, then re-run)\n\n",
            nrow(obj), OUT, paste(SUBJ, collapse = "/")))

# ---- objective signatures ----
obj$lenb <- cut(obj$hands, c(0, 60, 150, 300, 1e5), labels = c("<60", "60-150", "150-300", "300+"))
cat("=== session length vs bb/100 (confounded w/ chasing — the log will disentangle) ===\n")
print(obj %>% group_by(lenb) %>% summarise(sessions = n(), median_hands = median(hands),
      bb100 = round(mean(bb100), 1), .groups = "drop") %>% as.data.frame(), row.names = FALSE)

bl <- which(num(d$net) / num(d$bb) < -20)
af <- unique(unlist(lapply(bl, function(i) { nx <- i + 1:10; nx[nx <= nrow(d) & d$session[nx] == d$session[i]] })))
cat(sprintf("\n=== post-big-loss (next 10 hands) vs baseline ===\n  baseline: VPIP %.0f%% net/hand $%+.3f | after loss: VPIP %.0f%% net/hand $%+.3f\n",
    100 * mean(tf(d$vpip)), mean(d$net), 100 * mean(tf(d$vpip[af])), mean(d$net[af])))

# ---- subjective correlations (only if annotated) ----
ann <- obj[rowSums(!is.na(obj[, SUBJ[1:3]])) > 0, ]
if (nrow(ann) >= 5) {
  cat(sprintf("\n=== subjective vs results (%d annotated sessions) ===\n", nrow(ann)))
  for (c in c("sleep_hrs", "energy_1to5", "tilt_1to5")) {
    v <- num(ann[[c]]); ok <- !is.na(v)
    if (sum(ok) >= 5) cat(sprintf("  cor(%-11s, bb/100) = %+.2f   cor(%-11s, VPIP) = %+.2f\n",
        c, cor(v[ok], ann$bb100[ok]), c, cor(v[ok], ann$vpip[ok])))
  }
} else {
  cat(sprintf("\n(annotate >=5 sessions' sleep/energy/tilt in %s to unlock subjective correlations)\n", OUT))
}
