## functions/statistics.R ------------------------------------------------------
## Assumption checks, effect sizes, confidence intervals and non-parametric
## fallbacks. All functions degrade to base-R implementations when the optional
## packages (car, effectsize, FSA) are unavailable.
## ---------------------------------------------------------------------------

## ---- Assumptions ----------------------------------------------------------

## Shapiro-Wilk normality on model residuals (capped at 5000 obs -- the test's
## valid range). Returns a one-row data.frame.
shapiro_check <- function(residuals) {
  r <- residuals[is.finite(residuals)]
  if (length(r) < 3)
    return(data.frame(test = "Shapiro-Wilk", statistic = NA_real_, p_value = NA_real_))
  if (length(r) > 5000) r <- sample(r, 5000)
  s <- stats::shapiro.test(r)
  data.frame(test = "Shapiro-Wilk", statistic = unname(s$statistic),
             p_value = s$p.value)
}

## Levene's test (median-centred / Brown-Forsythe). Uses car when present,
## otherwise a base-R equivalent.
levene_check <- function(y, g) {
  ok <- is.finite(y) & !is.na(g)
  y <- y[ok]; g <- droplevels(as.factor(g[ok]))
  if (nlevels(g) < 2 || length(y) < nlevels(g) + 1)
    return(data.frame(test = "Levene", statistic = NA_real_, df1 = NA, df2 = NA,
                      p_value = NA_real_))
  if (isTRUE(HAS$car)) {
    lt <- car::leveneTest(y ~ g, center = median)
    return(data.frame(test = "Levene", statistic = lt$`F value`[1],
                      df1 = lt$Df[1], df2 = lt$Df[2], p_value = lt$`Pr(>F)`[1]))
  }
  med <- tapply(y, g, median)
  z <- abs(y - med[as.character(g)])
  a <- summary(stats::aov(z ~ g))[[1]]
  data.frame(test = "Levene", statistic = a[["F value"]][1], df1 = a[["Df"]][1],
             df2 = a[["Df"]][2], p_value = a[["Pr(>F)"]][1])
}

## Combined verdict for one response: normal AND homoscedastic -> parametric.
assumption_verdict <- function(y, g, residuals, alpha = 0.05) {
  sw <- shapiro_check(residuals)
  lv <- levene_check(y, g)
  normal <- is.na(sw$p_value) || sw$p_value >= alpha
  homosc <- is.na(lv$p_value) || lv$p_value >= alpha
  list(shapiro = sw, levene = lv,
       normal = normal, homoscedastic = homosc,
       use_parametric = normal && homosc)
}

## ---- Effect sizes ---------------------------------------------------------

## Partial eta-squared and omega-squared from an ANOVA table (base-R aov object
## or car::Anova). Returns one row per model term.
effect_sizes_from_aov <- function(aov_fit) {
  if (isTRUE(HAS$effectsize)) {
    pes <- tryCatch(effectsize::eta_squared(aov_fit, partial = TRUE),
                    error = function(e) NULL)
    oms <- tryCatch(effectsize::omega_squared(aov_fit, partial = TRUE),
                    error = function(e) NULL)
    if (!is.null(pes)) {
      df <- data.frame(term = pes$Parameter,
                       partial_eta_sq = pes$Eta2_partial,
                       stringsAsFactors = FALSE)
      if (!is.null(oms))
        df$omega_sq <- oms$Omega2_partial[match(df$term, oms$Parameter)]
      return(df)
    }
  }
  ## Base-R fallback from the ANOVA sums of squares.
  tab <- as.data.frame(summary(aov_fit)[[1]])
  tab$term <- trimws(rownames(tab))
  ss <- tab[["Sum Sq"]]; dfn <- tab[["Df"]]
  res_i <- which(tab$term == "Residuals")
  ss_res <- ss[res_i]; df_res <- dfn[res_i]
  ms_res <- ss_res / df_res
  terms <- tab[-res_i, , drop = FALSE]
  data.frame(
    term = terms$term,
    partial_eta_sq = terms[["Sum Sq"]] / (terms[["Sum Sq"]] + ss_res),
    omega_sq = (terms[["Sum Sq"]] - terms[["Df"]] * ms_res) /
               (sum(ss) + ms_res),
    stringsAsFactors = FALSE
  )
}

## ---- Confidence intervals -------------------------------------------------

## Normal-theory CI for a group mean.
mean_ci <- function(x, conf = 0.95) {
  x <- x[is.finite(x)]; n <- length(x)
  if (n < 2) return(c(mean = if (n) mean(x) else NA, lower = NA, upper = NA, n = n))
  se <- stats::sd(x) / sqrt(n)
  tt <- stats::qt(1 - (1 - conf) / 2, df = n - 1)
  c(mean = mean(x), lower = mean(x) - tt * se, upper = mean(x) + tt * se, n = n)
}

