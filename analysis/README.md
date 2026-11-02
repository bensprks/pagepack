# analysis

Off-chain tooling that decides which entries to pack together. It is separate from the Solidity
library: contracts only ever see its output, a list of placements passed to `rebalance`.

> Not built yet. This describes the planned pipeline.

## Pipeline

1. **Collect.** Read blocks from a Monad RPC: token `Transfer`/`Approval` logs to find the most
   active tokens and holders, and `prestateTracer` traces on sampled blocks to see which storage
   slots each transaction touches.
2. **Map.** Turn raw slots back into logical entries, e.g. `(holder, token)` balances and
   `(owner, spender, token)` allowances.
3. **Pack.** Group entries into pages to minimise pages touched per transaction. Frequency
   packing is the baseline; co-access clustering is the experiment. Earlier mainnet data showed
   frequency packing is hard to beat, so both are reported against held-out transactions.
4. **Emit.** Write a layout file per map:

```json
{
  "map": "example.balances",
  "entriesPerPage": 64,
  "placements": [{ "key": "0x…", "index": 0 }]
}
```

This will run through `make layout`. RPC endpoints go in `.env`, which git ignores.
