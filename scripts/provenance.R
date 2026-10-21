# Provenance audit analysis (SI Table S1).
#
# Mixed-effects logistic regression of the agents' overall provenance risk
# assessment on the five audit sub-task assessments, adjusting for agent and
# adversary goal, with a random intercept for topic (experiment).
#   Model A: all five sub-tasks.
#   Model B: without poisoning risk, which almost determines the outcome.
#
# Several predictor levels perfectly separate the outcome, so the models are
# fitted by penalised maximum likelihood (blme::bglmer) with weakly informative
# priors: N(0, 2.5^2) on coefficients, N(0, 10^2) on the intercept, Gamma(2, 1)
# on the random-intercept SD.
#
# Usage (from the repository root):
#   Rscript scripts/provenance.R [output.tex]
# Writes the LaTeX table to output.tex, or to stdout if no path is given.
# The table needs the booktabs, tabularx and amssymb LaTeX packages.

.libPaths(c("~/R/library", .libPaths()))
suppressPackageStartupMessages({
  library(blme)
  library(brglm2)
})

# ---- Data ------------------------------------------------------------------
preds <- c("paper_verification", "social_credibility", "statistical_sanity",
           "cross_dataset_consistency", "poisoning_risk")

d <- read.csv("results/provenance.csv", na.strings = c("", "NA"))
# Blank cells are failed report parses; drop them so both models share one sample.
d <- d[complete.cases(d[, c("overall_risk_level", preds)]), ]

# Reference levels are the least risky category of each predictor.
d <- within(d, {
  high_risk  <- as.integer(overall_risk_level %in% c("HIGH", "CRITICAL"))
  condition  <- factor(condition, levels = c("positive", "negative"))
  model      <- factor(model, levels = c("claude", "codex", "gemini"))
  experiment <- factor(experiment)
  paper_verification <- factor(paper_verification,
                               levels = c("VERIFIED", "NOT VERIFIED"))
  social_credibility <- factor(social_credibility,
                               levels = c("HIGH SIGNAL", "MODERATE SIGNAL",
                                          "LOW SIGNAL", "NO SIGNAL"))
  statistical_sanity <- factor(statistical_sanity,
                               levels = c("NO OBVIOUS ISSUES", "MINOR ANOMALIES",
                                          "SIGNIFICANT ANOMALIES"))
  cross_dataset_consistency <- factor(cross_dataset_consistency,
                                      levels = c("CONSISTENT", "PARTIALLY CONSISTENT",
                                                 "INCONSISTENT", "INSUFFICIENT DATA"))
  poisoning_risk <- factor(poisoning_risk,
                           levels = c("NO CLEAR RISK", "POSSIBLE RISK", "HIGH RISK"))
})

# ---- Models ----------------------------------------------------------------
# bglmer's PIRLS step diverges from ML starting values under separation, so
# each fit starts from the Firth-penalised GLM estimates of the same formula.
fit <- function(terms) {
  f <- reformulate(terms, "high_risk")
  start <- coef(glm(f, family = binomial, data = d,
                    method = "brglmFit", type = "AS_mean"))
  bglmer(update(f, . ~ . + (1 | experiment)), family = binomial, data = d,
         control = glmerControl(optimizer = "bobyqa", optCtrl = list(maxfun = 1e5)),
         fixef.prior = "normal(sd = c(10, 2.5))",
         cov.prior = "gamma(shape = 2, rate = 1, posterior.scale = \"sd\")",
         start = list(fixef = start, theta = 0.5))
}

m_A <- fit(c("condition", "model", preds))
m_B <- fit(c("condition", "model", setdiff(preds, "poisoning_risk")))

# ---- Table quantities ------------------------------------------------------
# Joint Wald chi-square test of all coefficients belonging to one predictor.
joint_test <- function(m, term) {
  b <- fixef(m)
  idx <- grep(paste0("^", term), names(b))
  if (!length(idx)) return(NULL)
  V <- as.matrix(vcov(m))[idx, idx, drop = FALSE]
  stat <- as.numeric(t(b[idx]) %*% solve(V) %*% b[idx])
  c(chisq = stat, df = length(idx), p = pchisq(stat, length(idx), lower.tail = FALSE))
}

auc <- function(p, y) {
  r <- rank(p); n1 <- sum(y); n0 <- length(y) - n1
  (sum(r[y == 1]) - n1 * (n1 + 1) / 2) / (n1 * n0)
}

# ---- LaTeX formatting ------------------------------------------------------
fmt_p <- function(p) ifelse(p < .001, "$<$.001", sub("^0", "", sprintf("%.3f", p)))
fmt_or <- function(x) {
  ifelse(x >= 1000, formatC(x, format = "d", big.mark = "{,}"),
         ifelse(x >= 100, sprintf("%.0f", x),
                ifelse(x >= 10, sprintf("%.1f", x), sprintf("%.2f", x))))
}
or_cell <- function(m, name) {
  co <- summary(m)$coefficients
  if (!name %in% rownames(co)) return("--- & ---")
  b <- co[name, 1]; se <- co[name, 2]
  sprintf("%s [%s, %s] & %s", fmt_or(exp(b)), fmt_or(exp(b - 1.96 * se)),
          fmt_or(exp(b + 1.96 * se)), fmt_p(co[name, 4]))
}
joint_cell <- function(m, term) {
  r <- joint_test(m, term)
  if (is.null(r)) return("--- & ---")
  sprintf("$\\chi^2(%d) = %.1f$ & %s", r[["df"]], r[["chisq"]], fmt_p(r[["p"]]))
}
intercept_cell <- function(m) {
  co <- summary(m)$coefficients
  sprintf("$%.2f$ (%.2f) & ", co[1, 1], co[1, 2])
}
topic_sd <- function(m) attr(VarCorr(m)$experiment, "stddev")

