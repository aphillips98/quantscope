## functions/anova.R -----------------------------------------------------------
## Factorial ANOVA for the DSE design. Fits the main-effects (optionally with
## interactions) model for one response over the configured factors, using
## Type-II sums of squares (car::Anova when available, base aov otherwise), and
## exposes the tidy table plus estimated marginal means.
## ---------------------------------------------------------------------------

## Build the model formula from the response and the factors present in the data
## (a factor with a single observed level is dropped automatically).
build_formula <- function(response, factors, data, interactions = FALSE) {
  usable <- Filter(function(f) f %in% names(data) &&
                     nlevels(droplevels(as.factor(data[[f]]))) >= 2, factors)
  if (!length(usable)) return(NULL)
  rhs <- if (interactions && length(usable) >= 2)
    paste(usable, collapse = " * ") else paste(usable, collapse = " + ")
  list(formula = stats::as.formula(paste(response, "~", rhs)), factors = usable)
}

## Fit the ANOVA and return a tidy table with F, p, partial eta^2 and omega^2.
fit_anova <- function(response, factors, data, type = 2, interactions = FALSE) {
  spec <- build_formula(response, factors, data, interactions)
  if (is.null(spec)) return(NULL)
  d <- data[is.finite(data[[response]]), , drop = FALSE]
  if (nrow(d) < length(spec$factors) + 2) return(NULL)
  fit <- stats::aov(spec$formula, data = d)

  ## ANOVA table (Type II via car when available).
  if (isTRUE(HAS$car)) {
    at <- tryCatch(as.data.frame(mute_hypothesis_warning(car::Anova(fit, type = type))),
                   error = function(e) NULL)
    if (!is.null(at)) {
      at$term <- trimws(rownames(at))
      tab <- data.frame(
        term = at$term,
        sum_sq = at[["Sum Sq"]], df = at[["Df"]],
        F_value = at[["F value"]], p_value = at[["Pr(>F)"]],
        stringsAsFactors = FALSE)
    } else tab <- .base_anova_table(fit)
  } else {
    tab <- .base_anova_table(fit)
  }
  tab <- tab[tab$term != "Residuals" & !is.na(tab$df), , drop = FALSE]

  es <- effect_sizes_from_aov(fit)
  tab$partial_eta_sq <- es$partial_eta_sq[match(tab$term, es$term)]
  tab$omega_sq       <- es$omega_sq[match(tab$term, es$term)]
  tab$response <- response
  list(fit = fit, table = tab, factors = spec$factors, data = d)
}

.base_anova_table <- function(fit) {
  a <- as.data.frame(summary(fit)[[1]])
  a$term <- trimws(rownames(a))
  data.frame(term = a$term, sum_sq = a[["Sum Sq"]], df = a[["Df"]],
             F_value = a[["F value"]], p_value = a[["Pr(>F)"]],
             stringsAsFactors = FALSE)
}

## Estimated marginal means with a confidence interval for one factor. Uses
## emmeans when available; otherwise falls back to observed group means + CI.
marginal_means <- function(anova_obj, factor, conf = 0.95) {
  d <- anova_obj$data; response <- anova_obj$table$response[1]
  if (isTRUE(HAS$emmeans)) {
    emm <- tryCatch(
      as.data.frame(emmeans::emmeans(anova_obj$fit, specs = factor,
                                     level = conf)),
      error = function(e) NULL)
    if (!is.null(emm)) {
      names(emm)[names(emm) == "emmean"]    <- "estimate"
      names(emm)[names(emm) == "lower.CL"]  <- "lower"
      names(emm)[names(emm) == "upper.CL"]  <- "upper"
      emm$factor <- factor; emm$response <- response
      emm$level <- as.character(emm[[factor]])
      return(emm[, c("factor", "level", "estimate", "lower", "upper",
                     "response")])
    }
  }
  ## Fallback: observed means + normal CI.
  g <- droplevels(as.factor(d[[factor]]))
  parts <- split(d[[response]], g)
  rows <- lapply(names(parts), function(l) {
    ci <- mean_ci(parts[[l]], conf)
    data.frame(factor = factor, level = l, estimate = ci["mean"],
               lower = ci["lower"], upper = ci["upper"], response = response,
               row.names = NULL)
  })
  do.call(rbind, rows)
}
