#!/usr/bin/env python3
"""ETL: convert raw efimon time-series CSVs into an R-friendly DOE dataset.

The R statistical layer consumes tidy, one-row-per-run tables; it does not parse
the raw efimon output. This script performs that conversion:

  * discovers per-run archives ``llamacpp_<HW>_<ts>_<jobid>.zip`` collected under
    the data root (the node/<HW> is parsed from the file name, see ``node_map.py``)
  * extracts each archive to a temporary directory, whose run dir has the layout
    ``csv_logs/`` (the ``llama_cli_efimon_*`` / ``sleep_efimon_*`` CSVs) and
    ``llama_logs/`` (the ``llama_cli_*`` stdout logs); the temp copy is deleted
    after loading so only the ``.zip`` files remain on disk
  * derives the experimental factors (model, quantization, CPU/GPU arch, execution
    mode, run_id) from the file name and directory (see ``node_map.py``)
  * integrates instantaneous power over time to obtain energy, and computes power,
    frequency, CPU-usage and fan aggregates per run
  * optionally subtracts the paired ``sleep_efimon_*`` idle baseline to obtain
    baseline-adjusted energy (disabled by default; enable with ``--include-sleep``)
  * parses the llama-cli throughput footer ``[ Prompt: X t/s | Generation: Y t/s ]``
    when a captured stdout log is present (otherwise throughput/token metrics are NA)

Outputs (default ``r_analysis/data/``):
  * ``runs_wide.csv``       one row per (node, model, quant, run_id) -- the DOE table
  * ``samples_long.csv``    one row per raw sample (for normality / within-run views)
  * ``data_dictionary.md``  description of every column

Pure standard library (no pandas) so it runs on any Python 3.6+ without extra deps.
"""

import argparse
import csv
import glob
import math
import os
import re
import shutil
import statistics as stats
import sys
import tempfile
import zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from node_map import (  # noqa: E402
    resolve_node,
    resolve_model,
    node_key_from_run_name,
    QUANT_BITS,
    PRIMARY_QUANTS,
    KNOWN_MODEL_FAMILIES,
)

# ---------------------------------------------------------------------------
# Filename parsing
# ---------------------------------------------------------------------------
QUANT_ALTERNATION = "|".join(sorted(QUANT_BITS, key=len, reverse=True))
# First batch (efimon CSVs in csv_logs/):
#   llama_cli_efimon_gemma-2-9b-it-Q2_K_20260701_160103_59402.csv.2995122
#   sleep_before_efimon_gemma-2-9b-it-Q6_K_20260711_185522_12560.csv.3826659
#   sleep_after_efimon_Mistral-7B-Instruct-v0.3-Q8_0_20260711_191006_45207.csv.X
# Second batch (efimon CSVs in efimon/, combined energy+profiling zip):
#   efimon_gemma-2-9b-it-Q2_K_rep01_20260727_145337_46583.csv.1812363
# The kind prefix is optional (plain ``efimon_`` == an inference run) and an
# optional ``_repNN`` repetition token may sit between the quant and timestamp.
FNAME_RE = re.compile(
    r"^(?:(?P<kind>llama_cli|sleep_before|sleep_after|sleep)_)?efimon_"
    r"(?P<model>.+?)[-.](?P<quant>" + QUANT_ALTERNATION + r")"
    r"(?:_rep(?P<rep>\d+))?_"
    r"(?P<date>\d{8})_(?P<time>\d{6})_(?P<pid>\d+)\.csv"
)

THROUGHPUT_RE = re.compile(
    r"Prompt:\s*([0-9.]+)\s*t/s.*?Generation:\s*([0-9.]+)\s*t/s",
    re.IGNORECASE,
)

# Newer llama.cpp `print_timing` footer, e.g.
#   prompt eval time =  391.92 ms /  125 tokens ( 3.14 ms per token, 318.94 tokens per second)
#          eval time = 1518.62 ms /  159 tokens ( 9.55 ms per token, 104.70 tokens per second)
PROMPT_TIMING_RE = re.compile(
    r"prompt eval time\s*=.*?/\s*(\d+)\s*tokens.*?([0-9.]+)\s*tokens per second",
    re.IGNORECASE,
)
GEN_TIMING_RE = re.compile(
    r"(?<!prompt )eval time\s*=.*?/\s*(\d+)\s*tokens.*?([0-9.]+)\s*tokens per second",
    re.IGNORECASE,
)


