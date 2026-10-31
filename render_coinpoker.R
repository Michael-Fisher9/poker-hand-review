#!/usr/bin/env Rscript
# Build the dashboard from hands/*.txt, end to end. Run from anywhere: Rscript render_coinpoker.R
# The luck ledger (about a minute of equity calculations) is skipped with --quick.
setwd(dirname(normalizePath(sub("--file=", "",
  grep("--file=", commandArgs(FALSE), value = TRUE)[1]))))

quick <- "--quick" %in% commandArgs(TRUE)

cat("Parsing hand histories ...\n")
system2("Rscript", "parse_coinpoker.R")

# Rebuild the derived-feature layer (starting-hand class, fees, range model) first,
# so the dashboard reads a fresh coinpoker_features.csv.
cat("Building features ...\n")
system2("Rscript", "features_coinpoker.R")

cat("Finding missed opportunities ...\n")
system2("Rscript", "missed_ops.R")

cat("Allocating rakeback ...\n")
system2("Rscript", "rakeback_allocate.R")

cat("Running downswing simulator ...\n")
system2("Rscript", "downswing_sim.R")

cat("Running RNG fairness audit ...\n")
system2("Rscript", "rng_audit.R")

cat("Running counterfactual replay ...\n")
system2("Rscript", "counterfactual_replay.R")

cat("Running hand-trajectory clustering ...\n")
system2("Rscript", "hand_clusters.R")

cat("Running table ecology ...\n")
system2("Rscript", "table_ecology.R")

if (!quick) {
  cat("Building the luck ledger ...\n")
  system2("python3", "luck_ledger.py")   # standard library only
}

invisible(Sys.setlocale("LC_CTYPE", "en_US.UTF-8"))   # otherwise non-ASCII text in R strings prints as <U+2014>
rmarkdown::render("coinpoker_dashboard.Rmd", output_file = "coinpoker_dashboard.html", quiet = TRUE)
cat("\nDone -> coinpoker_dashboard.html\n")
