"""Renders the gas snapshots written by PagePackGas.t.sol as a markdown table.

Usage: python3 test/gas/report.py [snapshots-dir]
"""

import json
import sys
from pathlib import Path

SCENARIOS = [
    "1 record",
    "2 records",
    "10 records",
    "30 records",
    "30 records, 3 pages",
    "2 unpacked records",
]


def load(directory: Path, name: str) -> dict:
    path = directory / f"{name}.json"
    return {key: int(value) for key, value in json.loads(path.read_text()).items()}


def change(value: int, baseline: int) -> str:
    return f"{value:,} ({(value - baseline) / baseline:+.0%})"


def main() -> None:
    directory = Path(sys.argv[1] if len(sys.argv) > 1 else "snapshots")

    mapping = load(directory, "mapping")
    packed = load(directory, "pagepack")
    hinted = load(directory, "pagepack-hinted")

    print("| Records updated in one tx | Mapping | pagepack, no hint | pagepack, hinted |")
    print("| --- | ---: | ---: | ---: |")

    for scenario in SCENARIOS:
        baseline = mapping[scenario]
        no_hint = change(packed[scenario], baseline)
        with_hint = change(hinted[scenario], baseline) if scenario in hinted else "n/a"

        print(f"| {scenario} | {baseline:,} | {no_hint} | {with_hint} |")


if __name__ == "__main__":
    main()
