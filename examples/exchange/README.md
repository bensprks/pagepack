# Order-book exchange

The account side of a perpetuals exchange, built on pagepack: collateral, positions, resting
orders and cross-margin checks. It models the storage that order-book exchanges on Monad touch
on every transaction, whether matching runs onchain against a resting book (like
[Perpl](MAINNET.md)) or offchain in an operator's engine that settles fills in batches.

| File | What it does |
| --- | --- |
| [`Exchange.sol`](Exchange.sol) | Deposits, quoting with margin checks, settlement of a taker against makers. Storage-agnostic. |
| [`ExchangeMap.sol`](ExchangeMap.sol) | The four entry structs and a typed pagepack map holding them, with their keys. |
| [`PackedExchange.sol`](PackedExchange.sol) | Stores entries in the typed map and lets an admin rebalance. About 80 lines. |
| [`MAINNET.md`](MAINNET.md) | What Perpl's mainnet traffic and storage look like, from a five-minute sample. |

## Why exchanges

On a busy exchange, a few market makers account for most transactions, and each of their
transactions reads and writes several small entries: the account, an order or three, and a
position in every market the account trades, because margin is checked across all of them. In a
typical layout each of those entries is a mapping entry on its own page. On Monad that costs
8,100 gas per entry before any work is done.

Those entries are used together all the time, and which accounts are hot changes over time.
That is the case pagepack is built for: put each active market maker's entries on one page, put
every market's entry on one shared page, and repack when activity shifts.

## Design

**Entries.** Accounts, positions, order slots and markets are all one-slot structs. `Exchange`
asks a storage hook for each entry (`_account(trader)`, `_position(trader, market)`,
`_order(trader, index)`, `_market(market)`), works on the struct in place and does everything
else itself. `PackedExchange` answers from `ExchangeMap`, a typed map holding all four kinds;
the benchmark baseline answers from Solidity mappings. Both share every line of logic.

`ExchangeMap` bit-packs each entry's natural key into a `bytes32` with its kind in the top
byte (`accountKey`, `positionKey`, `orderKey`, `marketKey`), for hints and layouts. Its width is
pinned at one slot, and creating it checks that every struct fits.

**One lookup per entry per call.** Without a hint, every pagepack lookup searches the map's
directory. A call keeps the entries of the market it is working in, so a settlement locates the
market and the taker's position once rather than on every fill, and a re-quote finds a market's
margin rate without locating it again for each order.

**Reusable order slots.** Each account has 16 order slots. Instead of a new storage entry per
order, a new order overwrites a slot, and cancelled or filled slots keep a nonzero word. Writing
over a nonzero word avoids MIP-8's 17,000 gas charge for growing state, so placing an order in a
reused slot costs 20% less, with or without pagepack.

**Hints.** Any call can carry `(key, hint)` pairs. The packed exchange hands them to pagepack's
`useHints`, which keeps them in transient storage for the transaction, so the caller can pass
them in any order and every lookup picks its hint up. A market maker or a settlement operator
knows the layout and can always pass them; anyone else passes none.

The exchange's map keeps home flags (`mapWithHomeHints`). Takers are long-tail accounts that
are never packed, and with a `HOME` hint for the taker a fully hinted settlement never loads the
directory. The flags cost one storage slot on the home page of each packed entry: a few hundred
slots for the active accounts.

## Trust assumptions

This is a storage benchmark, kept small on purpose. It enforces its own accounting (balances,
locked margin, the taker's margin), but trusts the operator that calls `settle` as the matching
and risk engine:

- **Authorization.** The operator names the taker. Nothing onchain checks that the taker agreed
  to the trade. A real exchange verifies a signed order or has the taker send the transaction.
- **Order identity.** A fill names a maker's order index and a size, not an expected price or
  order version. Slots are reused, so if the maker re-quotes between the match and settlement,
  the fill takes the new order.
- **Maker risk.** Only the taker's margin is checked after a fill. Filling a maker can leave it
  under-margined, e.g. an ask far below the mark price. A real exchange checks makers too, or
  liquidates them.
- **Prices and rates.** Mark prices are set by the admin as a stand-in for an oracle, and a
  market's margin rate is fixed when it is listed. There is no funding or liquidation.

Both backends omit these checks consistently. Adding them may change the storage access pattern
and measured savings.

## Results

From `make gas`. Each operation is a fresh transaction with cold storage. 8 markets and 16
makers. Maker 0 holds positions in 6 markets with 8 resting orders, like Perpl's busiest
account; the others quote one market. The taker is a long-tail account and is not packed.

| Operation | Mappings | pagepack | pagepack + hints |
| --- | ---: | ---: | ---: |
| Re-quote 1 order, maker in 6 markets | 158,495 | 84,113 (-47%) | 76,473 (-52%) |
| Re-quote 3 orders, one market | 106,006 | 76,954 (-27%) | 66,969 (-37%) |
| Taker vs 3 makers | 206,535 | 129,945 (-37%) | 117,327 (-43%) |
| Taker vs 14 makers | 706,264 | 342,197 (-52%) | 318,918 (-55%) |

| Operation | Mappings |
| --- | ---: |
| New order in a never-used slot | 86,442 |
| New order in a reused slot | 69,442 (-20%) |

- **Re-quotes** are most of the traffic on Perpl. A maker in several markets saves the most,
  because its margin check reads a position and a market entry for every one of them.
- **Settlement** saves on every maker and grows with the batch: each maker's account, order and
  position share a page with other makers'.
- **A better mapping layout would close part of the gap.** A mapping of per-trader structs keeps
  one trader's account, orders and positions on one page, so the multi-market re-quote would load
  that page plus one per market entry. A settlement would still load a page per maker. pagepack
  puts many makers' entries, and every market's, on a page or two.
- **Without hints, results depend a little on the entries' fingerprints.** A directory search
  takes one to a few probes depending on the fingerprint it looks for, and a map's name decides
  every fingerprint. The same 14-maker settlement without hints, under six map names:

  | Map name | pagepack |
  | --- | ---: |
  | pagepack.exchange | 342,197 |
  | pagepack.exchange.1 | 344,047 |
  | pagepack.exchange.2 | 351,758 |
  | pagepack.exchange.3 | 333,126 |
  | pagepack.exchange.4 | 344,433 |
  | pagepack.exchange.5 | 334,826 |

  Fully hinted calls never search the directory, so their cost doesn't vary.
- **The model is smaller than a real exchange.** It has no order-book index, order locks or
  funding entries. In the mainnet sample, Perpl's re-quotes touched 16 to 46 pages against this
  model's 4 to 14 (see [MAINNET.md](MAINNET.md)). Whether a real exchange saves more is a
  hypothesis: the extra pages hold state this model doesn't consolidate.

## Rebalancing

The admin applies layouts chosen offchain from recent activity, e.g. daily:

1. Rank accounts by how often they trade, and markets by how often they are read.
2. Place each hot account's account, order-slot and position entries together, and every market
   entry on one page. Entries with the same `index / entriesPerPage()` share a page (64 here).
3. Call `rebalance(placements)` with only the entries that change, placing evicted ones at
   `PagePack.HOME`. It applies as one step, so a layout can swap entries directly. Old hints
   keep working, without the saving, until callers refresh them with `hintOf`.
