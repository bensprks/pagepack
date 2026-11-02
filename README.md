# pagepack

Storage records that are used together, packed onto the same [MIP-8](https://github.com/monad-crypto/MIPs/blob/main/MIPs/MIP-8.md) page.

On Monad, storage is priced per 128-slot page: the first slot you touch on a page costs 8,100 gas
and every other slot on it costs 100. A Solidity mapping puts each entry on its own page, so a
transaction that updates 30 balances pays for 30 page loads. pagepack lets you move the records
that are used together onto shared pages, so the same transaction pays for one or two.

> Work in progress. Not audited.

## Results

Updating existing one-slot balances in one transaction, Monad gas schedule, from `make gas`:

| Records updated in one tx | Mapping | pagepack, no hint | pagepack, hinted |
| --- | ---: | ---: | ---: |
| 1 record | 33,556 | 43,572 (+30%) | 34,813 (+4%) |
| 2 records | 45,321 | 46,439 (+2%) | 36,445 (-20%) |
| 10 records | 139,537 | 66,462 (-52%) | 49,609 (-64%) |
| 30 records | 375,029 | 124,818 (-67%) | 82,441 (-78%) |
| 30 records, 3 pages | 375,065 | 144,189 (-62%) | 104,437 (-72%) |
| 2 unpacked records | 45,333 | 55,828 (+23%) | – |
| 2 unpacked records, home-hint map | 45,333 | 56,417 (+24%) | 47,895 (+6%) |

The saving grows with batch size, which is the case pagepack is built for, e.g. a protocol that
settles 1 to 30 accounts every few hundred milliseconds. Without hints, single-record writes and
records that were never packed cost more than a mapping, because finding a record costs gas too.
In a map that keeps home flags, a hint brings a record that was never packed within 6% of a
mapping entry, at a storage cost described under [Planning layouts](#planning-layouts).

In the [order-book exchange example](examples/exchange), modelled on the transactions that
dominate Perpl on mainnet, a market maker's re-quote costs 51% less and a taker filling against
14 makers 55% less than the same exchange on mappings.

## How it works

```
  directory: one page per map
  ┌───────┬─────────┬─────────┬─────┬─────────┐
  │ count │ entry 0 │ entry 1 │ ... │ entry n │   entry = fingerprint → packed index,
  └───────┴─────────┴─────────┴─────┴─────────┘   sorted by fingerprint, 8 per slot

  packed pages: records used together, side by side
  ┌────┬──────┬────┬──────┬─────┬────┬──────┬────────┐
  │ id │ data │ id │ data │ ... │ id │ data │ unused │   floor(128 / (width + 1)) records
  └────┴──────┴────┴──────┴─────┴────┴──────┴────────┘   per page: 42 for two-slot records
   index 0     index 1           index 41

  home pages: one per record at keccak256(map, key), like a mapping entry
  ┌──────┬──────────────────────────────────────┬──────┐
  │ data │ unused                               │ flag │   data until the record is packed;
  └──────┴──────────────────────────────────────┴──────┘   flag while packed (home-hint maps)
```

- **Maps.** A map holds fixed-width records by key (say, one-slot balances). Records only
  share pages with records in the same map, so put entities used together in one map.
- **Home and packed locations.** Every record starts on its home page, derived from its key. An
  admin calls `rebalance` to move hot records into numbered slots on packed pages. A record is
  never split across pages. In a home-hint map, a flag on the home page marks it as packed.
- **Identity words.** Each packed record is stored with its identity, `keccak256(map, key)`,
  so any lookup can confirm it found the right record. Stale data can't be returned.
- **Directory.** One page per map lists a 22-bit fingerprint and packed index for up to 1,016
  records, 8 to a storage word. The fingerprints are evenly spread hash bits, so a search can
  guess which word to read and usually settles in one or two reads.

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
checked against the identity word. In a home-hint map, a record that isn't packed has the hint
`HOME`, checked against its packed flag, so it costs what a mapping entry does; other maps
ignore `HOME`. Without a hint, or with a wrong one, the lookup searches the directory, loading
that page once per transaction. Every path ends at an identity word or the flag, so a wrong or
stale hint can cost gas but never returns the wrong record. Load a batch's hints once with
`useHints` and every `find` in the transaction uses them.

A search interpolates which directory word should hold the key's fingerprint, reads it and
compares all 8 entries at once. A miss rules out everything on one side of that word, so the
next guess is close. Records at home cost the same to search for as packed ones. Over random
directories, with the page already loaded, from `make gas`:

| Directory and record | Probes, mean | Probes, max | Gas, mean | Gas, max |
| --- | ---: | ---: | ---: | ---: |
| 64 packed, packed record | 1.25 | 3 | 968 | 1,998 |
| 64 packed, record at home | 1.33 | 3 | 1,006 | 2,012 |
| 512 packed, packed record | 1.81 | 4 | 1,294 | 2,592 |
| 512 packed, record at home | 1.92 | 4 | 1,348 | 2,601 |
| 1016 packed, packed record | 1.94 | 4 | 1,362 | 2,592 |
| 1016 packed, record at home | 1.96 | 4 | 1,368 | 2,606 |

Probes are the directory words read after the count. Fingerprints chosen to defeat the guess, as
keys ground to be packed could be, make the search fall back to bisection after five probes,
which caps it at 12.

Each lookup without a hint searches again, even for a record found earlier in the call. Look a
record up once per call and pass its struct or `Record` along, as long as nothing in between
could rebalance (see [Using records safely](#using-records-safely)).

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

Give each kind of record a typed map: copy
[`examples/loans/LoanMap.sol`](examples/loans/LoanMap.sol) and rename its struct, key and
functions. Contracts then use records as structs:

```solidity
import {PagePack} from "pagepack/PagePack.sol";
import {LoanMap, loanMap} from "./LoanMap.sol";

contract Lender {
    LoanMap internal immutable LOANS = loanMap("app.loans");

    function accrue(uint256 loanId, uint128 amount) external {
        LOANS.find(loanId).interest += amount;
    }

    /// Hints are optional. Loaded once, they serve every lookup in the transaction.
    function accrueAll(uint256[] calldata ids, uint128 amount, PagePack.Hint[] calldata hints)
        external
    {
        LOANS.map().useHints(hints);

        for (uint256 i; i < ids.length; ++i) {
            LOANS.find(ids[i]).interest += amount;
        }
    }

    function rebalance(bytes32[] calldata evictions, PagePack.Placement[] calldata placements)
        external
        onlyAdmin
    {
        LOANS.map().rebalance(evictions, placements);
    }
}
```

The module holds the `Loan` struct and a `LoanMap` type wrapping a `PagedMap`. `loanMap(name)`
takes the map's width from the struct itself: in a `Loan[2] storage` array, the slot of the
second element is the struct's size. `find(loanId)` returns `Loan storage` wherever the record
lives, and Solidity handles the field offsets and packing. `loanKey(loanId)` gives the `bytes32`
key that hints, layouts and off-chain tools use, and `map()` the underlying `PagedMap`.

`LOANS.map().hintOf(loanKey(id))` returns a record's hint, so an off-chain caller can build hints
for a batch with one `eth_call`. To give records that aren't packed a hint too, have the module
create its map with `PagePack.mapWithHomeHints`; [Planning layouts](#planning-layouts) covers what
that costs.

Solidity reads and writes each field separately. To load the slot only once, read the fields you
need in one statement and write the changed ones together, after any checks. Each extra field
written still costs about 100 gas, where a hand-packed word is written once.

### Several kinds in one map

Records only share pages with records in the same map, so entities used together, such as an
account and its positions, belong in one map. Write one module for the map, with a getter and a
key function per kind. Its width is set by hand, and the constructor function checks every struct
against it with `requireFits`, so a struct that outgrows it stops the deploy:

```solidity
function exchangeMap(string memory name) view returns (ExchangeMap) {
    PagedMap records = PagePack.mapWithHomeHints(name, 1);

    records.requireFits(_accountSlots());
    records.requireFits(_positionSlots());
    records.requireFits(_orderSlots());
    records.requireFits(_marketSlots());

    return ExchangeMap.wrap(PagedMap.unwrap(records));
}
```

The exchange example's [`ExchangeMap.sol`](examples/exchange/ExchangeMap.sol) works this way, with
`RECORDS.account(trader)`, `RECORDS.position(trader, market)`, `RECORDS.order(trader, index)` and
`RECORDS.market(market)`.

### Records underneath

A typed map is a thin layer over `PagedMap` and `Record`. `find(key)` on a `PagedMap` returns a
`Record`, the slot where the record's data starts, and `read` and `write` use it a slot at a time:

```solidity
import {PagePack, PagedMap, Record} from "pagepack/PagePack.sol";

PagedMap internal immutable BALANCES = PagePack.map("vault.balances", 1);

function credit(bytes32 key, uint256 amount) internal {
    Record r = BALANCES.find(key);
    r.write(0, r.read(0) + amount);
}
```

A typed getter lays its struct over the same slot. `find(key, hint)` takes one hint directly
instead of loading hints with `useHints`.

### Using records safely

A `Record` is a raw storage pointer, and so is a struct laid over one. A few rules keep them safe:

- **Fixed-size fields only.** Mappings, dynamic arrays, strings and bytes keep their contents at
  slots derived from the record's location, so a move would leave them behind. Keep them in their
  own storage, keyed by the record's key.
- **Fit the width.** Offset `width` is already the next record's identity word, so a struct may be
  narrower than its map but never wider, and `read` and `write` offsets must stay below the width.
  A map of one kind takes its width from the struct, so it always fits; a map of several kinds
  checks each struct at deploy. Both measure a struct by array stride, which counts arrays, nested
  structs and fields added later. The helper must be `view`, since the compiler treats indexing a
  storage array as a possible read (error 2527), but it reads nothing;
  [`test/TypedRecords.t.sol`](test/TypedRecords.t.sol) checks that and shows what a wider struct
  breaks.
- **Cast or bit-pack keys; hash only keys over 32 bytes.** pagepack hashes the map and key
  together, so a key only has to be unique within its map. Cast a single value
  (`bytes32(loanId)`), bit-pack a composite key that fits in 32 bytes, as the exchange's
  `positionKey` packs a trader and a market, and hash only longer ones, since hashing adds gas to
  every lookup. In a map of several kinds, tag each key with its kind so kinds never collide.
- **Look records up again after anything that could rebalance.** A `Record`, and a struct laid
  over one, points wherever the record was when you looked it up. Look it up again after anything
  in the same transaction that could rebalance, including an external call that might re-enter.

## Upgrades

Upgradeable proxies aren't supported yet. These decide where records live, so they are fixed
once records are written:

- the map's name, and whether it keeps home hints;
- its width, so a field that makes a typed map's struct wider moves the whole map;
- the key encoding;
- pagepack's own storage format, which isn't frozen before 1.0.

A pinned-width variant, checked with `requireFits` like a map of several kinds, may become the
upgrade path, leaving room to add fields. Contracts reach records through typed modules, so their
call sites won't change if it does.

## Planning layouts

pagepack applies layouts; choosing them happens off-chain. What a planner needs to know:

- **Capacity.** A map packs up to 1,016 records, at indices below 1,024. The rest stay at home
  and cost what a mapping entry does.
- **Fingerprint collisions.** The directory knows records by a 22-bit fingerprint, so two records
  with the same one can't both be packed. Among 1,016 random keys there's an 11.6% chance some
  pair collides (3.1% at 512, 0.1% at 100). Check new placements with `fingerprintOf` and leave
  one of each pair at home; otherwise `rebalance` reverts with `FingerprintCollision(key)`.
- **Record width.** All records in a map have the same width, plus one identity word each when
  packed, so a page holds `floor(128 / (width + 1))` of them: 64 one-slot records, 42 two-slot or
  32 three-slot. Put fields that are used together in one record, and rarely used fields in a
  map of their own.
- **Schema changes.** A map's location comes from its name, width and mode, so widening a
  record makes a new map rather than appending to the old one. Moving to it means copying
  records; see [Upgrades](#upgrades).
- **Home hints or compact storage.** A default map empties a record's home page when it packs
  it. A map made with `mapWithHomeHints` leaves a flag there instead, so a `HOME` hint can
  confirm a record isn't packed without loading the directory. Each flag is a live storage slot
  that keeps its home page occupied:

  | 512 nonzero one-slot records | Live storage slots | Occupied pages |
  | --- | ---: | ---: |
  | Mapping | 512 | 512 |
  | pagepack, all packed | 1,089 | 9 |
  | pagepack with home hints, all packed | 1,601 | 521 |

  These are logical counts of nonzero slots, not database bytes. Flags pay off when transactions
  often touch records that aren't packed and would load the directory only for them, like the
  long-tail takers in the exchange example. They also make evicting cheaper, since the home slot
  stays occupied. The choice is part of the map, like its width: the two kinds never share
  storage, so switching means migrating.
- **Gas.** Packing a record from home costs about 39,000 gas plus 18,000 to 20,000 for each
  nonzero slot it holds, mostly MIP-8's charge for new storage slots. Slots that are still zero
  cost nothing:

  | Packing from home, 16 records per call | Gas per record |
  | --- | ---: |
  | 1-slot records | 58,472 |
  | 3-slot records | 94,481 |
  | 8-slot records | 185,948 |
  | 8-slot records, 1 slot set | 62,636 |
  | 1-slot records, never written | 38,056 |
  | 1-slot records, never written, home-hint map | 58,396 |

  Filling a map of 1,016 one-slot records takes about 55M gas, so split large migrations into
  transactions sized from the table above; listing new records in fingerprint order also skips a
  sort. After that, a rebalance costs what it changes. Swapping two records costs about 60,000
  gas at any size. Packing or evicting rebuilds the directory once per call, which grows with the
  number of packed records. Evicting also pays 17,000 gas for the record's home slot in a default
  map:

  | Operation (one-slot records, incl. 21,000 tx base) | 64 packed | 512 packed | 1,016 packed |
  | --- | ---: | ---: | ---: |
  | Empty rebalance | 22,883 | 22,883 | 22,883 |
  | Swap two records | 59,458 | 60,047 | 61,206 |
  | Move one record | 97,680 | 98,269 | 98,286 |
  | Evict one record | 93,923 | 158,582 | 230,362 |
  | Replace one record with another | 114,331 | 175,331 | 250,472 |
  | Resubmit the whole layout | 146,888 | 1,008,208 | 1,980,980 |

- **Payback.** A rebalance pays off when the page loads it saves before the next one exceed its
  cost. Measure that against the current layout, not against mappings: moving a record that
  already shares a page with the records it is used with saves nothing.

## Repository

| Path | What's there |
| --- | --- |
| `src/` | The library: `PagePack.sol`, with the directory's bit-level format in `LibDirectory.sol` and a sort copied from Solady in `utils/`. No dependencies. |
| `test/` | Unit, fuzz and invariant tests, example tests, and `test/gas/` benchmarks. |
| `examples/loans/` | A typed map module to copy for each kind of record. |
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
