"""Renders the gas snapshots written by the benchmarks in test/gas as markdown tables.

Each row's percentages are relative to the first column that has a value for that row, or to
the first row when a table sets compare_to_first_row. Tables whose columns aren't alternatives,
such as directory sizes, set percentages to False. A table can set divide_by to show each value
per item, e.g. per record when a benchmark packs several at once. A column can name a third
value, a scale for snapshots kept in hundredths, which it shows with two decimals.

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
            "2 unpacked records, home-hint space",
        ],
    },
    {
        "title": "Library: directory search, page already loaded (1,024 searches each)",
        "label": "Directory and record",
        "columns": [
            ("Probes, mean", "pagepack-search-probes", 100),
            ("Probes, max", "pagepack-search-probes-max"),
            ("Gas, mean", "pagepack-search"),
            ("Gas, max", "pagepack-search-max"),
        ],
        "percentages": False,
        "rows": [
            "64 packed, packed record",
            "64 packed, record at home",
            "512 packed, packed record",
            "512 packed, record at home",
            "1016 packed, packed record",
            "1016 packed, record at home",
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
        "title": "Library: packing records from home, per record (16 per call)",
        "label": "Record shape",
        "columns": [("pagepack", "pagepack-packing")],
        "percentages": False,
        "divide_by": 16,
        "rows": [
            "1-word records",
            "3-word records",
            "8-word records",
            "8-word records, 1 word set",
            "1-word records, never written",
            "1-word records, home-hint space",
            "1-word records, never written, home-hint space",
        ],
    },
    {
        "title": "Library: storage left by 512 nonzero one-word records",
        "label": "Layout",
        "columns": [
            ("Live storage words", "footprint-words"),
            ("Occupied pages", "footprint-pages"),
        ],
        "percentages": False,
        "rows": [
            "Mapping",
            "pagepack, nothing packed",
            "pagepack, all packed",
            "pagepack with home hints, all packed",
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
    groups = [load(directory, column[1]) for column in table["columns"]]
    scales = [column[2] if len(column) > 2 else None for column in table["columns"]]
    headers = [table["label"]] + [column[0] for column in table["columns"]]

    print(f"### {table['title']}\n")
    print("| " + " | ".join(headers) + " |")
    print("| --- |" + " ---: |" * len(table["columns"]))

    first_row = [group.get(table["rows"][0]) for group in groups]

    for row in table["rows"]:
        values = [group.get(row) for group in groups]

        if table.get("divide_by"):
            values = [None if v is None else round(v / table["divide_by"]) for v in values]

        if table.get("compare_to_first_row"):
            baseline = first_row[0]
        else:
            baseline = next(value for value in values if value is not None)
        cells = []

        for value, scale in zip(values, scales):
            if value is None:
                cells.append("–")
            elif scale:
                cells.append(f"{value / scale:,.2f}")
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
