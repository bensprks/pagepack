# Order-book exchange

The account side of a perpetuals exchange, built on pagepack: collateral, positions, resting
orders and cross-margin checks. It models the storage that order-book exchanges on Monad touch
on every transaction, whether matching runs on-chain against a resting book (like
[Perpl](MAINNET.md)) or off-chain in an operator's engine that settles fills in batches.

| File | What it does |
| --- | --- |
| [`Exchange.sol`](Exchange.sol) | Deposits, quoting with margin checks, settlement of a taker against makers. Storage-agnostic. |
| [`PackedExchange.sol`](PackedExchange.sol) | Stores records with pagepack and lets an admin rebalance. About 50 lines. |
| [`MAINNET.md`](MAINNET.md) | What Perpl's mainnet traffic and storage look like, and what the gaps mean for its layout. |

## Why exchanges

On a busy exchange, a few market makers account for most transactions, and each of their
transactions reads and writes several small records: the account, an order or three, and a
position in every market the account trades, because margin is checked across all of them. In a
typical layout each of those records is a mapping entry on its own page. On Monad that costs
8,100 gas per record before any work is done.

Those records are used together all the time, and which accounts are hot changes over time.
That is the case pagepack is built for: put each active market maker's records on one page, put
every market's record on one shared page, and repack when activity shifts.

## Design

**Records.** Accounts, positions, order slots and markets are all one-word records with a
`bytes32` key (`accountKey`, `positionKey`, `orderKey`, `marketKey`). `Exchange` asks
`_locate(key)` where a record lives, lays the record's struct over that slot and does everything
else itself. `PackedExchange` answers with pagepack; the benchmark baseline answers with a
mapping. Both share every line of logic.

**One lookup per record per call.** Without a hint, every pagepack lookup searches the space's
directory. A call keeps the records of the market it is working in, so a settlement locates the
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

The exchange's space keeps home flags (`spaceWithHomeHints`). Takers are long-tail accounts that
are never packed, and with a `HOME` hint for the taker a fully hinted settlement never loads the
directory. The flags cost one storage word on the home page of each packed record: a few hundred
words for the active accounts.

## Trust assumptions

This is a storage benchmark, kept small on purpose. It enforces its own accounting (balances,
locked margin, the taker's margin), but trusts the operator that calls `settle` as the matching
and risk engine:

- **Authorization.** The operator names the taker. Nothing on-chain checks that the taker agreed
  to the trade. A real exchange verifies a signed order or has the taker send the transaction.
- **Order identity.** A fill names a maker's slot and a size, not an expected price or order
  version. Slots are reused, so if the maker re-quotes between the match and settlement, the
  fill takes the new order.
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
| Re-quote 1 order, maker in 6 markets | 158,865 | 79,196 (-50%) | 76,647 (-52%) |
| Re-quote 3 orders, one market | 106,141 | 74,033 (-30%) | 66,855 (-37%) |
| Taker vs 3 makers | 207,067 | 126,535 (-39%) | 118,072 (-43%) |
| Taker vs 14 makers | 708,083 | 330,183 (-53%) | 319,850 (-55%) |

| Operation | Mappings |
| --- | ---: |
| New order in a never-used slot | 86,572 |
| New order in a reused slot | 69,572 (-20%) |

- **Re-quotes** are most of the traffic on Perpl. A maker in several markets saves the most,
  because its margin check reads a position and a market record for every one of them.
- **Settlement** saves on every maker and grows with the batch: each maker's account, order and
  position share a page with other makers'.
- **Without hints, results depend a little on the records' fingerprints.** A directory search
  takes one to a few probes depending on the fingerprint it looks for, and a space's name decides
  every fingerprint. The same 14-maker settlement without hints, under six space names:

  | Space name | pagepack |
  | --- | ---: |
  | pagepack.exchange | 330,183 |
  | pagepack.exchange.1 | 330,839 |
  | pagepack.exchange.2 | 333,851 |
  | pagepack.exchange.3 | 329,538 |
  | pagepack.exchange.4 | 335,612 |
  | pagepack.exchange.5 | 329,421 |

  Fully hinted calls never search the directory, so their cost doesn't vary.
- **The model is smaller than a real exchange.** It has no order-book index, order locks or
  funding records. In the mainnet sample, Perpl's re-quotes touched 16 to 46 pages against this
  model's 4 to 14 (see [MAINNET.md](MAINNET.md)). Whether a real exchange saves more is a
  hypothesis: the extra pages hold state this model doesn't consolidate.

## Rebalancing

The admin applies layouts chosen off-chain from recent activity, e.g. daily:

1. Rank accounts by how often they trade, and markets by how often they are read.
2. Place each hot account's account, order-slot and position records together, and every market
   record on one page. Records with the same `index / recordsPerPage()` share a page (64 here).
3. Call `rebalance(evictions, placements)` with only the records that change. It applies as one
   step, so a layout can swap records directly. Old hints keep working, without the saving,
   until callers refresh them with `hintOf`.
