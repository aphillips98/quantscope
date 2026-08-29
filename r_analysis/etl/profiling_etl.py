#!/usr/bin/env python3
"""ETL: convert raw Nsight Systems and Linux perf profiling outputs into tidy,
R-friendly tables.

This is an ADDITIVE companion to ``energy_etl.py``. It does not touch the
efimon energy pipeline; it only parses the profiling artefacts collected next to
the energy runs and writes new CSVs that the R stages 09/10 consume.

Discovered inputs (under ``--input``, one sub-dir per run):

  ``llamacpp_<HW>_<date>_<time>_<jobid>/``
    * ``nsight/*.sqlite``            -- exported Nsight Systems databases (GPU runs)
    * ``perf_stat/perf_stat_*.csv``  -- ``perf stat -x,`` counter dumps (CPU runs)

The node/<HW> token maps to the experimental factors (cpu_arch, gpu_arch,
exec_mode) via :mod:`node_map`; model / quant / repetition are parsed from the
file name.

Nsight metrics are produced by shelling out to the installed ``nsys stats`` tool
(``--report gpukernsum,cudaapisum,gpumemtimesum,gpumemsizesum,osrtsum``) on each
``.sqlite`` and parsing its CSV output. If ``nsys`` is unavailable the Nsight
tables are skipped with a warning.

Outputs (default ``r_analysis/data/``):
  * ``perf_counters_long.csv``   one row per (run, perf event)
  * ``perf_runs_wide.csv``       one row per CPU run (derived counter metrics)
  * ``nsight_kernels_long.csv``  one row per (run, CUDA kernel)
  * ``nsight_cuda_api_long.csv`` one row per (run, CUDA API call)
  * ``nsight_gpu_mem_long.csv``  one row per (run, GPU memory operation)
  * ``nsight_osrt_long.csv``     one row per (run, OS runtime call)
  * ``nsight_runs_wide.csv``     one row per GPU run (aggregated GPU metrics)
  * ``profiling_data_dictionary.md`` column documentation

Pure standard library plus a subprocess call to ``nsys``; no third-party deps.
"""

import argparse
import csv
import glob
import math
import os
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from node_map import (  # noqa: E402
    resolve_node,
    resolve_model,
    node_key_from_run_name,
    QUANT_BITS,
)

# ---------------------------------------------------------------------------
# Filename parsing
# ---------------------------------------------------------------------------
QUANT_ALTERNATION = "|".join(sorted(QUANT_BITS, key=len, reverse=True))
# e.g. nsys_gemma-2-9b-it-Q2_K_rep01_20260719_021341_96172.sqlite
#      perf_stat_Meta-Llama-3.1-8B-Instruct-Q8_0_rep01_20260719_022636_87321.csv
PROF_FNAME_RE = re.compile(
    r"^(?P<kind>nsys|perf_stat)_"
    r"(?P<model>.+?)[-.](?P<quant>" + QUANT_ALTERNATION + r")_"
    r"rep(?P<rep>\d+)_(?P<date>\d{8})_(?P<time>\d{6})_(?P<pid>\d+)"
)

# nsys stats reports we request and the "count" column header each one uses.
NSYS_REPORTS = ("gpukernsum", "cudaapisum", "gpumemtimesum",
                "gpumemsizesum", "osrtsum")


def parse_prof_name(fname):
    """Return factor dict parsed from a profiling artefact file name, or None."""
    base = os.path.basename(fname)
    m = PROF_FNAME_RE.match(base)
    if not m:
        return None
    family, size_b = resolve_model(m.group("model"))
    return {
        "kind": m.group("kind"),
        "model_spec": m.group("model"),
        "model": family,
        "model_size_b": size_b,
        "quant": m.group("quant"),
        "quant_bits": QUANT_BITS.get(m.group("quant"), math.nan),
        "rep": int(m.group("rep")),
        "ts": m.group("date") + "_" + m.group("time"),
        "pid": m.group("pid"),
    }


