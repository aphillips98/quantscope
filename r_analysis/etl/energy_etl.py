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
  * ``samples_long.csv``    one row per raw sample (for time-series / within-run views)
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

# Wall-clock timings emitted by llama.cpp `print_timing`, in milliseconds. These
# are the authoritative run/inference durations (efimon's ``exec_time_s`` is only
# the summed sampling window, which is unreliable on short GPU runs). ``load time``
# is not emitted by the newer ``slot print_timing`` footer, so it is usually NA.
LOAD_TIME_RE = re.compile(r"load time\s*=\s*([0-9.]+)\s*ms", re.IGNORECASE)
PROMPT_EVAL_TIME_RE = re.compile(
    r"prompt eval time\s*=\s*([0-9.]+)\s*ms\s*/\s*(\d+)\s*tokens", re.IGNORECASE
)
EVAL_TIME_RE = re.compile(
    r"(?<!prompt )eval time\s*=\s*([0-9.]+)\s*ms\s*/\s*(\d+)\s*(?:tokens|runs)",
    re.IGNORECASE,
)
TOTAL_TIME_RE = re.compile(
    r"total time\s*=\s*([0-9.]+)\s*ms(?:\s*/\s*(\d+)\s*tokens)?", re.IGNORECASE
)

LLAMA_TIMING_KEYS = (
    "load_time_ms", "prompt_eval_time_ms", "prompt_tokens",
    "eval_time_ms", "eval_tokens", "total_time_ms", "total_tokens",
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
        "pid": m.group("pid"),
        "rep": int(m.group("rep")) if m.group("rep") else None,
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
            fans = []
            for c in fan_cols:
                value = _to_float(row[c])
                if not math.isnan(value):
                    fans.append(value)
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


def _resolved_dts(samples):
    """Resolve per-sample intervals consistently for energy and long-format time.

    The first zero/invalid interval is kept at 0.0 because it normally marks the
    initial sample at t=0. Later missing/invalid intervals are replaced by the
    median valid sampling interval.
    """
    default_dt = _default_dt(samples)
    resolved = []
    for i, sample in enumerate(samples):
        value = sample["dt_s"]
        if not math.isnan(value) and value > 0:
            resolved.append(value)
        elif i == 0:
            resolved.append(0.0)
        elif not math.isnan(default_dt):
            resolved.append(default_dt)
        else:
            resolved.append(math.nan)
    return resolved


def _time_weighted_mean(values, dts):
    pairs = [
        (value, delta)
        for value, delta in zip(values, dts)
        if not math.isnan(value) and not math.isnan(delta) and delta > 0
    ]
    if not pairs:
        return math.nan
    total_time = sum(delta for _, delta in pairs)
    return sum(value * delta for value, delta in pairs) / total_time if total_time > 0 else math.nan


# ---------------------------------------------------------------------------
# Throughput parsing (optional; present once collection scripts capture stdout)
# ---------------------------------------------------------------------------
def _llama_log_candidates(run_dir, info):
    """Return ordered candidate llama.cpp log paths for this measurement.

    Exact timestamp/PID/repetition matches are preferred. A broad fallback is
    accepted only when it resolves to a single candidate, preventing silent
    association with another repetition. Returns ``None`` when the fallback is
    ambiguous (multiple candidates) and ``[]`` when nothing is found.
    """
    bases = (os.path.join(run_dir, "llama_logs"), run_dir)
    exact_patterns = []
    fallback_patterns = []

    rep_token = "_rep{:02d}".format(info["rep"]) if info.get("rep") is not None else ""
    for base in bases:
        exact_patterns.extend([
            os.path.join(
                base,
                "efimon_{}*{}{}*_{}_{}_{}*.log".format(
                    info["model_spec"], info["quant"], rep_token,
                    info["date"], info["time"], info["pid"]
                ),
            ),
            os.path.join(
                base,
                "llama_cli_{}*{}_{}_{}_{}*.log".format(
                    info["model_spec"], info["quant"],
                    info["date"], info["time"], info["pid"]
                ),
            ),
            os.path.join(
                base,
                "llama_stdout_{}*{}_{}_{}_{}*.log".format(
                    info["model_spec"], info["quant"],
                    info["date"], info["time"], info["pid"]
                ),
            ),
        ])
        fallback_patterns.extend([
            os.path.join(base, "efimon_{}*{}{}*.log".format(
                info["model_spec"], info["quant"], rep_token)),
            os.path.join(base, "llama_cli_{}*{}*.log".format(
                info["model_spec"], info["quant"])),
            os.path.join(base, "llama_stdout_{}*{}*.log".format(
                info["model_spec"], info["quant"])),
        ])

    def unique_candidates(patterns):
        found = []
        seen = set()
        for pat in patterns:
            for cand in sorted(glob.glob(pat)):
                if cand not in seen:
                    seen.add(cand)
                    found.append(cand)
        return found

    candidates = unique_candidates(exact_patterns)
    if not candidates:
        fallback = unique_candidates(fallback_patterns)
        if len(fallback) == 1:
            candidates = fallback
        elif len(fallback) > 1:
            return None
    return candidates


def find_throughput(run_dir, info):
    """Return (prompt_tps, generation_tps, generated_tokens) for this measurement."""
    candidates = _llama_log_candidates(run_dir, info)
    if candidates is None:
        print(
            "  WARNING: ambiguous throughput logs for {} {} {}; leaving NA".format(
                info["model_spec"], info["quant"], info["ts"]
            )
        )
        return math.nan, math.nan, math.nan

    for cand in candidates:
        try:
            with open(cand, errors="ignore") as fh:
                text = fh.read()
        except OSError:
            continue

        prompt_tps = gen_tps = gen_tokens = math.nan
        gen_matches = GEN_TIMING_RE.findall(text)
        prompt_matches = PROMPT_TIMING_RE.findall(text)
        if gen_matches:
            gen_tokens = float(gen_matches[-1][0])
            gen_tps = float(gen_matches[-1][1])
        if prompt_matches:
            prompt_tps = float(prompt_matches[-1][1])

        if math.isnan(gen_tps):
            legacy_matches = THROUGHPUT_RE.findall(text)
            if legacy_matches:
                prompt_tps = float(legacy_matches[-1][0])
                gen_tps = float(legacy_matches[-1][1])

        if not (math.isnan(gen_tps) and math.isnan(prompt_tps)):
            return prompt_tps, gen_tps, gen_tokens

    return math.nan, math.nan, math.nan


def _nan_timings():
    return {k: math.nan for k in LLAMA_TIMING_KEYS}


def parse_llama_timings(text):
    """Extract llama.cpp ``print_timing`` durations (ms) and token counts."""
    t = _nan_timings()
    m = LOAD_TIME_RE.findall(text)
    if m:
        t["load_time_ms"] = float(m[-1])
    m = PROMPT_EVAL_TIME_RE.findall(text)
    if m:
        t["prompt_eval_time_ms"] = float(m[-1][0])
        t["prompt_tokens"] = float(m[-1][1])
    m = EVAL_TIME_RE.findall(text)
    if m:
        t["eval_time_ms"] = float(m[-1][0])
        t["eval_tokens"] = float(m[-1][1])
    m = TOTAL_TIME_RE.findall(text)
    if m:
        t["total_time_ms"] = float(m[-1][0])
        if m[-1][1]:
            t["total_tokens"] = float(m[-1][1])
    return t


def find_llama_timings(run_dir, info):
    """Return the llama.cpp timing dict for this measurement (NaNs if unavailable)."""
    candidates = _llama_log_candidates(run_dir, info)
    if not candidates:
        return _nan_timings()
    for cand in candidates:
        try:
            with open(cand, errors="ignore") as fh:
                text = fh.read()
        except OSError:
            continue
        timings = parse_llama_timings(text)
        if any(not math.isnan(v) for v in timings.values()):
            return timings
    return _nan_timings()



# ---------------------------------------------------------------------------
# Per-run aggregation
# ---------------------------------------------------------------------------
def aggregate_run(llama_path, sleep_paths, run_dir, node_key, info, run_id=None,
                  time_source="efimon"):
    samples = load_samples(llama_path)
    if not samples:
        return None

    resolved_dts = _resolved_dts(samples)
    valid_dts = [d for d in resolved_dts if not math.isnan(d)]
    if not valid_dts or sum(valid_dts) <= 0:
        print("  WARNING: no valid sample intervals in {}, skipping".format(llama_path))
        return None

    socket_values = [s["socket_power"] for s in samples]
    psu_values = [s["psu_power"] for s in samples]

    energy_socket = _nansum([
        power * delta
        for power, delta in zip(socket_values, resolved_dts)
        if not math.isnan(power) and not math.isnan(delta)
    ])
    energy_psu = _nansum([
        power * delta
        for power, delta in zip(psu_values, resolved_dts)
        if not math.isnan(power) and not math.isnan(delta)
    ])
    exec_time = _nansum(resolved_dts)

    avg_socket_power = (
        energy_socket / exec_time
        if not math.isnan(energy_socket) and not math.isnan(exec_time) and exec_time > 0
        else math.nan
    )
    avg_psu_power = (
        energy_psu / exec_time
        if not math.isnan(energy_psu) and not math.isnan(exec_time) and exec_time > 0
        else math.nan
    )

    # Paired idle baseline. Each sleep run is reduced separately, then the
    # before/after means receive equal weight.
    idle_socket_runs = []
    idle_psu_runs = []
    for sp in (sleep_paths or []):
        if not sp or not os.path.exists(sp):
            continue
        base_samples = load_samples(sp)
        if not base_samples:
            continue
        base_dts = _resolved_dts(base_samples)
        socket_idle = _time_weighted_mean(
            [b["socket_power"] for b in base_samples], base_dts
        )
        psu_idle = _time_weighted_mean(
            [b["psu_power"] for b in base_samples], base_dts
        )
        if not math.isnan(socket_idle):
            idle_socket_runs.append(socket_idle)
        if not math.isnan(psu_idle):
            idle_psu_runs.append(psu_idle)

    idle_socket = _nanmean(idle_socket_runs)
    idle_psu = _nanmean(idle_psu_runs)

    energy_socket_adj = (
        energy_socket - idle_socket * exec_time
        if not math.isnan(energy_socket) and not math.isnan(idle_socket)
        else math.nan
    )
    energy_psu_adj = (
        energy_psu - idle_psu * exec_time
        if not math.isnan(energy_psu) and not math.isnan(idle_psu)
        else math.nan
    )

    socket_series = [x for x in socket_values if not math.isnan(x)]
    psu_series = [x for x in psu_values if not math.isnan(x)]
    freq_series = [s["socket_freq"] for s in samples if not math.isnan(s["socket_freq"])]
    fan_means = [s["fan_mean"] for s in samples if not math.isnan(s["fan_mean"])]
    fan_maxes = [s["fan_max"] for s in samples if not math.isnan(s["fan_max"])]

    family, size_b = resolve_model(info["model_spec"])
    node = resolve_node(node_key)
    base_run_id = run_id if run_id is not None else os.path.basename(run_dir)
    measurement_id = "{}__{}__{}__{}__{}".format(
        base_run_id, node_key, family, info["quant"], info["ts"]
    )

    prompt_tps, gen_tps, gen_tokens = find_throughput(run_dir, info)
    timings = find_llama_timings(run_dir, info)

    def _ms_to_s(x):
        return x / 1000.0 if not math.isnan(x) else math.nan

    # llama.cpp reports the authoritative wall-clock durations. ``total time`` is
    # the end-to-end generation window (prompt eval + token generation, excluding
    # model load), and prompt_eval+eval is the pure compute time. These are kept
    # alongside efimon's ``exec_time_s`` (the summed sampling window), not instead
    # of it.
    llama_total_time_s = _ms_to_s(timings["total_time_ms"])
    llama_load_time_s = _ms_to_s(timings["load_time_ms"])
    llama_prompt_eval_time_s = _ms_to_s(timings["prompt_eval_time_ms"])
    llama_eval_time_s = _ms_to_s(timings["eval_time_ms"])
    _compute_parts = [
        p for p in (timings["prompt_eval_time_ms"], timings["eval_time_ms"])
        if not math.isnan(p)
    ]
    llama_inference_time_s = sum(_compute_parts) / 1000.0 if _compute_parts else math.nan

    # ``exec_time`` (efimon Σdt) is always preserved in ``efimon_time_s``. The
    # canonical ``exec_time_s`` consumed downstream is selectable: the efimon
    # window by default, or llama.cpp's total time when ``time_source=='llama'``
    # (falling back to efimon when the llama timing is unavailable). Energy and
    # power columns stay efimon-integral based regardless of this choice.
    efimon_time = exec_time
    if time_source == "llama" and not math.isnan(llama_total_time_s):
        canonical_time = llama_total_time_s
    else:
        canonical_time = efimon_time

    # Token-efficiency metrics are only computed from a measured generated-token
    # count. generation_tps * EFIMON wall time is intentionally not used because
    # the EFIMON window can include model load, prompt evaluation, and overhead.
    est_tokens = gen_tokens if not math.isnan(gen_tokens) else math.nan
    energy_per_token = (
        energy_psu / est_tokens
        if not math.isnan(energy_psu) and not math.isnan(est_tokens) and est_tokens > 0
        else math.nan
    )
    tokens_per_joule = (
        est_tokens / energy_psu
        if not math.isnan(energy_psu) and energy_psu > 0
        and not math.isnan(est_tokens) and est_tokens > 0
        else math.nan
    )

    return {
        "measurement_id": measurement_id,
        "run_id": base_run_id,
        "repetition": info.get("rep"),
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
        "exec_time_s": canonical_time,
        "efimon_time_s": efimon_time,
        "energy_socket_j": energy_socket,
        "energy_psu_j": energy_psu,
        "energy_socket_adj_j": energy_socket_adj,
        "energy_psu_adj_j": energy_psu_adj,
        "avg_socket_power_w": avg_socket_power,
        "peak_socket_power_w": max(socket_series) if socket_series else math.nan,
        "avg_psu_power_w": avg_psu_power,
        "peak_psu_power_w": max(psu_series) if psu_series else math.nan,
        "idle_socket_power_w": idle_socket,
        "idle_psu_power_w": idle_psu,
        "avg_cpu_freq_mhz": _time_weighted_mean(
            [s["socket_freq"] for s in samples], resolved_dts
        ),
        "cpu_freq_sd_mhz": stats.pstdev(freq_series) if len(freq_series) > 1 else math.nan,
        "avg_system_cpu_pct": _time_weighted_mean(
            [s["system_cpu"] for s in samples], resolved_dts
        ),
        "avg_process_cpu_pct": _time_weighted_mean(
            [s["process_cpu"] for s in samples], resolved_dts
        ),
        "avg_fan_rpm": _time_weighted_mean(
            [s["fan_mean"] for s in samples], resolved_dts
        ),
        "peak_fan_rpm": max(fan_maxes) if fan_maxes else math.nan,
        "prompt_tps": prompt_tps,
        "generation_tps": gen_tps,
        "est_tokens": est_tokens,
        "energy_per_token_j": energy_per_token,
        "tokens_per_joule": tokens_per_joule,
        "llama_total_time_s": llama_total_time_s,
        "llama_inference_time_s": llama_inference_time_s,
        "llama_load_time_s": llama_load_time_s,
        "llama_prompt_eval_time_s": llama_prompt_eval_time_s,
        "llama_eval_time_s": llama_eval_time_s,
        "llama_prompt_tokens": timings["prompt_tokens"],
        "llama_eval_tokens": timings["eval_tokens"],
        "llama_total_tokens": timings["total_tokens"],
    }, samples, resolved_dts


WIDE_COLUMNS = [
    "measurement_id", "run_id", "repetition", "node", "cpu_arch", "gpu_arch", "exec_mode", "model", "model_size_b",
    "quant", "quant_bits", "timestamp", "n_samples", "exec_time_s", "efimon_time_s",
    "energy_socket_j", "energy_psu_j", "energy_socket_adj_j", "energy_psu_adj_j",
    "avg_socket_power_w", "peak_socket_power_w", "avg_psu_power_w", "peak_psu_power_w",
    "idle_socket_power_w", "idle_psu_power_w", "avg_cpu_freq_mhz", "cpu_freq_sd_mhz",
    "avg_system_cpu_pct", "avg_process_cpu_pct", "avg_fan_rpm", "peak_fan_rpm",
    "prompt_tps", "generation_tps", "est_tokens", "energy_per_token_j", "tokens_per_joule",
    "llama_total_time_s", "llama_inference_time_s", "llama_load_time_s",
    "llama_prompt_eval_time_s", "llama_eval_time_s",
    "llama_prompt_tokens", "llama_eval_tokens", "llama_total_tokens",
]

LONG_COLUMNS = [
    "measurement_id", "run_id", "node", "model", "quant", "exec_mode", "sample_idx", "time_s",
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
                     use_sleep=False, time_source="efimon"):
    """Load one extracted run directory into the wide/long row accumulators.

    The paired ``sleep_efimon_*`` idle baseline is ignored unless ``use_sleep``
    is set; when ignored, the idle-power and baseline-adjusted energy columns
    are left as NaN. ``time_source`` selects which duration populates
    ``exec_time_s`` (see ``aggregate_run``).
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
        key = (info["model_spec"], info["quant"], info.get("rep"))
        if info["kind"].startswith("sleep"):
            if use_sleep:
                sleep_index.setdefault(key, []).append(path)
        else:
            llama_files.append((path, info))
    for path, info in llama_files:
        if info["quant"] not in allowed_quants:
            continue
        sleep_paths = sleep_index.get(
            (info["model_spec"], info["quant"], info.get("rep"))
        ) if use_sleep else None
        result = aggregate_run(path, sleep_paths, run_dir, node_key, info,
                               run_id=run_id, time_source=time_source)
        if result is None:
            continue
        agg, samples, resolved_dts = result
        if not keep_unknown_models and agg["model"] not in KNOWN_MODEL_FAMILIES:
            continue
        wide_rows.append(agg)
        t = 0.0
        for i, (s, delta) in enumerate(zip(samples, resolved_dts)):
            long_rows.append(
                {
                    "measurement_id": agg["measurement_id"],
                    "run_id": agg["run_id"], "node": node_key,
                    "model": agg["model"], "quant": agg["quant"],
                    "exec_mode": agg["exec_mode"], "sample_idx": i, "time_s": round(t, 3),
                    "socket_power_w": s["socket_power"], "psu_power_w": s["psu_power"],
                    "socket_freq_mhz": s["socket_freq"], "system_cpu_pct": s["system_cpu"],
                    "process_cpu_pct": s["process_cpu"], "fan_mean_rpm": s["fan_mean"],
                }
            )
            if not math.isnan(delta):
                t += delta


def build(data_root, out_dir, nodes_filter, keep_unknown_models=False,
          use_sleep=False, time_source="efimon"):
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
                             use_sleep=use_sleep, time_source=time_source)
        finally:
            shutil.rmtree(extract_root, ignore_errors=True)

    seen = set()
    duplicate_ids = set()
    for row in wide_rows:
        mid = row["measurement_id"]
        if mid in seen:
            duplicate_ids.add(mid)
        seen.add(mid)
    for mid in sorted(duplicate_ids):
        print("  WARNING: duplicate measurement_id {}".format(mid))

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

## runs_wide.csv  (one row per measured execution -- the DOE table)

### Factors
| column | description |
|---|---|
| measurement_id | unique identifier for one measured execution |
| run_id | archive/batch identifier shared by measurements from the same collected run |
| repetition | repetition parsed from `_repNN` when present |
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
| avg_socket_power_w / peak_socket_power_w | W | time-weighted mean / max total socket power |
| avg_psu_power_w / peak_psu_power_w | W | time-weighted mean / max total PSU power |
| exec_time_s | s | canonical run time consumed downstream. Selected via `--time-source`: efimon Σdt (default) or llama.cpp total time. |
| efimon_time_s | s | efimon wall time = sum of sample intervals (always the raw efimon window; unreliable on short GPU runs, quantized to the ~3s cadence). |
| generation_tps | tokens/s | llama-cli generation throughput (NA until stdout capture is enabled) |
| prompt_tps | tokens/s | llama-cli prompt-eval throughput (NA until stdout capture is enabled) |
| energy_per_token_j | J/token | PSU energy / measured generated-token count; NA when token count is unavailable |
| tokens_per_joule | tokens/J | measured generated-token count / PSU energy; NA when token count is unavailable |

### llama.cpp wall-clock timings (authoritative run durations)
Parsed from the paired llama.cpp `print_timing` footer. Kept alongside `exec_time_s`
(efimon's sampling window), not as a replacement. NA when no matching log is found.
| column | units | description |
|---|---|---|
| llama_total_time_s | s | end-to-end generation window = prompt eval + token generation (excludes model load) |
| llama_inference_time_s | s | pure compute = prompt_eval + eval time (equals total time when no idle gaps) |
| llama_load_time_s | s | model load time; usually NA (not emitted by the newer `slot print_timing` footer) |
| llama_prompt_eval_time_s | s | prompt evaluation (prefill) time |
| llama_eval_time_s | s | token generation (decode) time |
| llama_prompt_tokens | tokens | prompt tokens evaluated |
| llama_eval_tokens | tokens | generated tokens (decode) |
| llama_total_tokens | tokens | prompt + generated tokens |

### Secondary responses / covariates
| column | units | description |
|---|---|---|
| idle_socket_power_w / idle_psu_power_w | W | mean idle power from paired sleep run |
| avg_cpu_freq_mhz / cpu_freq_sd_mhz | MHz | mean / population sd of per-sample mean socket frequency |
| avg_system_cpu_pct / avg_process_cpu_pct | % | mean system / process CPU usage |
| avg_fan_rpm / peak_fan_rpm | RPM | mean / max fan speed across all fans |
| n_samples | count | number of ~3s efimon samples in the run |
| est_tokens | tokens | generated-token count parsed from llama.cpp timing output; NA when unavailable |

### Notes / limitations
* GPU-specific power is NOT measured; only CPU socket power and whole-node PSU power exist.
* Temperature sensors are not present in the efimon output, so no temperature columns.
* Token counts are not emitted by llama-cli here (only rates), so est_tokens,
  energy_per_token_j and tokens_per_joule are approximations and will be NA until the
  collection scripts capture the `[ Prompt: X t/s | Generation: Y t/s ]` footer.

## samples_long.csv  (one row per raw efimon sample)
Used for time-series stability, anomaly, throttling, and within-run variance views. Raw samples are autocorrelated and are not independent experimental replicates; DOE normality checks must use model residuals from runs_wide.csv. Columns: run_id, node, model,
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