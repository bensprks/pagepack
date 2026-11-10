"""Renders the gas snapshots written by the benchmarks in test/gas as markdown tables.

Each row's percentages are relative to the first column that has a value for that row, or to
the first row when a table sets compare_to_first_row. Tables whose columns aren't alternatives,
such as directory sizes, set percentages to False. A table can set divide_by to show each value
per item, e.g. per entry when a benchmark packs several at once. A column can name a third
value, a scale for snapshots kept in hundredths, which it shows with two decimals.

Usage: python3 test/gas/report.py [snapshots-dir]
"""

import json
import sys
from pathlib import Path

TABLES = [
    {
        "title": "Library: updating existing one-slot entries in one transaction",
        "label": "Entries updated",
        "columns": [
            ("Regular mapping", "mapping"),
            ("pagepack, no hint", "pagepack"),
            ("pagepack, hinted", "pagepack-hinted"),
        ],
        "rows": [
            "1 entry",
            "2 entries",
            "10 entries",
            "30 entries",
            "64 entries, a full page",
            "30 entries, 3 pages",
            "2 unpacked entries",
            "2 unpacked entries, home-hint map",
        ],
    },
    {
        "title": "Library: the same update by hint style",
        "label": "Entries updated",
        "columns": [
            ("No hint", "pagepack"),
            ("`useHints`, 5 bytes a hint", "pagepack-hinted-loaded"),
            ("`find(key, hint)`, a word a hint", "pagepack-hinted-words"),
            ("`find(key, hint)`, 2 bytes a hint", "pagepack-hinted"),
        ],
        "rows": [
            "1 entry",
            "10 entries",
            "30 entries",
            "64 entries, a full page",
        ],
    },
    {
        "title": "Library: updating packed one-slot entries over 16 key sets",
        "label": "Entries updated",
        "columns": [
            ("No hint, mean", "pagepack-key-sets"),
            ("No hint, lowest", "pagepack-key-sets-lowest"),
            ("No hint, highest", "pagepack-key-sets-highest"),
            ("Hinted, mean", "pagepack-key-sets-hinted"),
        ],
        "percentages": False,
        "rows": ["10 entries", "64 entries, a full page"],
    },
    {
        "title": "Library: directory search, page already loaded (1,024 searches each)",
        "label": "Directory and entry",
        "columns": [
            ("Probes, mean", "pagepack-search-probes", 100),
            ("Probes, max", "pagepack-search-probes-max"),
            ("Gas, mean", "pagepack-search"),
            ("Gas, max", "pagepack-search-max"),
        ],
        "percentages": False,
        "rows": [
            "64 packed, packed entry",
            "64 packed, entry at home",
            "512 packed, packed entry",
            "512 packed, entry at home",
            "1016 packed, packed entry",
            "1016 packed, entry at home",
        ],
    },
    {
        "title": "Library: rebalancing",
        "label": "Operation",
        "columns": [("pagepack", "pagepack-rebalance")],
        "percentages": False,
        "rows": [
            "Move a 3-slot entry within a page",
            "Pack a 1-slot entry into a gap",
            "Pack a 2-slot entry, moving 62 slots",
            "Pack a 2-slot entry into a gap",
            "Pack a 2-slot entry, moving 32 entries",
        ],
    },
    {
        "title": "Library: spending from two-slot accounts under one-slot approvals, hinted",
        "label": "Accounts in one transaction",
        "columns": [
            ("Mappings", "mixed-mappings"),
            ("Two maps", "mixed-two-maps"),
            ("One map, width 2", "mixed-pinned"),
            ("One map of both sizes", "mixed-sizes"),
        ],
        "rows": ["10 accounts", "25 accounts"],
    },
    {
        "title": "Library: rebalancing by number of packed entries (one-slot entries)",
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
            "Move one entry",
            "Swap two entries",
            "Evict one entry",
            "Replace one entry with another",
            "Pack every entry",
        ],
    },
    {
        "title": "Library: packing entries from home, per entry (16 per call)",
        "label": "Entry shape",
        "columns": [("pagepack", "pagepack-packing")],
        "percentages": False,
        "divide_by": 16,
        "rows": [
            "1-slot entries",
            "3-slot entries",
            "8-slot entries",
            "8-slot entries, 1 slot set",
            "1-slot entries, never written",
            "1-slot entries, home-hint map",
            "1-slot entries, never written, home-hint map",
        ],
    },
    {
        "title": "Library: storage left by 512 nonzero one-slot entries",
        "label": "Layout",
        "columns": [
            ("Live storage slots", "footprint-slots"),
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
        "title": "Exchange example: taker vs 14 makers without hints, by map name",
        "label": "Map name",
        "columns": [("pagepack", "exchange-map-names")],
        "percentages": False,
        "rows": [
            "pagepack.exchange",
            "pagepack.exchange.1",
            "pagepack.exchange.2",
            "pagepack.exchange.3",
            "pagepack.exchange.4",
            "pagepack.exchange.5",
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
