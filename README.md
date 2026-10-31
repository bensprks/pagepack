# pagepack

Storage records that are used together, packed onto the same [MIP-8](https://github.com/monad-crypto/MIPs/blob/main/MIPs/MIP-8.md) page.

On Monad, storage is priced per 128-slot page: the first slot you touch on a page costs 8,100 gas
and every other slot on it costs 100. A Solidity mapping puts each entry on its own page, so a
transaction that updates 30 balances pays for 30 page loads. pagepack lets you move the records
that are used together onto shared pages, so the same transaction pays for one or two.

> Work in progress. Not audited.

## Results

Updating existing one-word balances in one transaction, Monad gas schedule, from `make gas`:

| Records updated in one tx | Mapping | pagepack, no hint | pagepack, hinted |
| --- | ---: | ---: | ---: |
| 1 record | 33,556 | 42,996 (+28%) | 34,801 (+4%) |
| 2 records | 45,321 | 45,670 (+1%) | 36,421 (-20%) |
| 10 records | 139,537 | 67,910 (-51%) | 49,489 (-65%) |
| 30 records | 375,029 | 135,056 (-64%) | 82,081 (-78%) |
| 30 records, 3 pages | 375,065 | 144,456 (-61%) | 104,077 (-72%) |
| 2 unpacked records | 45,333 | 57,600 (+27%) | – |

The saving grows with batch size, which is the case pagepack is built for, e.g. a protocol that
settles 1 to 30 accounts every few hundred milliseconds. Single-record writes and records that
were never packed cost more than a mapping, because finding a record costs gas too.

In the [order-book exchange example](examples/exchange), modelled on the transactions that
dominate Perpl on mainnet, a market maker's re-quote costs 52% less and a taker filling against
14 makers 49% less than the same exchange on mappings.

## How it works

```
          one per space                       packed pages
   ┌──────────────────────────┐   ┌──────────────┬──────────────┬─────
   │ count │ fingerprint→index │   │ id │ data    │ id │ data    │ ...
   └──────────────────────────┘   └──────────────┴──────────────┴─────
             directory                 page 0          page 1

   unpacked record → its own page at keccak256(space, key), like a mapping entry
```

- **Spaces.** A space is a family of fixed-width records (say, one-word balances). Records only
  share pages with records in the same space, so put entities used together in one space.
- **Home and packed locations.** Every record starts at a home location derived from its key.
  An admin calls `rebalance` to move hot records into numbered slots on packed pages. A record is
  never split across pages.
- **Identity words.** Each packed record is stored with its identity, `keccak256(space, key)`,
  so any lookup can confirm it found the right record. Stale data can't be returned.
- **Directory.** One page per space lists a 22-bit fingerprint and packed index for up to 1,016
  records. A lookup without a hint loads that page (once per transaction) and searches it. The
  fingerprints are evenly spread hash bits, so interpolation search finds most entries in about
  three probes.
- **Hints.** A caller that knows the layout passes a record's packed index. It is checked
  against the identity word, so the directory is skipped entirely. Wrong or stale hints fall back
  to the directory: they can cost gas but never return the wrong record.
- **Rebalancing.** The layout is chosen off-chain from observed activity (see `analysis/`) and
  applied with `rebalance`, which moves records and rewrites the directory in one transaction.
  The library has no access control; the contract using it decides who can call it.

## Usage

```bash
forge install bensprks/pagepack
```

```solidity
import {PagePack, Record, Space} from "pagepack/PagePack.sol";

contract Ledger {
    Space internal immutable BALANCES = PagePack.space("ledger.balances", 1);

    function balanceOf(address owner, uint256 id) external view returns (uint256) {
        return BALANCES.find(_key(owner, id)).read(0);
    }

    function settle(Debit[] calldata debits, uint256[] calldata hints) external {
        for (uint256 i; i < debits.length; ++i) {
            Record r = BALANCES.find(_key(debits[i].owner, debits[i].id), hints[i]);
            r.write(0, r.read(0) - debits[i].amount);
        }
    }

    function rebalance(bytes32[] calldata evictions, PagePack.Placement[] calldata placements)
        external
        onlyAdmin
    {
        BALANCES.rebalance(evictions, placements);
    }
}
```

`BALANCES.hintOf(key)` returns a record's hint, so an off-chain caller can build hints for a
batch with one `eth_call`.

## Repository

| Path | What's there |
| --- | --- |
| `src/` | The library. A single file, `PagePack.sol`, with no dependencies. |
| `test/` | Unit and fuzz tests, example tests, and `test/gas/` benchmarks. |
| `examples/exchange/` | The account side of an order-book exchange: quoting, settlement and cross-margin, built on pagepack. |
| `analysis/` | Off-chain tooling that chooses layouts from mainnet activity *(planned)*. |

## Development

Requires [Foundry](https://getfoundry.sh). All execution uses Monad's gas schedule
(`network = "monad"` in `foundry.toml`).

```bash
make test   # unit and fuzz tests
make gas    # benchmarks and the comparison tables above
make fmt
```

## License

MIT