def parse_measurement_filename(basename):
    """Return dict(kind, model_spec, quant, ts) or None if not a measurement file."""
    m = FNAME_RE.match(basename)
    if not m:
        return None
    return {
        "kind": m.group("kind") or "llama_cli",
        "model_spec": m.group("model"),
        "quant": m.group("quant"),
        "ts": "{}_{}_{}".format(m.group("date"), m.group("time"), m.group("pid")),
        "date": m.group("date"),
        "time": m.group("time"),
    }


# ---------------------------------------------------------------------------
# CSV loading / per-sample reduction
# ---------------------------------------------------------------------------
def _cols(header, pattern):
    rx = re.compile(pattern)
    return [c for c in header if rx.match(c)]


def _to_float(x):
    try:
        return float(x)
    except (TypeError, ValueError):
        return math.nan


def load_samples(path):
    """Load an efimon CSV into a list of per-sample dicts with reduced signals.

    Returns list of dicts: socket_power, psu_power, socket_freq, system_cpu,
    process_cpu, fan_mean, fan_max, dt_s.
    """
    with open(path, newline="") as fh:
        reader = csv.DictReader(fh)
        header = reader.fieldnames or []
        socket_cols = _cols(header, r"SocketPower\d+$")
        psu_cols = _cols(header, r"PSUPower\d+$")
        freq_cols = _cols(header, r"SocketFreq\d+$")
        fan_cols = _cols(header, r"FanSpeed\d+$")
        samples = []
        for row in reader:
            socket = [_to_float(row[c]) for c in socket_cols]
            psu = [_to_float(row[c]) for c in psu_cols]
            freq = [_to_float(row[c]) for c in freq_cols]
            fans = [_to_float(row[c]) for c in fan_cols if not math.isnan(_to_float(row[c]))]
            dt_ms = _to_float(row.get("TimeDifference", "nan"))
            samples.append(
                {
                    "socket_power": _nansum(socket),
                    "psu_power": _nansum(psu),
                    "socket_freq": _nanmean(freq),
                    "system_cpu": _to_float(row.get("SystemCpuUsage", "nan")),
                    "process_cpu": _to_float(row.get("ProcessCpuUsage", "nan")),
                    "fan_mean": _nanmean(fans) if fans else math.nan,
                    "fan_max": max(fans) if fans else math.nan,
                    "dt_s": (dt_ms / 1000.0) if not math.isnan(dt_ms) else math.nan,
                }
            )
    return samples


def _nansum(vals):
    v = [x for x in vals if not math.isnan(x)]
    return sum(v) if v else math.nan


def _nanmean(vals):
    v = [x for x in vals if not math.isnan(x)]
    return (sum(v) / len(v)) if v else math.nan


def _default_dt(samples):
    dts = [s["dt_s"] for s in samples if not math.isnan(s["dt_s"]) and s["dt_s"] > 0]
    return stats.median(dts) if dts else math.nan


# ---------------------------------------------------------------------------
# Throughput parsing (optional; present once collection scripts capture stdout)
# ---------------------------------------------------------------------------
def find_throughput(run_dir, info):
    """Look for a captured llama-cli stdout/log matching this model/quant/ts and
    return (prompt_tps, generation_tps, generated_tokens).

    Logs live in ``run_dir/llama_logs/`` (with the run-dir root kept as a tolerant
    fallback). Supports the modern ``print_timing`` footer (``eval time = ... / N
    tokens ... tokens per second``) and the legacy ``[ Prompt: X t/s | Generation:
    Y t/s ]`` footer. Missing values are returned as NaN."""
    patterns = []
    for base in (os.path.join(run_dir, "llama_logs"), run_dir):
        patterns.extend([
            # Second batch: efimon_<model>-<quant>_repNN_<date>_<time>_<pid>.log
            os.path.join(base, "efimon_{}*{}*_{}_{}_*.log".format(
                info["model_spec"], info["quant"], info["date"], info["time"])),
            os.path.join(base, "efimon_{}*{}*.log".format(
                info["model_spec"], info["quant"])),
            # First batch: llama_cli_* / llama_stdout_* captured stdout
            os.path.join(base, "llama_cli_{}*{}_{}_{}_*.log".format(
                info["model_spec"], info["quant"], info["date"], info["time"])),
            os.path.join(base, "llama_cli_{}*{}*.log".format(
                info["model_spec"], info["quant"])),
            os.path.join(base, "llama_stdout_{}*{}*.log".format(info["model_spec"], info["quant"])),
            os.path.join(base, "llama_stdout_*{}*{}*".format(info["model_spec"], info["quant"])),
            os.path.join(base, "*{}*{}*stdout*".format(info["model_spec"], info["quant"])),
        ])
    for pat in patterns:
        for cand in sorted(glob.glob(pat)):
            try:
                with open(cand, errors="ignore") as fh:
                    text = fh.read()
            except OSError:
                continue
            prompt_tps = gen_tps = gen_tokens = math.nan
            mg = GEN_TIMING_RE.search(text)
            if mg:
                gen_tokens = float(mg.group(1))
                gen_tps = float(mg.group(2))
            mp = PROMPT_TIMING_RE.search(text)
            if mp:
                prompt_tps = float(mp.group(2))
            if math.isnan(gen_tps):  # legacy footer fallback
                m = THROUGHPUT_RE.search(text)
                if m:
                    prompt_tps, gen_tps = float(m.group(1)), float(m.group(2))
            if not (math.isnan(gen_tps) and math.isnan(prompt_tps)):
                return prompt_tps, gen_tps, gen_tokens
    return math.nan, math.nan, math.nan


