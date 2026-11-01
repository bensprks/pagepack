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
| 1 record | 33,556 | 43,166 (+29%) | 34,813 (+4%) |
| 2 records | 45,321 | 46,010 (+2%) | 36,445 (-20%) |
| 10 records | 139,537 | 69,610 (-50%) | 49,609 (-64%) |
| 30 records | 375,029 | 140,156 (-63%) | 82,441 (-78%) |
| 30 records, 3 pages | 375,065 | 149,556 (-60%) | 104,437 (-72%) |
| 2 unpacked records | 45,333 | 57,940 (+28%) | 47,821 (+5%) |

The saving grows with batch size, which is the case pagepack is built for, e.g. a protocol that
settles 1 to 30 accounts every few hundred milliseconds. Without hints, single-record writes and
records that were never packed cost more than a mapping, because finding a record costs gas too.
With a hint, a record that was never packed costs within 5% of a mapping entry.

In the [order-book exchange example](examples/exchange), modelled on the transactions that
dominate Perpl on mainnet, a market maker's re-quote costs 51% less and a taker filling against
14 makers 48% less than the same exchange on mappings.

## How it works

```
  directory: one page per space
  ┌───────┬─────────┬─────────┬─────┬─────────┐
  │ count │ entry 0 │ entry 1 │ ... │ entry n │   entry = fingerprint → packed index,
  └───────┴─────────┴─────────┴─────┴─────────┘   sorted by fingerprint, 8 per slot

  packed pages: records used together, side by side
  ┌────┬──────┬────┬──────┬─────┬────┬──────┬────────┐
  │ id │ data │ id │ data │ ... │ id │ data │ unused │   floor(128 / (width + 1)) records
  └────┴──────┴────┴──────┴─────┴────┴──────┴────────┘   per page: 42 for two-word records
   index 0     index 1           index 41

  home pages: one per record at keccak256(space, key), like a mapping entry
  ┌──────┬──────────────────────────────────────┬──────┐
  │ data │ unused                               │ flag │   the record's data until it is
  └──────┴──────────────────────────────────────┴──────┘   packed; the flag is set while packed
```

- **Spaces.** A space is a family of fixed-width records (say, one-word balances). Records only
  share pages with records in the same space, so put entities used together in one space.
- **Home and packed locations.** Every record starts on its home page, derived from its key. An
  admin calls `rebalance` to move hot records into numbered slots on packed pages. A record is
  never split across pages, and while it is packed, a flag on its home page says so.
- **Identity words.** Each packed record is stored with its identity, `keccak256(space, key)`,
  so any lookup can confirm it found the right record. Stale data can't be returned.
- **Directory.** One page per space lists a 22-bit fingerprint and packed index for up to 1,016
  records. The fingerprints are evenly spread hash bits, so interpolation search finds most
  entries in about three probes.

### Finding a record

```
                                  find(key)
                                      │
          ┌───────────────────────────┼────────────────────────────┐
          │ hint = index + 1          │ hint = HOME                │ no hint
          v                           v                            │
  identity word at index        packed flag on home                │
  belongs to this key?          page is clear?                     │
          │                           │                            │
     ┌────┴────┐                 ┌────┴────┐                       │
     │ yes     │ no              │ yes     │ no                    │
     v         │                 v         │                       │
  packed       │               home        │                       │
               └───────────────────────────┴───────────┬───────────┘
                                                       v
                                 search the directory for the key's fingerprint
                                                       │
                                             ┌─────────┴─────────┐
                                             │ found             │ not found
                                             v                   v
                                  identity word matches?        home
                                             │
                                        ┌────┴────┐
                                        │ yes     │ no
                                        v         v
                                     packed      home
```

`find(key)` checks a hint first if there is one. A packed record's hint is its index plus one,
checked against the identity word. A record that isn't packed has the hint `HOME`, checked
against its packed flag, so it costs what a mapping entry does. Without a hint, or with a wrong
one, the lookup searches the directory, loading that page once per transaction. Every path ends
at an identity word or the flag, so a wrong or stale hint can cost gas but never returns the
wrong record. Load a batch's hints once with `useHints` and every `find` in the transaction uses
them.

### Rebalancing

```
  rebalance(evictions: [a], placements: [b at index 0, c at index 1])

  before                                  after
  ┌──────────┬──────────┐                 ┌──────────┬──────────┐
  │ index 0  │ index 1  │   home          │ index 0  │ index 1  │   home
  │ a        │ b        │   c             │ b        │ c        │   a
  └──────────┴──────────┘                 └──────────┴──────────┘

  1. plan    find each named record and check the final layout is valid
  2. clear   read every moving record into memory and clear its old slots
  3. write   write each record to its new slots, so b can take a's index while a leaves
  4. index   packed-to-packed moves rewrite their directory entry in place;
             packing or evicting rebuilds the directory once
```

