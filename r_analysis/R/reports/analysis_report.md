# Design Space Exploration -- Energy Characterization of LLM Inference

## Reproducibility

| Field | Value |
|---|---|
| Software version | R 4.3.3 |
| Pipeline version | 2.0.0 |
| Date | 2026-08-28 20:28:38 |
| Sample size (runs) | 537 |
| Repetitions / cell (median) | 8 |
| Random seed | 20260707 |
| Input dataset | /home/phillian/thesis/r_analysis/data |
| Primary response | Total energy [J] |

## Experimental design

- Runs: **537** across **76** design cells (1-8 repetitions each).
- Factors: hardware, model, quant.
- Fully balanced: **FALSE**; under-replicated cells: **2**.

## Assumption checks

Normality (Shapiro-Wilk) and homogeneity (Levene) on the primary model. When violated the analysis switches to Kruskal-Wallis automatically.

| response | factor | shapiro_p | levene_p | normal | homoscedastic | use_parametric |
|---|---|---|---|---|---|---|
| total_energy_j | hardware       | 4.003754e-25   | 7.066602e-65   | FALSE          | FALSE          | FALSE          |
| total_energy_j | model          | 4.003754e-25   | 3.744686e-01   | FALSE          | TRUE           | FALSE          |
| total_energy_j | quant          | 4.003754e-25   | 9.808680e-01   | FALSE          | TRUE           | FALSE          |

**Path used:** non-parametric (Kruskal-Wallis + Dunn).

## Confirmatory model

| term | sum_sq | df | F_value | p_value | partial_eta_sq | omega_sq | response |
|---|---|---|---|---|---|---|---|
| hardware       | 1.271972e+12   | 3              | 732.9881       | 0.0000         | 0.8044         | 0.8009         | total_energy_j |
| model          | 3.188428e+10   | 3              |  18.3737       | 0.0000         | 0.0888         | 0.0825         | total_energy_j |
| quant          | 3.252257e+09   | 4              |   1.4056       | 0.2308         | 0.0106         | 0.0030         | total_energy_j |

### Effect sizes

| response | term | partial_eta_sq | omega_sq |
|---|---|---|---|
| total_energy_j | hardware       | 0.8044         | 0.8009         |
| total_energy_j | model          | 0.0888         | 0.0825         |
| total_energy_j | quant          | 0.0106         | 0.0030         |

### Kruskal-Wallis (non-parametric omnibus)

| response | factor | test | statistic | df | p_value | epsilon_sq |
|---|---|---|---|---|---|---|
| total_energy_j | hardware       | Kruskal-Wallis | 482.9860       | 3              | 0.0000         |  0.9005        |
| total_energy_j | model          | Kruskal-Wallis |   5.8485       | 3              | 0.1192         |  0.0053        |
| total_energy_j | quant          | Kruskal-Wallis |   0.6415       | 4              | 0.9583         | -0.0063        |

## Significant post-hoc comparisons

12 of 28 comparisons significant at alpha = 0.05.

| factor | response | comparison | Z | p_unadj | p_adj | significant |
|---|---|---|---|---|---|---|
| hardware       | total_energy_j | AMD - V100     |  21.4388       | 0              | 0              | TRUE           |
| hardware       | total_energy_j | AMD - A100     |  13.0597       | 0              | 0              | TRUE           |
| hardware       | total_energy_j | AMD - H100     |   7.6842       | 0              | 0              | TRUE           |
| hardware       | total_energy_j | V100 - A100    |  -7.6505       | 0              | 0              | TRUE           |
| hardware       | total_energy_j | V100 - H100    | -12.3092       | 0              | 0              | TRUE           |
| hardware       | total_energy_j | A100 - H100    |  -4.7727       | 0              | 0              | TRUE           |
| gpu_arch       | total_energy_j | V100 - A100    |  -7.6505       | 0              | 0              | TRUE           |
| gpu_arch       | total_energy_j | V100 - H100    | -12.3092       | 0              | 0              | TRUE           |
| gpu_arch       | total_energy_j | V100 - None    | -21.4388       | 0              | 0              | TRUE           |
| gpu_arch       | total_energy_j | A100 - H100    |  -4.7727       | 0              | 0              | TRUE           |
| gpu_arch       | total_energy_j | A100 - None    | -13.0597       | 0              | 0              | TRUE           |
| gpu_arch       | total_energy_j | H100 - None    |  -7.6842       | 0              | 0              | TRUE           |

## Figures

![figure5_factor_importance](/home/phillian/thesis/r_analysis/figures/figure5_factor_importance.png)

*Factor importance across ANOVA, random forest and standardized regression.*