# ---------------------------------------------------------------------------
# Per-run aggregation
# ---------------------------------------------------------------------------
def aggregate_run(llama_path, sleep_paths, run_dir, node_key, info, run_id=None):
    samples = load_samples(llama_path)
    if not samples:
        return None
    dt_default = _default_dt(samples)

    def dt(s):
        return s["dt_s"] if not math.isnan(s["dt_s"]) and s["dt_s"] > 0 else dt_default

    socket_series = [s["socket_power"] for s in samples if not math.isnan(s["socket_power"])]
    psu_series = [s["psu_power"] for s in samples if not math.isnan(s["psu_power"])]

    energy_socket = _nansum([s["socket_power"] * dt(s) for s in samples])
    energy_psu = _nansum([s["psu_power"] * dt(s) for s in samples])
    exec_time = _nansum([dt(s) for s in samples])

    # baseline: pool the paired idle (sleep_before + sleep_after) samples and
    # average their instantaneous power.
    idle_socket = idle_psu = math.nan
    base = []
    for sp in (sleep_paths or []):
        if sp and os.path.exists(sp):
            base.extend(load_samples(sp))
    if base:
        idle_socket = _nanmean([b["socket_power"] for b in base])
        idle_psu = _nanmean([b["psu_power"] for b in base])
    energy_socket_adj = (
        _nansum([(s["socket_power"] - idle_socket) * dt(s) for s in samples])
        if not math.isnan(idle_socket)
        else math.nan
    )
    energy_psu_adj = (
        _nansum([(s["psu_power"] - idle_psu) * dt(s) for s in samples])
        if not math.isnan(idle_psu)
        else math.nan
    )

    freq_series = [s["socket_freq"] for s in samples if not math.isnan(s["socket_freq"])]
    fan_means = [s["fan_mean"] for s in samples if not math.isnan(s["fan_mean"])]
    fan_maxes = [s["fan_max"] for s in samples if not math.isnan(s["fan_max"])]

    family, size_b = resolve_model(info["model_spec"])
    node = resolve_node(node_key)

    prompt_tps, gen_tps, gen_tokens = find_throughput(run_dir, info)
    # Prefer the measured generated-token count; else approximate with rate x time.
    if not math.isnan(gen_tokens):
        est_tokens = gen_tokens
    elif not math.isnan(gen_tps):
        est_tokens = gen_tps * exec_time
    else:
        est_tokens = math.nan
    total_energy = energy_psu if not math.isnan(energy_psu) else energy_socket
    energy_per_token = (
        total_energy / est_tokens if est_tokens and not math.isnan(est_tokens) and est_tokens > 0 else math.nan
    )
    tokens_per_joule = (
        est_tokens / total_energy if total_energy and not math.isnan(total_energy) and total_energy > 0 else math.nan
    )

    return {
        "run_id": run_id if run_id is not None else os.path.basename(run_dir),
        "node": node_key,
        "cpu_arch": node["cpu_arch"],
        "gpu_arch": node["gpu_arch"],
        "exec_mode": node["exec_mode"],
        "model": family,
        "model_size_b": size_b,
        "quant": info["quant"],
        "quant_bits": QUANT_BITS.get(info["quant"], math.nan),
        "timestamp": info["ts"],
        "n_samples": len(samples),
        "exec_time_s": exec_time,
        "energy_socket_j": energy_socket,
        "energy_psu_j": energy_psu,
        "energy_socket_adj_j": energy_socket_adj,
        "energy_psu_adj_j": energy_psu_adj,
        "avg_socket_power_w": _nanmean(socket_series),
        "peak_socket_power_w": max(socket_series) if socket_series else math.nan,
        "avg_psu_power_w": _nanmean(psu_series),
        "peak_psu_power_w": max(psu_series) if psu_series else math.nan,
        "idle_socket_power_w": idle_socket,
        "idle_psu_power_w": idle_psu,
        "avg_cpu_freq_mhz": _nanmean(freq_series),
        "cpu_freq_sd_mhz": stats.pstdev(freq_series) if len(freq_series) > 1 else math.nan,
        "avg_system_cpu_pct": _nanmean([s["system_cpu"] for s in samples]),
        "avg_process_cpu_pct": _nanmean([s["process_cpu"] for s in samples]),
        "avg_fan_rpm": _nanmean(fan_means) if fan_means else math.nan,
        "peak_fan_rpm": max(fan_maxes) if fan_maxes else math.nan,
        "prompt_tps": prompt_tps,
        "generation_tps": gen_tps,
        "est_tokens": est_tokens,
        "energy_per_token_j": energy_per_token,
        "tokens_per_joule": tokens_per_joule,
    }, samples