# ---------------------------------------------------------------------------
# perf stat -x, parsing
# ---------------------------------------------------------------------------
# `perf stat -x,` emits comment lines (starting with '#') then rows of:
#   value , unit , event , run_time_ns , pct_measured , derived_value , derived_unit
# value may be "<not counted>" / "<not supported>".
def _num(tok):
    tok = (tok or "").strip()
    if tok in ("", "<not counted>", "<not supported>"):
        return math.nan
    try:
        return float(tok)
    except ValueError:
        return math.nan


def parse_perf_stat(path):
    """Parse a ``perf stat -x,`` CSV into (long_events, wide_metrics)."""
    events = []
    with open(path, newline="") as fh:
        for row in csv.reader(fh):
            if not row or row[0].lstrip().startswith("#"):
                continue
            # pad to the expected 7 fields
            row = (row + [""] * 7)[:7]
            value, unit, event, run_time_ns, pct, dval, dunit = row
            events.append({
                "event": event.strip(),
                "value": _num(value),
                "unit": unit.strip(),
                "run_time_ns": _num(run_time_ns),
                "pct_measured": _num(pct),
                "derived_value": _num(dval),
                "derived_unit": dunit.strip(),
            })

    # Build a name->value lookup (strip the ":u" user-mode suffix for keys).
    def val(name):
        for e in events:
            base = e["event"].split(":")[0]
            if base == name:
                return e["value"]
        return math.nan

    def derived(name):
        for e in events:
            base = e["event"].split(":")[0]
            if base == name:
                return e["derived_value"]
        return math.nan

    # A miss-rate helper: 100 * misses / accesses, falling back to a perf-derived
    # value (e.g. "of all L1-dcache accesses") when the raw ratio is unusable.
    def miss_pct(misses, accesses, fallback_name):
        if (accesses and not math.isnan(accesses) and accesses > 0
                and not math.isnan(misses)):
            return 100.0 * misses / accesses
        return derived(fallback_name)

    cycles = val("cycles")
    instructions = val("instructions")
    branches = val("branches")
    branch_misses = val("branch-misses")
    cache_refs = val("cache-references")
    cache_misses = val("cache-misses")
    task_clock = val("task-clock")  # nanoseconds (raw perf -x task-clock count)

    # Cache hierarchy (present in the second-batch captures; NaN otherwise).
    l1d_loads = val("L1-dcache-loads")
    l1d_load_misses = val("L1-dcache-load-misses")
    l1i_loads = val("L1-icache-loads")
    l1i_load_misses = val("L1-icache-load-misses")
    l2_accesses = val("l2_cache_accesses_from_dc_misses")
    l2_misses = val("l2_cache_misses_from_dc_misses")

    wide = {
        "task_clock_ns": task_clock,
        "cpus_utilized": derived("task-clock"),
        "cycles": cycles,
        "instructions": instructions,
        "ipc": (instructions / cycles) if cycles and not math.isnan(cycles)
                and cycles > 0 and not math.isnan(instructions) else derived("instructions"),
        "cpi": (cycles / instructions) if instructions and not math.isnan(instructions)
                and instructions > 0 and not math.isnan(cycles) else math.nan,
        "ghz": derived("cycles"),
        "branches": branches,
        "branch_misses": branch_misses,
        "branch_miss_pct": (100.0 * branch_misses / branches)
                if branches and not math.isnan(branches) and branches > 0
                and not math.isnan(branch_misses) else derived("branch-misses"),
        "cache_references": cache_refs,
        "cache_misses": cache_misses,
        "cache_miss_pct": (100.0 * cache_misses / cache_refs)
                if cache_refs and not math.isnan(cache_refs) and cache_refs > 0
                and not math.isnan(cache_misses) else derived("cache-misses"),
        "l1d_loads": l1d_loads,
        "l1d_load_misses": l1d_load_misses,
        "l1d_miss_pct": miss_pct(l1d_load_misses, l1d_loads,
                                 "L1-dcache-load-misses"),
        "l1i_loads": l1i_loads,
        "l1i_load_misses": l1i_load_misses,
        "l1i_miss_pct": miss_pct(l1i_load_misses, l1i_loads,
                                 "L1-icache-load-misses"),
        "l2_accesses": l2_accesses,
        "l2_misses": l2_misses,
        "l2_miss_pct": miss_pct(l2_misses, l2_accesses,
                                "l2_cache_misses_from_dc_misses"),
        "context_switches": val("context-switches"),
        "cpu_migrations": val("cpu-migrations"),
        "page_faults": val("page-faults"),
    }
    return events, wide


