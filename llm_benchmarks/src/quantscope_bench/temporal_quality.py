"""Non-invasive temporal quality audit for benchmark request windows.

Reports wall-clock gaps between requests, not inferred GPU idle time. All
timestamps are Unix nanoseconds; no sample latency or scoring is modified.
"""
from __future__ import annotations

import csv
import json
import math
from collections import defaultdict
from pathlib import Path

FIELDS = ('model_name','run_id','benchmark','window_duration_seconds',
          'request_count','sum_request_latency_seconds','request_union_seconds',
          'time_without_requests_seconds','largest_gap_seconds',
          'largest_internal_gap_seconds','gap_count_over_threshold',
          'gap_threshold_seconds','uncovered_fraction','status','warnings')


def _seconds(value):
    try:
        v = float(value)
        return v if math.isfinite(v) else None
    except (TypeError, ValueError):
        return None


def audit_temporal_quality(requests, windows, *, gap_threshold_seconds=2.0,
                           uncovered_fraction_threshold=0.25):
    """Return per-window diagnostics without modifying input records.

    Request intervals are clipped to benchmark windows; overlapping intervals
    are merged to avoid double-counting concurrent requests. Requests that
    cannot be assigned unambiguously to a benchmark are not counted.
    """
    grouped = defaultdict(list)
    for request in requests:
        grouped[(str(request.get('model_name')), str(request.get('run_id')))].append(request)
    rows = []
    for window in windows:
        model = str(window.get('model_name'))
        run = str(window.get('run_id'))
        benchmark = str(window.get('benchmark'))
        start = _seconds(window.get('start_timestamp_ns'))
        end = _seconds(window.get('end_timestamp_ns'))
        warnings = []
        intervals = []
        if start is None or end is None or end <= start:
            warnings.append('invalid_window_timestamps')
        else:
            for req in grouped[(model, run)]:
                a = _seconds(req.get('start_timestamp_ns'))
                b = _seconds(req.get('end_timestamp_ns'))
                if a is None or b is None or b <= a:
                    continue
                if a >= start and b <= end:
                    intervals.append((a,b))
                elif a < end and b > start:
                    warnings.append('request_crosses_window_boundary')
        intervals.sort()
        duration = (end-start)/1e9 if start is not None and end is not None and end > start else None
        total_latency = sum((b-a)/1e9 for a,b in intervals)
        merged = []
        for a,b in intervals:
            if merged and a <= merged[-1][1]:
                merged[-1] = (merged[-1][0],max(b,merged[-1][1]))
            else:
                merged.append((a,b))
        covered = sum((b-a)/1e9 for a,b in merged)
        gaps = []
        internal_gaps = []
        if duration is not None:
            cursor = start
            for a,b in merged:
                if a > cursor:
                    gap = (a-cursor)/1e9
                    gaps.append(gap)
                    if cursor != start:
                        internal_gaps.append(gap)
                cursor = max(cursor,b)
            if end > cursor:
                gaps.append((end-cursor)/1e9)
            uncovered = max(0.0,duration-covered)
            fraction = uncovered/duration
        else:
            uncovered = fraction = None
        if not intervals:
            warnings.append('no_timestamped_requests_in_window')
        if internal_gaps and max(internal_gaps) > gap_threshold_seconds:
            warnings.append('long_internal_request_gap')
        if fraction is not None and fraction > uncovered_fraction_threshold:
            warnings.append('high_uncovered_fraction')
        rows.append(dict(model_name=model,run_id=run,benchmark=benchmark,
            window_duration_seconds=duration,request_count=len(intervals),
            sum_request_latency_seconds=total_latency,request_union_seconds=covered,
            time_without_requests_seconds=uncovered,
            largest_gap_seconds=max(gaps,default=0.0),
            largest_internal_gap_seconds=max(internal_gaps,default=0.0),
            gap_count_over_threshold=sum(g>gap_threshold_seconds for g in gaps),
            gap_threshold_seconds=gap_threshold_seconds,uncovered_fraction=fraction,
            status='warning' if warnings else 'ok',warnings=';'.join(sorted(set(warnings)))))
    return rows


def write_temporal_quality(output_dir, requests, windows, **kwargs):
    """Write additive CSV/JSON reports. Does not change existing artifacts."""
    output_dir = Path(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    rows = audit_temporal_quality(requests, windows, **kwargs)
    with (output_dir/'temporal_quality.csv').open('w',newline='',encoding='utf-8') as handle:
        writer = csv.DictWriter(handle,fieldnames=FIELDS)
        writer.writeheader()
        writer.writerows(rows)
    with (output_dir/'temporal_quality.json').open('w',encoding='utf-8') as handle:
        json.dump({'schema_version':1,'windows':rows,
                   'summary':{'total_windows':len(rows),
                              'warning_windows':sum(row['status']=='warning' for row in rows)}},
                  handle,indent=2,allow_nan=False)
    return rows


def main(argv=None):
    import argparse
    parser = argparse.ArgumentParser(description='Audit existing Quantscope benchmark windows')
    parser.add_argument('run_directory',type=Path)
    parser.add_argument('--gap-threshold-seconds',type=float,default=2.0)
    args = parser.parse_args(argv)
    root = args.run_directory
    with (root/'instrumentation'/'benchmark_windows.json').open(encoding='utf-8') as handle:
        data = json.load(handle)
    with (root/'performance'/'performance_requests.csv').open(newline='',encoding='utf-8') as handle:
        requests = list(csv.DictReader(handle))
    rows = write_temporal_quality(root/'instrumentation',requests,data['windows'],
                                  gap_threshold_seconds=args.gap_threshold_seconds)
    print(f"Audited {len(rows)} windows; {sum(r['status']=='warning' for r in rows)} warnings")


if __name__ == '__main__':
    main()