WIDE_COLUMNS = [
    "run_id", "node", "cpu_arch", "gpu_arch", "exec_mode", "model", "model_size_b",
    "quant", "quant_bits", "timestamp", "n_samples", "exec_time_s",
    "energy_socket_j", "energy_psu_j", "energy_socket_adj_j", "energy_psu_adj_j",
    "avg_socket_power_w", "peak_socket_power_w", "avg_psu_power_w", "peak_psu_power_w",
    "idle_socket_power_w", "idle_psu_power_w", "avg_cpu_freq_mhz", "cpu_freq_sd_mhz",
    "avg_system_cpu_pct", "avg_process_cpu_pct", "avg_fan_rpm", "peak_fan_rpm",
    "prompt_tps", "generation_tps", "est_tokens", "energy_per_token_j", "tokens_per_joule",
]

LONG_COLUMNS = [
    "run_id", "node", "model", "quant", "exec_mode", "sample_idx", "time_s",
    "socket_power_w", "psu_power_w", "socket_freq_mhz", "system_cpu_pct",
    "process_cpu_pct", "fan_mean_rpm",
]


def _fmt(v):
    if isinstance(v, float):
        if math.isnan(v):
            return ""
        return repr(round(v, 6))
    return v


def _locate_run_dir(extract_root):
    """Return the run directory inside an extracted archive.

    Handles the expected case where the whole ``RUN_DIR`` was zipped (a single
    top-level directory) as well as the tolerant case where the run files were
    zipped flat (``extract_root`` itself is the run dir).
    """
    entries = [os.path.join(extract_root, e) for e in os.listdir(extract_root)]
    subdirs = [e for e in entries if os.path.isdir(e)]
    files = [e for e in entries if os.path.isfile(e)]
    if len(subdirs) == 1 and not files:
        return subdirs[0]
    return extract_root