# ---------------------------------------------------------------------------
# Nsight (nsys stats) parsing
# ---------------------------------------------------------------------------
def run_nsys_stats(sqlite_path, nsys_bin, tmp_root):
    """Run ``nsys stats`` for all reports; return {report: [dict rows]} or {}."""
    stem = os.path.splitext(os.path.basename(sqlite_path))[0]
    out_base = os.path.join(tmp_root, stem)
    cmd = [nsys_bin, "stats"]
    for rep in NSYS_REPORTS:
        cmd += ["-r", rep]
    cmd += ["--format", "csv", "-o", out_base, sqlite_path]
    try:
        subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL)
    except (subprocess.CalledProcessError, OSError) as exc:
        sys.stderr.write("  [nsys] failed on %s: %s\n"
                         % (os.path.basename(sqlite_path), exc))
        return {}

    out = {}
    for rep in NSYS_REPORTS:
        csv_path = "%s_%s.csv" % (out_base, rep)
        if not os.path.exists(csv_path):
            continue
        with open(csv_path, newline="") as fh:
            out[rep] = list(csv.DictReader(fh))
        os.remove(csv_path)
    return out


def _f(row, key):
    """Float accessor tolerant to thousands separators / blanks."""
    v = row.get(key, "")
    if v is None:
        return math.nan
    v = str(v).replace(",", "").strip()
    if v in ("", "-"):
        return math.nan
    try:
        return float(v)
    except ValueError:
        return math.nan


def summarize_nsight(reports):
    """Aggregate the per-report nsys rows into a single wide GPU-metrics dict."""
    kern = reports.get("gpukernsum", [])
    api = reports.get("cudaapisum", [])
    memt = reports.get("gpumemtimesum", [])
    mems = reports.get("gpumemsizesum", [])

    kern_total = sum(_f(r, "Total Time (ns)") for r in kern if not math.isnan(_f(r, "Total Time (ns)")))
    kern_instances = sum(_f(r, "Instances") for r in kern if not math.isnan(_f(r, "Instances")))
    top_kernel = kern[0] if kern else None

    api_total = sum(_f(r, "Total Time (ns)") for r in api if not math.isnan(_f(r, "Total Time (ns)")))

    def api_time(name):
        for r in api:
            if r.get("Name", "").strip() == name:
                return _f(r, "Total Time (ns)")
        return math.nan

    def mem_time(op):
        for r in memt:
            if op in r.get("Operation", ""):
                return _f(r, "Total Time (ns)")
        return math.nan

    def mem_size(op):
        for r in mems:
            if op in r.get("Operation", ""):
                return _f(r, "Total (MB)")
        return math.nan

    memcpy_total_ns = sum(_f(r, "Total Time (ns)") for r in memt
                          if "memcpy" in r.get("Operation", "").lower()
                          and not math.isnan(_f(r, "Total Time (ns)")))

    return {
        "kernel_total_time_ns": kern_total,
        "kernel_instances": kern_instances,
        "n_distinct_kernels": len(kern),
        "top_kernel_name": (top_kernel.get("Name", "") if top_kernel else ""),
        "top_kernel_time_pct": (_f(top_kernel, "Time (%)") if top_kernel else math.nan),
        "cuda_api_total_time_ns": api_total,
        "cuda_memcpy_time_ns": api_time("cudaMemcpyAsync"),
        "cuda_sync_time_ns": api_time("cudaStreamSynchronize"),
        "cuda_launch_time_ns": api_time("cudaLaunchKernel"),
        "gpu_memcpy_time_ns": memcpy_total_ns,
        "gpu_memcpy_htod_ns": mem_time("HtoD"),
        "gpu_memcpy_dtoh_ns": mem_time("DtoH"),
        "gpu_memcpy_htod_mb": mem_size("HtoD"),
        "gpu_memcpy_dtoh_mb": mem_size("DtoH"),
        "gpu_memset_mb": mem_size("memset"),
    }