The layout is chosen off-chain from observed activity (see `analysis/`) and applied with
`rebalance(evictions, placements)`. A call names only the records that change and where each
ends up, and it applies as one step, so order doesn't matter and swaps and cycles work. Because
every old slot is cleared before any new one is written, moves within a page also avoid MIP-8's
state-growth charge. The library has no access control; the contract using it decides who can
call it. [Planning layouts](#planning-layouts) covers capacity, collisions and cost.

## Usage

```bash
forge install bensprks/pagepack
```

Then add this line to your project's `remappings.txt`. Without it, Foundry's automatic
remapping points `pagepack/` at the repository root rather than `src/`, and the import fails.

```text
pagepack/=lib/pagepack/src/
```

```solidity
import {PagePack, Record, Space} from "pagepack/PagePack.sol";

contract Vault {
    Space internal immutable BALANCES = PagePack.space("vault.balances", 1);

    function balanceOf(address owner, uint256 id) external view returns (uint256) {
        return BALANCES.find(_key(owner, id)).read(0);
    }

    /// Hints are optional. Loaded once, they serve every lookup in the transaction.
    function settle(Debit[] calldata debits, PagePack.Hint[] calldata hints) external {
        BALANCES.useHints(hints);

        for (uint256 i; i < debits.length; ++i) {
            Record r = BALANCES.find(_key(debits[i].owner, debits[i].id));
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
batch with one `eth_call`. `find(key, hint)` takes one hint directly instead.

### Using records safely

A `Record` is a raw storage pointer, so a few rules keep it safe:

- **Keep offsets below the space's width.** `read` and `write` don't check them, and offset
  `width` is already the next record's identity word.
- **Don't hold a `Record` across a rebalance.** It points wherever the record was when you looked
  it up. Look it up again after anything in the same transaction that could rebalance, including
  an external call that might re-enter.
- **Store fixed-size values only.** Mappings, dynamic arrays and long strings or bytes keep their
  contents at slots derived from the record's location, so a move would leave them behind. Keep
  them in their own storage, keyed by the record's key.

## Planning layouts

pagepack applies layouts; choosing them happens off-chain. What a planner needs to know:

- **Capacity.** A space packs up to 1,016 records, at indices below 1,024. The rest stay at home
  and cost what a mapping entry does.
- **Fingerprint collisions.** The directory knows records by a 22-bit fingerprint, so two records
  with the same one can't both be packed. Among 1,016 random keys there's an 11.6% chance some
  pair collides (3.1% at 512, 0.1% at 100). Check new placements with `fingerprintOf` and leave
  one of each pair at home; otherwise `rebalance` reverts with `FingerprintCollision(key)`.
- **Record width.** All records in a space have the same width, plus one identity word each when
  packed, so a page holds `floor(128 / (width + 1))` of them: 64 one-word records, 42 two-word or
  32 three-word. Put fields that are used together in one record, and rarely used fields in a
  space of their own.
- **Schema changes.** A space's location comes from its name and width, so widening a record
  makes a new space rather than appending to the old one. Moving to it means copying records.
- **Gas.** Packing a record from home costs about 54,000 gas, most of it MIP-8's charge for two
  new storage slots (identity and data). Filling a space takes about 55M gas, so split large
  migrations into transactions of a few hundred records; listing new records in fingerprint
  order also skips a sort. After that, a rebalance costs what it changes. Swapping two records
  costs about 60,000 gas at any size. Packing or evicting rebuilds the directory once per call,
  which grows with the number of packed records:

  | Operation (one-word records, incl. 21,000 tx base) | 64 packed | 512 packed | 1,016 packed |
  | --- | ---: | ---: | ---: |
  | Empty rebalance | 22,861 | 22,861 | 22,861 |
  | Swap two records | 59,670 | 63,046 | 61,592 |
  | Move one record | 97,369 | 101,135 | 98,545 |
  | Evict one record | 77,058 | 144,894 | 214,067 |
  | Replace one record with another | 98,140 | 162,116 | 234,676 |
  | Resubmit the whole layout | 146,834 | 1,008,154 | 1,980,926 |

- **Payback.** A rebalance pays off when the page loads it saves before the next one exceed its
  cost. Measure that against the current layout, not against mappings: moving a record that
  already shares a page with the records it is used with saves nothing.

## Repository

| Path | What's there |
| --- | --- |
| `src/` | The library: `PagePack.sol`, with the directory's bit-level format in `LibDirectory.sol` and a sort copied from Solady in `utils/`. No dependencies. |
| `test/` | Unit, fuzz and invariant tests, example tests, and `test/gas/` benchmarks. |
| `examples/exchange/` | The account side of an order-book exchange: quoting, settlement and cross-margin, built on pagepack. |
| `analysis/` | Off-chain tooling that chooses layouts from mainnet activity *(planned)*. |

## Development

Requires [Foundry](https://getfoundry.sh). All execution uses Monad's gas schedule
(`network = "monad"` in `foundry.toml`).

```bash
make test   # unit, fuzz and invariant tests
make gas    # benchmarks and the comparison tables above
make fmt
```

CI checks gas snapshots. If a change moves any benchmark, run `make gas` and commit the updated
`snapshots/` along with the change.

## License

MIT