def _process_run_dir(run_dir, node_key, run_id, allowed_quants,
                     keep_unknown_models, wide_rows, long_rows,
                     use_sleep=False):
    """Load one extracted run directory into the wide/long row accumulators.

    The paired ``sleep_efimon_*`` idle baseline is ignored unless ``use_sleep``
    is set; when ignored, the idle-power and baseline-adjusted energy columns
    are left as NaN.
    """
    csv_dir = run_dir
    for cand in ("csv_logs", "efimon"):
        d = os.path.join(run_dir, cand)
        if os.path.isdir(d):
            csv_dir = d  # first batch -> csv_logs/, second batch -> efimon/
            break
    # index sleep files by (model_spec, quant) for pairing (only if wanted).
    # Timestamps differ between the idle and inference runs, so pairing is by
    # model+quant; both sleep_before and sleep_after are collected per key.
    sleep_index = {}
    llama_files = []
    for path in sorted(glob.glob(os.path.join(csv_dir, "*efimon_*.csv*"))):
        info = parse_measurement_filename(os.path.basename(path))
        if not info:
            continue
        key = (info["model_spec"], info["quant"])
        if info["kind"].startswith("sleep"):
            if use_sleep:
                sleep_index.setdefault(key, []).append(path)
        else:
            llama_files.append((path, info))
    for path, info in llama_files:
        if info["quant"] not in allowed_quants:
            continue
        sleep_paths = sleep_index.get((info["model_spec"], info["quant"])) \
            if use_sleep else None
        result = aggregate_run(path, sleep_paths, run_dir, node_key, info, run_id=run_id)
        if result is None:
            continue
        agg, samples = result
        if not keep_unknown_models and agg["model"] not in KNOWN_MODEL_FAMILIES:
            continue
        wide_rows.append(agg)
        t = 0.0
        for i, s in enumerate(samples):
            dt = s["dt_s"] if not math.isnan(s["dt_s"]) else 0.0
            long_rows.append(
                {
                    "run_id": agg["run_id"], "node": node_key,
                    "model": agg["model"], "quant": agg["quant"],
                    "exec_mode": agg["exec_mode"], "sample_idx": i, "time_s": round(t, 3),
                    "socket_power_w": s["socket_power"], "psu_power_w": s["psu_power"],
                    "socket_freq_mhz": s["socket_freq"], "system_cpu_pct": s["system_cpu"],
                    "process_cpu_pct": s["process_cpu"], "fan_mean_rpm": s["fan_mean"],
                }
            )
            t += dt


def build(data_root, out_dir, nodes_filter, keep_unknown_models=False,
          use_sleep=False):
    os.makedirs(out_dir, exist_ok=True)
    wide_rows = []
    long_rows = []
    allowed_quants = set(PRIMARY_QUANTS) | {"Q2_K"}

    # Run archives are collected together under the data root (node is encoded in
    # the file name, not the folder path). Discover them anywhere beneath it.
    zip_paths = sorted(glob.glob(os.path.join(data_root, "**", "*.zip"), recursive=True))
    for zip_path in zip_paths:
        run_id = os.path.splitext(os.path.basename(zip_path))[0]
        node_key = node_key_from_run_name(os.path.basename(zip_path))
        if node_key is None:
            print("  WARNING: cannot derive node from {}, skipping".format(os.path.basename(zip_path)))
            continue
        if nodes_filter and node_key not in nodes_filter:
            continue
        extract_root = tempfile.mkdtemp(prefix="efimon_etl_")
        try:
            try:
                with zipfile.ZipFile(zip_path) as zf:
                    zf.extractall(extract_root)
            except (zipfile.BadZipFile, OSError) as exc:
                print("  WARNING: skipping unreadable zip {}: {}".format(zip_path, exc))
                continue
            run_dir = _locate_run_dir(extract_root)
            _process_run_dir(run_dir, node_key, run_id, allowed_quants,
                             keep_unknown_models, wide_rows, long_rows,
                             use_sleep=use_sleep)
        finally:
            shutil.rmtree(extract_root, ignore_errors=True)

    _write_csv(os.path.join(out_dir, "runs_wide.csv"), WIDE_COLUMNS, wide_rows)
    _write_csv(os.path.join(out_dir, "samples_long.csv"), LONG_COLUMNS, long_rows)
    _write_dictionary(os.path.join(out_dir, "data_dictionary.md"))
    print("Wrote {} run rows and {} sample rows to {}".format(len(wide_rows), len(long_rows), out_dir))
    _summarise(wide_rows)


def _write_csv(path, columns, rows):
    with open(path, "w", newline="") as fh:
        writer = csv.writer(fh)
        writer.writerow(columns)
        for r in rows:
            writer.writerow([_fmt(r.get(c, "")) for c in columns])


def _summarise(rows):
    if not rows:
        print("  WARNING: no runs found -- check --data-root")
        return
    from collections import Counter
    print("  nodes     :", dict(Counter(r["node"] for r in rows)))
    print("  models    :", dict(Counter(r["model"] for r in rows)))
    print("  quants    :", dict(Counter(r["quant"] for r in rows)))
    print("  exec_mode :", dict(Counter(r["exec_mode"] for r in rows)))
    have_tp = sum(1 for r in rows if not (isinstance(r["generation_tps"], float) and math.isnan(r["generation_tps"])))
    print("  throughput captured for {}/{} runs".format(have_tp, len(rows)))


def _write_dictionary(path):
    with open(path, "w") as fh:
        fh.write(DATA_DICTIONARY)