# ---------------------------------------------------------------------------
# CSV writing
# ---------------------------------------------------------------------------
def _fmt(v):
    if isinstance(v, float):
        return "" if math.isnan(v) else repr(round(v, 6))
    return v


def write_csv(path, columns, rows):
    if not rows:
        sys.stderr.write("  [skip] %s: no rows\n" % os.path.basename(path))
        return
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(columns)
        for r in rows:
            w.writerow([_fmt(r.get(c, "")) for c in columns])
    sys.stderr.write("  [csv] %s (%d rows)\n" % (os.path.basename(path), len(rows)))


# ---------------------------------------------------------------------------
# Column schemas
# ---------------------------------------------------------------------------
FACTOR_COLS = ["run_id", "node", "cpu_arch", "gpu_arch", "exec_mode",
               "model", "model_size_b", "quant", "quant_bits", "rep", "timestamp"]

PERF_LONG_COLS = FACTOR_COLS + ["event", "value", "unit", "run_time_ns",
                                "pct_measured", "derived_value", "derived_unit"]
PERF_WIDE_COLS = FACTOR_COLS + [
    "task_clock_ns", "cpus_utilized", "cycles", "instructions", "ipc", "cpi",
    "ghz", "branches", "branch_misses", "branch_miss_pct", "cache_references",
    "cache_misses", "cache_miss_pct",
    "l1d_loads", "l1d_load_misses", "l1d_miss_pct",
    "l1i_loads", "l1i_load_misses", "l1i_miss_pct",
    "l2_accesses", "l2_misses", "l2_miss_pct",
    "context_switches", "cpu_migrations", "page_faults"]

KERN_LONG_COLS = FACTOR_COLS + ["kernel", "time_pct", "total_time_ns",
                                "instances", "avg_ns", "med_ns", "min_ns",
                                "max_ns", "stddev_ns"]
API_LONG_COLS = FACTOR_COLS + ["name", "time_pct", "total_time_ns", "num_calls",
                               "avg_ns", "med_ns", "min_ns", "max_ns", "stddev_ns"]
MEM_LONG_COLS = FACTOR_COLS + ["operation", "time_pct", "total_time_ns", "count",
                               "total_mb", "avg_ns", "min_ns", "max_ns"]
OSRT_LONG_COLS = API_LONG_COLS
NSIGHT_WIDE_COLS = FACTOR_COLS + [
    "kernel_total_time_ns", "kernel_instances", "n_distinct_kernels",
    "top_kernel_name", "top_kernel_time_pct", "cuda_api_total_time_ns",
    "cuda_memcpy_time_ns", "cuda_sync_time_ns", "cuda_launch_time_ns",
    "gpu_memcpy_time_ns", "gpu_memcpy_htod_ns", "gpu_memcpy_dtoh_ns",
    "gpu_memcpy_htod_mb", "gpu_memcpy_dtoh_mb", "gpu_memset_mb"]


