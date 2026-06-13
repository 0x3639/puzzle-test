#!/usr/bin/env python3
"""Summarize JSONL output from runpod/run.sh full."""

from __future__ import annotations

import argparse
import glob
import json
from pathlib import Path
from statistics import mean


ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "out"
WORKLOAD = OUT / "gpu_workload.json"


def default_path() -> Path:
    paths = [Path(path) for path in glob.glob(str(OUT / "runpod_full_*.jsonl"))]
    if not paths:
        raise SystemExit("no out/runpod_full_*.jsonl files found; pass a path explicitly")
    return max(paths, key=lambda path: path.stat().st_mtime)


def expected_total() -> int | None:
    if not WORKLOAD.exists():
        return None
    return json.loads(WORKLOAD.read_text()).get("total_exact_length_combinations")


def load_rows(path: Path) -> list[dict]:
    rows = []
    with path.open() as handle:
        for line_number, line in enumerate(handle, 1):
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError as exc:
                raise SystemExit(f"{path}:{line_number}: invalid JSON: {exc}") from exc
    if not rows:
        raise SystemExit(f"{path}: no JSON rows found")
    return rows


def summarize(path: Path) -> dict:
    rows = load_rows(path)
    intervals = sorted(
        (int(row["start"]), int(row["start"]) + int(row["count"]), row)
        for row in rows
    )

    gaps = []
    overlaps = []
    cursor = intervals[0][0]
    for start, stop, _row in intervals:
        if start > cursor:
            gaps.append({"start": cursor, "stop": start, "count": start - cursor})
        elif start < cursor:
            overlaps.append({"start": start, "stop": min(stop, cursor), "count": min(stop, cursor) - start})
        cursor = max(cursor, stop)

    total = expected_total()
    count_sum = sum(int(row["count"]) for row in rows)
    checksum_sum = sum(int(row["checksum_valid"]) for row in rows)
    elapsed_sum = sum(float(row["elapsed_seconds"]) for row in rows)
    rates = [float(row["combos_per_second"]) for row in rows if float(row.get("combos_per_second", 0)) > 0]
    range_start = intervals[0][0]
    range_stop = max(stop for _start, stop, _row in intervals)

    summary = {
        "path": str(path),
        "chunks": len(rows),
        "range_start": range_start,
        "range_stop": range_stop,
        "range_count": range_stop - range_start,
        "candidate_count_sum": count_sum,
        "expected_total_candidates": total,
        "full_space_covered": (
            total is not None
            and range_start == 0
            and range_stop == total
            and count_sum == total
            and not gaps
            and not overlaps
        ),
        "gaps": gaps[:10],
        "gap_count": len(gaps),
        "overlaps": overlaps[:10],
        "overlap_count": len(overlaps),
        "checksum_valid": checksum_sum,
        "checksum_ratio": checksum_sum / count_sum if count_sum else 0,
        "expected_checksum_approx": total / 16 if total is not None else None,
        "elapsed_seconds_sum": elapsed_sum,
        "weighted_combos_per_second": count_sum / elapsed_sum if elapsed_sum else 0,
        "min_chunk_combos_per_second": min(rates) if rates else 0,
        "mean_chunk_combos_per_second": mean(rates) if rates else 0,
        "max_chunk_combos_per_second": max(rates) if rates else 0,
        "first_chunk": rows[0],
        "last_chunk": rows[-1],
    }
    return summary


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("path", nargs="?", help="JSONL file from runpod/run.sh full")
    parser.add_argument("--output", help="optional JSON summary output path")
    args = parser.parse_args()

    path = Path(args.path) if args.path else default_path()
    if not path.is_absolute():
        path = ROOT / path

    summary = summarize(path)
    text = json.dumps(summary, indent=2)
    print(text)

    if args.output:
        output = Path(args.output)
        if not output.is_absolute():
            output = ROOT / output
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(text + "\n")
        print(f"Wrote {output.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
