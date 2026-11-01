"""Renders the gas snapshots written by the benchmarks in test/gas as markdown tables.

Each row's percentages are relative to the first column that has a value for that row, or to
the first row when a table sets compare_to_first_row. Tables whose columns aren't alternatives,
such as directory sizes, set percentages to False.

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
        "title": "Library: rebalancing",
        "label": "Operation",
        "columns": [("pagepack", "pagepack-rebalance")],
        "rows": ["Move a 3-word record within a page"],
    },
    {
        "title": "Library: rebalancing by number of packed records (one-word records)",
        "label": "Operation",
        "columns": [
            ("64", "pagepack-rebalance-64"),
            ("512", "pagepack-rebalance-512"),
            ("1,016", "pagepack-rebalance-1016"),
        ],
        "percentages": False,
        "rows": [
            "Empty rebalance",
            "Resubmit the whole layout",
            "Move one record",
            "Swap two records",
            "Evict one record",
            "Replace one record with another",
            "Pack every record",
        ],
    },
    {
        "title": "Exchange example",
        "label": "Operation",
        "columns": [
            ("Mappings", "exchange-mapping"),
            ("pagepack", "exchange-pagepack"),
            ("pagepack + hints", "exchange-pagepack-hinted"),
        ],
        "rows": [
            "Re-quote 1 order, maker in 6 markets",
            "Re-quote 3 orders, one market",
            "Taker vs 3 makers",
            "Taker vs 14 makers",
        ],
    },
    {
        "title": "Exchange example: order slot reuse",
        "label": "Operation",
        "columns": [("Mappings", "exchange-slots")],
        "compare_to_first_row": True,
        "rows": [
            "New order in a never-used slot",
            "New order in a reused slot",
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

    first_row = [group.get(table["rows"][0]) for group in groups]

    for row in table["rows"]:
        values = [group.get(row) for group in groups]

        if table.get("compare_to_first_row"):
            baseline = first_row[0]
        else:
            baseline = next(value for value in values if value is not None)
        cells = []

        for value in values:
            if value is None:
                cells.append("–")
            elif value == baseline or not table.get("percentages", True):
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