def _factor_row(node_key, meta):
    node = resolve_node(node_key)
    return {
        "run_id": meta["run_id"],
        "node": node_key,
        "cpu_arch": node["cpu_arch"],
        "gpu_arch": node["gpu_arch"],
        "exec_mode": node["exec_mode"],
        "model": meta["model"],
        "model_size_b": meta["model_size_b"],
        "quant": meta["quant"],
        "quant_bits": meta["quant_bits"],
        "rep": meta["rep"],
        "timestamp": meta["ts"],
    }


# ---------------------------------------------------------------------------
# Run discovery / processing
# ---------------------------------------------------------------------------
def process_run_dir(run_dir, nsys_bin, tmp_root, do_perf, do_nsight, tables):
    node_key = node_key_from_run_name(os.path.basename(run_dir))
    if node_key is None:
        return

    # ---- perf stat (CPU runs) --------------------------------------------
    if do_perf:
        for path in sorted(glob.glob(os.path.join(run_dir, "perf_stat",
                                                   "perf_stat_*.csv"))):
            meta = parse_prof_name(path)
            if meta is None:
                continue
            meta["run_id"] = os.path.splitext(os.path.basename(path))[0]
            base = _factor_row(node_key, meta)
            events, wide = parse_perf_stat(path)
            for e in events:
                row = dict(base); row.update(e)
                tables["perf_long"].append(row)
            row = dict(base); row.update(wide)
            tables["perf_wide"].append(row)

    # ---- Nsight (GPU runs) -----------------------------------------------
    if do_nsight and nsys_bin:
        for path in sorted(glob.glob(os.path.join(run_dir, "nsight",
                                                  "*.sqlite"))):
            meta = parse_prof_name(path)
            if meta is None:
                continue
            meta["run_id"] = os.path.splitext(os.path.basename(path))[0]
            base = _factor_row(node_key, meta)
            reports = run_nsys_stats(path, nsys_bin, tmp_root)
            if not reports:
                continue

            for r in reports.get("gpukernsum", []):
                row = dict(base); row.update({
                    "kernel": r.get("Name", ""),
                    "time_pct": _f(r, "Time (%)"),
                    "total_time_ns": _f(r, "Total Time (ns)"),
                    "instances": _f(r, "Instances"),
                    "avg_ns": _f(r, "Avg (ns)"), "med_ns": _f(r, "Med (ns)"),
                    "min_ns": _f(r, "Min (ns)"), "max_ns": _f(r, "Max (ns)"),
                    "stddev_ns": _f(r, "StdDev (ns)"),
                })
                tables["kernels"].append(row)

            for r in reports.get("cudaapisum", []):
                row = dict(base); row.update({
                    "name": r.get("Name", ""),
                    "time_pct": _f(r, "Time (%)"),
                    "total_time_ns": _f(r, "Total Time (ns)"),
                    "num_calls": _f(r, "Num Calls"),
                    "avg_ns": _f(r, "Avg (ns)"), "med_ns": _f(r, "Med (ns)"),
                    "min_ns": _f(r, "Min (ns)"), "max_ns": _f(r, "Max (ns)"),
                    "stddev_ns": _f(r, "StdDev (ns)"),
                })
                tables["cuda_api"].append(row)

            for r in reports.get("osrtsum", []):
                row = dict(base); row.update({
                    "name": r.get("Name", ""),
                    "time_pct": _f(r, "Time (%)"),
                    "total_time_ns": _f(r, "Total Time (ns)"),
                    "num_calls": _f(r, "Num Calls"),
                    "avg_ns": _f(r, "Avg (ns)"), "med_ns": _f(r, "Med (ns)"),
                    "min_ns": _f(r, "Min (ns)"), "max_ns": _f(r, "Max (ns)"),
                    "stddev_ns": _f(r, "StdDev (ns)"),
                })
                tables["osrt"].append(row)

            # merge time + size memory reports keyed on Operation
            size_by_op = {r.get("Operation", ""): r
                          for r in reports.get("gpumemsizesum", [])}
            for r in reports.get("gpumemtimesum", []):
                op = r.get("Operation", "")
                sz = size_by_op.get(op, {})
                row = dict(base); row.update({
                    "operation": op,
                    "time_pct": _f(r, "Time (%)"),
                    "total_time_ns": _f(r, "Total Time (ns)"),
                    "count": _f(r, "Count"),
                    "total_mb": _f(sz, "Total (MB)"),
                    "avg_ns": _f(r, "Avg (ns)"),
                    "min_ns": _f(r, "Min (ns)"), "max_ns": _f(r, "Max (ns)"),
                })
                tables["gpu_mem"].append(row)

            row = dict(base); row.update(summarize_nsight(reports))
            tables["nsight_wide"].append(row)