DATA_DICTIONARY = """# Data dictionary -- R analysis dataset

Generated by `etl/build_dataset.py` (energy pipeline). Two tables are produced.

## runs_wide.csv  (one row per node x model x quant x run_id -- the DOE table)

### Factors
| column | description |
|---|---|
| run_id | run directory name; the repeated-measurement identifier |
| node | measurement node key |
| cpu_arch | AMD / Intel (derived from node) |
| gpu_arch | None / V100 / A100 / H100 (derived from node) |
| exec_mode | CPU-only / GPU-only (CPU-GPU added later) |
| model | model family (Gemma-2-9B, Llama-3.1-8B, Mistral-7B, Mixtral-8x7B, Phi-3.5-mini-3.8B) |
| model_size_b | total parameters in billions (Mixtral uses total, not active) |
| quant | quantization label (Q2_K, Q4_K_M, Q5_K_M, Q6_K, Q8_0) |
| quant_bits | approximate effective bits-per-weight (numeric surrogate for regression) |
| timestamp | run start timestamp parsed from the file name |

### Primary responses
| column | units | description |
|---|---|---|
| energy_socket_j | J | CPU socket energy = sum(socket_power x dt) |
| energy_psu_j | J | whole-node PSU energy = sum(psu_power x dt); treated as total system energy |
| energy_socket_adj_j | J | socket energy above idle baseline (paired sleep run) |
| energy_psu_adj_j | J | PSU energy above idle baseline |
| avg_socket_power_w / peak_socket_power_w | W | mean / max total socket power |
| avg_psu_power_w / peak_psu_power_w | W | mean / max total PSU power |
| exec_time_s | s | wall time = sum of sample intervals |
| generation_tps | tokens/s | llama-cli generation throughput (NA until stdout capture is enabled) |
| prompt_tps | tokens/s | llama-cli prompt-eval throughput (NA until stdout capture is enabled) |
| energy_per_token_j | J/token | total_energy / est_tokens (approximation) |
| tokens_per_joule | tokens/J | est_tokens / total_energy (approximation) |

### Secondary responses / covariates
| column | units | description |
|---|---|---|
| idle_socket_power_w / idle_psu_power_w | W | mean idle power from paired sleep run |
| avg_cpu_freq_mhz / cpu_freq_sd_mhz | MHz | mean / population sd of per-sample mean socket frequency |
| avg_system_cpu_pct / avg_process_cpu_pct | % | mean system / process CPU usage |
| avg_fan_rpm / peak_fan_rpm | RPM | mean / max fan speed across all fans |
| n_samples | count | number of ~3s efimon samples in the run |
| est_tokens | tokens | approx tokens = generation_tps x exec_time_s (see limitations) |

### Notes / limitations
* GPU-specific power is NOT measured; only CPU socket power and whole-node PSU power exist.
* Temperature sensors are not present in the efimon output, so no temperature columns.
* Token counts are not emitted by llama-cli here (only rates), so est_tokens,
  energy_per_token_j and tokens_per_joule are approximations and will be NA until the
  collection scripts capture the `[ Prompt: X t/s | Generation: Y t/s ]` footer.

## samples_long.csv  (one row per raw efimon sample)
Used for normality / Q-Q / within-run variance views. Columns: run_id, node, model,
quant, exec_mode, sample_idx, time_s, socket_power_w, psu_power_w, socket_freq_mhz,
system_cpu_pct, process_cpu_pct, fan_mean_rpm.
"""


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__)
    here = os.path.dirname(os.path.abspath(__file__))
    default_root = os.path.normpath(os.path.join(here, "..", "..", "efimon_data"))
    default_out = os.path.normpath(os.path.join(here, "..", "data"))
    p.add_argument("--data-root", default=default_root, help="efimon_data directory")
    p.add_argument("--out-dir", default=default_out, help="output directory for CSVs")
    p.add_argument("--nodes", nargs="*", default=None, help="restrict to these node keys")
    p.add_argument("--keep-unknown-models", action="store_true",
                   help="keep model families outside the five study models")
    p.add_argument("--include-sleep", action="store_true",
                   help="pair the sleep_efimon_* idle baseline to fill the idle "
                        "power and baseline-adjusted energy columns (ignored by "
                        "default)")
    args = p.parse_args(argv)
    build(args.data_root, args.out_dir,
          set(args.nodes) if args.nodes else None, args.keep_unknown_models,
          use_sleep=args.include_sleep)


if __name__ == "__main__":
    main()