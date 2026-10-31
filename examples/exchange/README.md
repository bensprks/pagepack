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
`_locate(key)` where a record lives and does everything else itself. `PackedExchange` answers
with pagepack; the benchmark baseline answers with a mapping. Both share every line of logic.

**Reusable order slots.** Each account has 16 order slots. Instead of a new storage entry per
order, a new order overwrites a slot, and cancelled or filled slots keep a nonzero word. Writing
over a nonzero word avoids MIP-8's 17,000 gas charge for growing state, so placing an order in a
reused slot costs 19% less, with or without pagepack.

**Hints.** Any call can carry `(key, hint)` pairs. They are stored in transient storage, so the
caller can pass them in any order and each lookup costs one `TLOAD`. A market maker or a
settlement operator knows the layout and can always pass them; anyone else passes none.

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
| Re-quote 1 order, maker in 6 markets | 159,567 | 87,923 (-45%) | 77,483 (-51%) |
| Re-quote 3 orders, one market | 108,949 | 89,599 (-18%) | 72,837 (-33%) |
| Taker vs 3 makers | 205,749 | 143,501 (-30%) | 134,477 (-35%) |
| Taker vs 14 makers | 703,080 | 413,886 (-41%) | 367,000 (-48%) |

| Operation | Mappings |
| --- | ---: |
| New order in a never-used slot | 87,258 |
| New order in a reused slot | 70,258 (-19%) |

- **Re-quotes** are most of the traffic on Perpl. A maker in several markets saves the most,
  because its margin check reads a position and a market record for every one of them.
- **Settlement** saves on every maker and grows with the batch: each maker's account, order and
  position share a page with other makers'.
- **The model is smaller than a real exchange.** It has no order-book index, order locks or
  funding records. In the mainnet sample, Perpl's re-quotes touched 16 to 46 pages against this
  model's 4 to 14 (see [MAINNET.md](MAINNET.md)). Whether a real exchange saves more is a
  hypothesis: the extra pages hold state this model doesn't consolidate.

## Rebalancing

The admin applies layouts chosen off-chain from recent activity, e.g. daily:

1. Rank accounts by how often they trade, and markets by how often they are read.
2. Place each hot account's account, order-slot and position records together, and every market
   record on one page. Records with the same `index / recordsPerPage()` share a page (64 here).
3. Call `rebalance(evictions, placements)`. Old hints keep working, without the saving, until
   callers refresh them with `hintOf`.