## Percentile bootstrap CI for an arbitrary statistic (default: the mean).
bootstrap_ci <- function(x, statistic = mean, n_resamples = 2000, conf = 0.95,
                         seed = NULL) {
  x <- x[is.finite(x)]
  if (length(x) < 3)
    return(data.frame(estimate = if (length(x)) statistic(x) else NA,
                      lower = NA, upper = NA, method = "bootstrap"))
  if (!is.null(seed)) set.seed(seed)
  boot <- replicate(n_resamples, statistic(sample(x, replace = TRUE)))
  a <- (1 - conf) / 2
  data.frame(estimate = statistic(x),
             lower = unname(stats::quantile(boot, a, na.rm = TRUE)),
             upper = unname(stats::quantile(boot, 1 - a, na.rm = TRUE)),
             method = "bootstrap")
}

## ---- Non-parametric -------------------------------------------------------

## Kruskal-Wallis omnibus test for one response across the levels of one factor.
kruskal_check <- function(y, g) {
  ok <- is.finite(y) & !is.na(g)
  y <- y[ok]; g <- droplevels(as.factor(g[ok]))
  if (nlevels(g) < 2)
    return(data.frame(test = "Kruskal-Wallis", statistic = NA_real_,
                      df = NA, p_value = NA_real_, epsilon_sq = NA_real_))
  k <- stats::kruskal.test(y ~ g)
  N <- length(y)
  eps2 <- (unname(k$statistic) - nlevels(g) + 1) / (N - nlevels(g))
  data.frame(test = "Kruskal-Wallis", statistic = unname(k$statistic),
             df = unname(k$parameter), p_value = k$p.value, epsilon_sq = eps2)
}

## Dunn's post-hoc test (rank-sum, tie-corrected). Uses FSA when present, else a
## base-R implementation. `method` is passed to p.adjust.
dunn_posthoc <- function(y, g, method = "BH") {
  ok <- is.finite(y) & !is.na(g)
  y <- y[ok]; g <- droplevels(as.factor(g[ok]))
  if (nlevels(g) < 2) return(NULL)
  if (isTRUE(HAS$FSA)) {
    res <- tryCatch(FSA::dunnTest(y ~ g, method = method), error = function(e) NULL)
    if (!is.null(res))
      return(data.frame(comparison = res$res$Comparison, Z = res$res$Z,
                        p_unadj = res$res$P.unadj, p_adj = res$res$P.adj,
                        stringsAsFactors = FALSE))
  }
  N <- length(y); r <- rank(y)
  ties <- table(r); tie_term <- sum(ties^3 - ties)
  Rbar <- tapply(r, g, mean); n <- tapply(r, g, length)
  lv <- levels(g); cmb <- utils::combn(lv, 2)
  sigma2 <- (N * (N + 1) / 12) - tie_term / (12 * (N - 1))
  rows <- lapply(seq_len(ncol(cmb)), function(k) {
    a <- cmb[1, k]; b <- cmb[2, k]
    se <- sqrt(sigma2 * (1 / n[a] + 1 / n[b]))
    z <- (Rbar[a] - Rbar[b]) / se
    data.frame(comparison = paste(a, "-", b), Z = as.numeric(z),
               p_unadj = 2 * stats::pnorm(-abs(z)), stringsAsFactors = FALSE)
  })
  df <- do.call(rbind, rows)
  df$p_adj <- stats::p.adjust(df$p_unadj, method = method)
  df
}

## Observed pairwise mean differences with Welch 95% CIs, for every pair of a
## grouping factor. Comparison labels use the "A - B" form (matching Dunn), and
## `pair_key` is an order-independent key for joining significance back on.
pairwise_effects <- function(y, g, conf = 0.95) {
  ok <- is.finite(y) & !is.na(g)
  y <- y[ok]; g <- droplevels(as.factor(g[ok]))
  lv <- levels(g)
  if (length(lv) < 2) return(NULL)
  cb <- utils::combn(lv, 2)
  out <- lapply(seq_len(ncol(cb)), function(k) {
    a <- cb[1, k]; b <- cb[2, k]
    xa <- y[g == a]; xb <- y[g == b]
    na <- length(xa); nb <- length(xb)
    if (na < 2 || nb < 2) return(NULL)
    va <- stats::var(xa); vb <- stats::var(xb)
    d  <- mean(xa) - mean(xb)
    se <- sqrt(va / na + vb / nb)
    df <- if (se > 0)
      se^4 / ((va / na)^2 / (na - 1) + (vb / nb)^2 / (nb - 1)) else na + nb - 2
    tc <- stats::qt(1 - (1 - conf) / 2, df)
    data.frame(comparison = paste(a, "-", b),
               pair_key = paste(sort(c(a, b)), collapse = "\r"),
               mean_diff = d, lower = d - tc * se, upper = d + tc * se,
               stringsAsFactors = FALSE)
  })
  do.call(rbind, Filter(Negate(is.null), out))
}