# ---------------------------------------------------------------------------
# Data dictionary
# ---------------------------------------------------------------------------
DICTIONARY = """# Profiling dataset dictionary

Generated by `etl/build_dataset.py` (profiling pipeline; additive to the efimon energy
pipeline). All tables share the leading factor columns:

| column | description |
|--------|-------------|
| run_id | unique id (profiling artefact file stem) |
| node | measurement node key (e.g. EPYC008, GPU_V100) |
| cpu_arch / gpu_arch / exec_mode | factor levels resolved from the node |
| model / model_size_b | model family and total parameter count (billions) |
| quant / quant_bits | quantization label and effective bits-per-weight |
| rep | repetition index parsed from the file name |
| timestamp | run timestamp (YYYYMMDD_HHMMSS) |

## perf_counters_long.csv
One row per (run, perf event). `value` is the raw counter, `derived_value` +
`derived_unit` the perf-computed rate (GHz, insn per cycle, M/sec, %).

## perf_runs_wide.csv
One row per CPU (perf) run. Derived: `ipc` (instructions/cycles), `cpi`
(cycles/instructions), `ghz`, `branch_miss_pct`, `cache_miss_pct` (last-level
cache), plus the cache hierarchy `l1d_miss_pct` (L1 data), `l1i_miss_pct`
(L1 instruction) and `l2_miss_pct` (L2 from data-cache misses, AMD), their raw
load/miss counts, and the base raw counters plus `task_clock_ns`. Cache-hierarchy
columns are populated only for captures that recorded those events (second batch
onward) and were sampled via counter multiplexing (rates remain valid); they are
empty for earlier runs.

## nsight_kernels_long.csv
One row per (run, CUDA kernel) from `nsys stats -r gpukernsum`.

## nsight_cuda_api_long.csv
One row per (run, CUDA API call) from `-r cudaapisum`.

## nsight_gpu_mem_long.csv
One row per (run, GPU memory operation): time (`gpumemtimesum`) joined with
transferred volume in MB (`gpumemsizesum`).

## nsight_osrt_long.csv
One row per (run, OS runtime call) from `-r osrtsum`.

## nsight_runs_wide.csv
One row per GPU (Nsight) run: aggregated kernel time, CUDA API time breakdown
(memcpy / sync / launch), and host<->device transfer time and volume.
"""
DEFAULT_INPUT = os.path.normpath(os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "..", "efimon_data", "nsight"))
DEFAULT_OUTDIR = os.path.normpath(os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "data"))


def _locate_run_dir(extract_root):
    """Return the run dir inside an extracted archive.

    Handles the common case where the whole ``llamacpp_*`` dir was zipped (a
    single top-level directory) and the flat case (``extract_root`` is the run
    dir itself).
    """
    entries = [os.path.join(extract_root, e) for e in os.listdir(extract_root)]
    subdirs = [e for e in entries if os.path.isdir(e)]
    files = [e for e in entries if os.path.isfile(e)]
    if len(subdirs) == 1 and not files:
        return subdirs[0]
    return extract_root