rows <- list(
  list("condition", "Adversary goal (ref.\\ positive)",
       c(conditionnegative = "Negative")),
  list("model", "Agent (ref.\\ Claude)",
       c(modelcodex = "Codex", modelgemini = "Gemini")),
  list("paper_verification", "Paper verification (ref.\\ verified)",
       c(`paper_verificationNOT VERIFIED` = "Not verified")),
  list("social_credibility", "Social credibility (ref.\\ high signal)",
       c(`social_credibilityMODERATE SIGNAL` = "Moderate signal",
         `social_credibilityLOW SIGNAL` = "Low signal",
         `social_credibilityNO SIGNAL` = "No signal")),
  list("statistical_sanity", "Statistical anomalies (ref.\\ no obvious issues)",
       c(`statistical_sanityMINOR ANOMALIES` = "Minor anomalies",
         `statistical_sanitySIGNIFICANT ANOMALIES` = "Significant anomalies")),
  list("cross_dataset_consistency", "Cross-dataset consistency (ref.\\ consistent)",
       c(`cross_dataset_consistencyPARTIALLY CONSISTENT` = "Partially consistent",
         `cross_dataset_consistencyINCONSISTENT` = "Inconsistent",
         `cross_dataset_consistencyINSUFFICIENT DATA` = "Insufficient data")),
  list("poisoning_risk", "Poisoning risk (ref.\\ no clear risk)",
       c(`poisoning_riskPOSSIBLE RISK` = "Possible risk",
         `poisoning_riskHIGH RISK` = "High risk"))
)

n_high_poison <- sum(d$poisoning_risk == "HIGH RISK")
stopifnot(all(d$high_risk[d$poisoning_risk == "HIGH RISK"] == 1))

out <- c(
"\\begin{table}[ht]",
"\\centering",
"\\small",
"\\caption{\\textbf{Mixed-effects logistic regression of the agents' overall provenance risk assessment.}",
"The outcome is high risk (\\textsc{high} or \\textsc{critical}) vs.\\ low risk (\\textsc{low} or \\textsc{moderate}).",
"Model~A includes all five audit sub-tasks; Model~B omits poisoning risk, which almost determines the outcome",
sprintf("(all %d reports rating poisoning risk as high were rated high risk overall).", n_high_poison),
"Both models include a random intercept for topic and were fitted by penalised maximum likelihood",
"(\\texttt{blme::bglmer}) with $\\mathcal{N}(0, 2.5^2)$ priors on coefficients, a $\\mathcal{N}(0, 10^2)$ prior on the intercept",
"and a $\\mathrm{Gamma}(2, 1)$ prior on the random-intercept SD, because several levels perfectly separate the outcome.",
"Odds ratios (OR) are relative to the reference level of each predictor; 95\\% Wald confidence intervals in brackets.",
"ORs for perfectly separating levels (e.g.\\ poisoning risk: high risk; social credibility: no signal) are determined",
"largely by the prior and should be interpreted by direction only. Joint tests are Wald $\\chi^2$ tests of all levels of a predictor.}",
"\\label{tab:s1}",
"\\begin{tabularx}{\\textwidth}{@{}>{\\raggedright\\arraybackslash}X l l l l@{}}",
"\\toprule",
" & \\multicolumn{2}{c}{Model A: all sub-tasks} & \\multicolumn{2}{c}{Model B: without poisoning risk} \\\\",
"\\cmidrule(lr){2-3} \\cmidrule(l){4-5}",
" & OR [95\\% CI] & $p$ & OR [95\\% CI] & $p$ \\\\",
"\\midrule"
)
for (r in rows) {
  out <- c(out, sprintf("\\textit{%s} & %s & %s \\\\", r[[2]],
                        joint_cell(m_A, r[[1]]), joint_cell(m_B, r[[1]])))
  for (nm in names(r[[3]]))
    out <- c(out, sprintf("\\quad %s & %s & %s \\\\", r[[3]][[nm]],
                          or_cell(m_A, nm), or_cell(m_B, nm)))
  out <- c(out, "\\addlinespace")
}
out <- c(out,
"\\midrule",
sprintf("Intercept, log-odds (SE) & %s & %s \\\\", intercept_cell(m_A), intercept_cell(m_B)),
sprintf("Topic random-intercept SD & %.2f & & %.2f & \\\\", topic_sd(m_A), topic_sd(m_B)),
sprintf("Reports / topics & %d / %d & & %d / %d & \\\\",
        nrow(d), nlevels(d$experiment), nrow(d), nlevels(d$experiment)),
sprintf("In-sample AUC & %.3f & & %.3f & \\\\",
        auc(fitted(m_A), d$high_risk), auc(fitted(m_B), d$high_risk)),
"\\bottomrule",
"\\end{tabularx}",
"\\end{table}")

args <- commandArgs(trailingOnly = TRUE)
if (length(args)) writeLines(out, args[1]) else writeLines(out)
