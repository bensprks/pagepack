# Perpl on Monad mainnet

What Perpl's exchange actually does on mainnet, which storage it touches, and what that means
for its layout under MIP-8. Everything here comes from public sources: Perpl's documentation and
explainers, its published ABI, and read-only RPC queries (logs and `prestateTracer` traces).
Sampled on 31 October 2026.

## Traffic is quote management

In 1,000 blocks (about five minutes), the exchange
(`0x34B6552d57a35a1D042CcAe1951BD1C370112a6F`) had **5,102 transactions** and 32,674 events:

| Event | Count |
| --- | ---: |
| Order requests | 13,565 |
| Orders changed | 7,243 |
| Orders placed | 1,376 |
| Orders cancelled | 1,262 |
| Maker fills | 190 |
| Taker fills | 116 |

**98% of transactions fill nothing.** They are market makers moving quotes, one to four orders
at a time. Order flow is concentrated: 52 accounts submitted orders, and the top three sent
74% of them (34%, 25% and 15%). The busiest account re-quotes the same 10 order ids over and
over.

Fills are rarer but wider: the largest taker order in the sample filled against 14 makers.

## Storage touched per transaction

Pages of exchange storage touched by representative transactions, from `prestateTracer`:

| Transaction | Slots | Pages |
| --- | ---: | ---: |
| Re-quote 1 order, maker with positions in 6 markets | 65 | 46 |
| Re-quote 3 orders, one market | 29 | 24 |
| Place 1 order | 23 | 16 |
| Taker vs 14 makers | 121 read, 77 written | 94 read, 66 written |

Almost every slot is on its own page. A page costs 8,100 gas the first time it is read in a
transaction, so the 46-page re-quote pays about 370,000 gas in page loads before doing any work.

## Where those slots are

Matching each slot against the Solidity mapping derivations of the account, market, order and
price values in the transaction's events recovers the layout. It agrees with the struct layouts
in Perpl's own [page-storage explainer](https://github.com/PerplFoundation/explainers):

| Storage | Keyed by | Size |
| --- | --- | --- |
| Account struct (base slot 213) | account id | 9 slots, one page |
| Perpetual struct (base slot 217) | perp id | 20 slots, one page |
| Positions, inside the perpetual (field 18) | account id | 1 slot each, own page |
| Orders, inside the perpetual (field 16) | order id | 1 slot each, own page |
| Price-level pointers (field 15) and price index (fields 13, 14) | price tick | 1 slot each, own page |
| Order-id index leaves (field 11) | order id / 256 | own page |
| Per-account, per-perp records (account field 3) | perp id | own page |

The multi-market re-quote reads the perpetual struct and the position for **all six markets**
the account trades, because margin is checked across them. That is 12 pages before the order
itself is touched.

## What this means

Perpl's explainer concludes that MIP-8 is a marginal win, about 4% across its own gas suite,
because single-slot positions, orders and order locks "each hash to their own scattered page",
which it calls a floor that page-ification cannot lower. That floor is a consequence of keying
every record by hash. It is not a property of the data:

- **The same accounts touch the same records all the time.** Three accounts send three quarters
  of the orders. Their accounts, positions, order records and locks could share a page or two
  each, instead of one page per record.
- **Margin checks read every market an account holds.** Putting each market's hot header slots
  on one shared page turns six page loads into one.
- **Order ids are already reused.** Allocating each account's orders within a block of ids, or
  per-account slots as in this example, keeps a maker's orders on its own page.
- **Neighbouring price levels are read together.** Storing price pointers and index words by
  tick in contiguous storage, rather than by hash, puts adjacent levels on the same page.

The explainer also names batched, multi-account forwarder flow as the regime its suite did not
measure. That is most of mainnet. The [example](README.md) models the account side of it: on the
same transaction shapes, packing cuts the multi-market re-quote by 45% (52% with hints) and the
14-maker fill by 41% (48% with hints). Perpl's real transactions touch several times more pages
than the model, so the absolute saving would be larger.

## Method

1. `eth_getLogs` on the exchange over the 1,000 most recent blocks, in 200-block requests,
   decoded with the ABI from Perpl's [SDK](https://github.com/PerplFoundation/dex-sdk).
2. `debug_traceTransaction` with `prestateTracer` (plain and `diffMode`) on one transaction of
   each common shape, counting exchange storage slots and their pages (`slot >> 7`).
3. For every slot, test `keccak256(key . base) + offset` for mapping bases 0-1,023 and keys from
   the transaction's events, then the same nested one level inside the matched structs.
