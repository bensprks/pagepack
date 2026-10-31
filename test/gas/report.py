"""Renders the gas snapshots written by the benchmarks in test/gas as markdown tables.

Each row's percentages are relative to the first column that has a value for that row.

Usage: python3 test/gas/report.py [snapshots-dir]
"""

import json
import sys
from pathlib import Path

TABLES = [
    {
        "title": "Library: updating existing one-word records in one transaction",
        "label": "Records updated",
        "columns": [
            ("Mapping", "mapping"),
            ("pagepack, no hint", "pagepack"),
            ("pagepack, hinted", "pagepack-hinted"),
        ],
        "rows": [
            "1 record",
            "2 records",
            "10 records",
            "30 records",
            "30 records, 3 pages",
            "2 unpacked records",
        ],
    },
    {
        "title": "ERC-6909 example",
        "label": "Operation",
        "columns": [
            ("Standalone ERC-20s", "erc20-standalone"),
            ("Ledger, mappings", "ledger-mapping"),
            ("Ledger, pagepack", "ledger-pagepack"),
            ("Ledger, pagepack + hints", "ledger-pagepack-hinted"),
        ],
        "rows": [
            "ERC-20 transfer",
            "ERC-6909 transfer",
            "Swap through a pool",
            "Batch settlement, 10 moves",
            "Batch settlement, 30 moves",
        ],
    },
]


def load(directory: Path, name: str) -> dict:
    path = directory / f"{name}.json"
    if not path.exists():
        return {}

    return {key: int(value) for key, value in json.loads(path.read_text()).items()}


def render(table: dict, directory: Path) -> None:
    groups = [load(directory, group) for _, group in table["columns"]]
    headers = [table["label"]] + [title for title, _ in table["columns"]]

    print(f"### {table['title']}\n")
    print("| " + " | ".join(headers) + " |")
    print("| --- |" + " ---: |" * len(table["columns"]))

    for row in table["rows"]:
        values = [group.get(row) for group in groups]
        baseline = next(value for value in values if value is not None)
        cells = []

        for value in values:
            if value is None:
                cells.append("–")
            elif value == baseline:
                cells.append(f"{value:,}")
            else:
                cells.append(f"{value:,} ({(value - baseline) / baseline:+.0%})")

        print(f"| {row} | " + " | ".join(cells) + " |")

    print()


def main() -> None:
    directory = Path(sys.argv[1] if len(sys.argv) > 1 else "snapshots")

    for table in TABLES:
        render(table, directory)


if __name__ == "__main__":
    main()
