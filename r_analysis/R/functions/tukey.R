## functions/tukey.R -----------------------------------------------------------
## Tukey HSD post-hoc comparisons for the parametric path. Returns a tidy table
## of pairwise mean differences with simultaneous 95% CIs and adjusted p-values,
## tagged with the factor so Figure 6 can group comparisons.
## ---------------------------------------------------------------------------

## Tukey HSD for one factor of a fitted ANOVA. Uses emmeans (preferred, honours
## the full model) and falls back to stats::TukeyHSD on a one-way aov.
tukey_hsd <- function(anova_obj, factor, conf = 0.95) {
  d <- anova_obj$data; response <- anova_obj$table$response[1]
  if (!factor %in% anova_obj$factors) return(NULL)

  if (isTRUE(HAS$emmeans)) {
    res <- tryCatch({
      emm <- emmeans::emmeans(anova_obj$fit, specs = factor)
      as.data.frame(emmeans::contrast(emm, method = "pairwise",
                                      adjust = "tukey"))
    }, error = function(e) NULL)
    ci <- tryCatch({
      emm <- emmeans::emmeans(anova_obj$fit, specs = factor)
      as.data.frame(stats::confint(emmeans::contrast(emm, method = "pairwise",
                                                     adjust = "tukey"),
                                   level = conf))
    }, error = function(e) NULL)
    if (!is.null(res)) {
      out <- data.frame(
        factor = factor, response = response,
        comparison = as.character(res$contrast),
        mean_diff = res$estimate,
        p_adj = res$p.value, stringsAsFactors = FALSE)
      if (!is.null(ci)) {
        out$lower <- ci$lower.CL[match(out$comparison, as.character(ci$contrast))]
        out$upper <- ci$upper.CL[match(out$comparison, as.character(ci$contrast))]
      } else { out$lower <- NA; out$upper <- NA }
      return(out)
    }
  }

  ## Base-R fallback: one-way Tukey HSD.
  d2 <- d[is.finite(d[[response]]), , drop = FALSE]
  d2[[factor]] <- droplevels(as.factor(d2[[factor]]))
  if (nlevels(d2[[factor]]) < 2) return(NULL)
  fit <- stats::aov(stats::as.formula(paste(response, "~", factor)), data = d2)
  th <- as.data.frame(stats::TukeyHSD(fit, conf.level = conf)[[factor]])
  data.frame(factor = factor, response = response,
             comparison = rownames(th), mean_diff = th$diff,
             lower = th$lwr, upper = th$upr, p_adj = th[["p adj"]],
             stringsAsFactors = FALSE)
}

## Run Tukey HSD across all requested factors and stack the results.
tukey_all <- function(anova_obj, factors, conf = 0.95) {
  rows <- lapply(factors, function(f) tukey_hsd(anova_obj, f, conf))
  rows <- Filter(Negate(is.null), rows)
  if (!length(rows)) return(NULL)
  do.call(rbind, rows)
}