def build(input_dir=DEFAULT_INPUT, outdir=DEFAULT_OUTDIR,
          nsys=None, do_nsight=True, do_perf=True):
    """Build the perf + Nsight profiling tables under ``outdir``.

    Discovers both already-extracted ``llamacpp_*`` run dirs and zipped
    ``llamacpp_*.zip`` run archives (extracted to a temp dir, cleaned up after).
    When a run exists both unzipped and as a ``.zip`` the unzipped copy wins, so
    it is never counted twice. Returns 0 on success, 1 when nothing is found.
    """
    if nsys is None:
        nsys = shutil.which("nsys") or "nsys"

    run_dirs = sorted(
        d for d in glob.glob(os.path.join(input_dir, "**", "llamacpp_*"),
                             recursive=True)
        if os.path.isdir(d))
    dir_names = {os.path.basename(d) for d in run_dirs}
    zip_paths = sorted(
        z for z in glob.glob(os.path.join(input_dir, "**", "llamacpp_*.zip"),
                             recursive=True)
        if os.path.splitext(os.path.basename(z))[0] not in dir_names)

    if not run_dirs and not zip_paths:
        sys.stderr.write("No llamacpp_* run dirs or .zip archives under %s\n"
                         % input_dir)
        return 1

    nsys_bin = nsys if (do_nsight and shutil.which(nsys) or
                        (do_nsight and os.path.exists(nsys))) else None
    if do_nsight and nsys_bin is None:
        sys.stderr.write("WARNING: nsys not found (%r); skipping Nsight tables.\n"
                         % nsys)

    tables = {k: [] for k in ("perf_long", "perf_wide", "kernels", "cuda_api",
                              "osrt", "gpu_mem", "nsight_wide")}

    tmp_root = tempfile.mkdtemp(prefix="nsys_stats_")
    try:
        for rd in run_dirs:
            sys.stderr.write("Run dir: %s\n" % os.path.basename(rd))
            process_run_dir(rd, nsys_bin, tmp_root,
                            do_perf=do_perf, do_nsight=do_nsight,
                            tables=tables)
        for zp in zip_paths:
            sys.stderr.write("Run zip: %s\n" % os.path.basename(zp))
            extract_root = tempfile.mkdtemp(prefix="prof_unzip_")
            try:
                try:
                    with zipfile.ZipFile(zp) as zf:
                        zf.extractall(extract_root)
                except (zipfile.BadZipFile, OSError) as exc:
                    sys.stderr.write("  WARNING: skipping unreadable zip %s: %s\n"
                                     % (zp, exc))
                    continue
                run_dir = _locate_run_dir(extract_root)
                process_run_dir(run_dir, nsys_bin, tmp_root,
                                do_perf=do_perf, do_nsight=do_nsight,
                                tables=tables)
            finally:
                shutil.rmtree(extract_root, ignore_errors=True)
    finally:
        shutil.rmtree(tmp_root, ignore_errors=True)

    out = outdir
    write_csv(os.path.join(out, "perf_counters_long.csv"), PERF_LONG_COLS, tables["perf_long"])
    write_csv(os.path.join(out, "perf_runs_wide.csv"), PERF_WIDE_COLS, tables["perf_wide"])
    write_csv(os.path.join(out, "nsight_kernels_long.csv"), KERN_LONG_COLS, tables["kernels"])
    write_csv(os.path.join(out, "nsight_cuda_api_long.csv"), API_LONG_COLS, tables["cuda_api"])
    write_csv(os.path.join(out, "nsight_osrt_long.csv"), OSRT_LONG_COLS, tables["osrt"])
    write_csv(os.path.join(out, "nsight_gpu_mem_long.csv"), MEM_LONG_COLS, tables["gpu_mem"])
    write_csv(os.path.join(out, "nsight_runs_wide.csv"), NSIGHT_WIDE_COLS, tables["nsight_wide"])

    with open(os.path.join(out, "profiling_data_dictionary.md"), "w") as fh:
        fh.write(DICTIONARY)
    sys.stderr.write("Done. Profiling outputs in %s\n" % out)
    return 0
