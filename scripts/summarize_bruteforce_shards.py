#!/usr/bin/env python3
"""Summarize constrained seed-word brute-force shard outputs."""

from __future__ import annotations

import argparse
import glob
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "out"


def load_results(pattern: str) -> list[dict]:
    paths = sorted(Path(path) for path in glob.glob(pattern))
    results = []
    for path in paths:
        try:
            result = json.loads(path.read_text())
        except json.JSONDecodeError as exc:
            raise SystemExit(f"could not parse {path}: {exc}") from exc
        result["_path"] = str(path)
        results.append(result)
    return results


def summarize(results: list[dict], shard_count: int | None) -> dict:
    completed = [result for result in results if not result.get("dry_run")]
    hits = [
        {"path": result["_path"], **hit}
        for result in completed
        for hit in result.get("hits", [])
    ]
    seen_indices = {
        result.get("shard_index")
        for result in completed
        if isinstance(result.get("shard_index"), int)
    }
    missing = []
    if shard_count is not None:
        missing = [index for index in range(shard_count) if index not in seen_indices]

    return {
        "files_read": len(results),
        "completed_result_files": len(completed),
        "total_combos_seen": sum(result.get("combos_seen", 0) for result in completed),
        "total_assigned_combinations": sum(
            result.get("assigned_exact_length_combinations", 0) for result in completed
        ),
        "total_checksum_valid_phrases": sum(
            result.get("checksum_valid_phrases", 0) for result in completed
        ),
        "total_address_derivations": sum(
            result.get("address_derivations", 0) for result in completed
        ),
        "hits": hits,
        "missing_shard_indices": missing,
    }


def write_report(summary: dict, output: Path) -> None:
    lines = [
        "# Brute Force Shard Summary",
        "",
        "```json",
        json.dumps(summary, indent=2),
        "```",
        "",
    ]
    output.write_text("\n".join(lines))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--glob", default=str(OUT / "length_shard_*.json"))
    parser.add_argument("--shard-count", type=int)
    parser.add_argument("--output", default=str(OUT / "bruteforce_shard_summary.md"))
    args = parser.parse_args()

    results = load_results(args.glob)
    summary = summarize(results, args.shard_count)
    output = Path(args.output)
    if not output.is_absolute():
        output = ROOT / output
    write_report(summary, output)
    print(json.dumps(summary, indent=2))
    print(f"Wrote {output.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
