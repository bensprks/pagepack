# pagepack

A Solidity `PagedMap`: a mapping whose busiest records can be moved next to each other in
storage, so transactions on Monad load fewer storage pages.

[MIP-8](https://github.com/monad-crypto/MIPs/blob/main/MIPs/MIP-8.md) prices storage by 128-slot
page: the first slot a transaction touches on a page costs 8,100 gas, and every other slot on that
page costs 100. A Solidity mapping scatters its entries one to a page, so a transaction that
updates 30 balances loads 30 pages. A `PagedMap` starts out the same, but an admin can regroup
records that are used together onto shared pages, and the same transaction then loads one.

> Work in progress. Not audited.

## A record's life

A `PagedMap` behaves like a mapping until it is rebalanced. Take three traders who are often
settled in the same batch:

| Step | Mapping | `PagedMap` |
| --- | --- | --- |
| Each trader's first write | Lands on its own page, fixed by its key | Lands on its own *home* page, just like a mapping entry |
| A batch touching all three | 3 page loads | 3 page loads, plus the directory page |
| The admin calls `rebalance` | Nothing can move | The three are copied side by side onto one *packed* page |
| Every later batch | Still 3 page loads | 1 page load with hints, 2 without |
| Usage shifts | Nothing changes | The next rebalance follows it |
| A new trader signs up | Its own page | Its own home page, until a rebalance packs it |

Nothing moves on its own. An off-chain planner watches which records are used together, and the
admin applies its layout ([why](#why-records-dont-pack-themselves)).

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
mapping entry, at a [storage cost](docs/reference.md#home-hints-or-compact-storage).

What pagepack adds over a well-designed mapping is grouping *across* keys, and regrouping as
usage changes. A mapping of per-owner structs already keeps one owner's records on one page;
pagepack can also put many owners' records, or every market's, on one page.

In the [order-book exchange example](examples/exchange), modelled on the transactions that
dominate Perpl on mainnet, a market maker's re-quote costs 51% less and a taker filling against
14 makers 55% less than the same exchange on mappings.

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

A typed getter lays its struct over the same slot.

## How it works

### Where a record lives

Every record in a `PagedMap` is in exactly one of two places:

- **Home.** Its default address: `keccak256(map, key)`, rounded down to the start of a page. Like
  a mapping entry, each record's home is on a page of its own. Every record starts here, and
  rounding to a page start keeps a record of up to 127 slots on one page.
- **Packed.** A numbered position on the map's packed pages, where `rebalance` puts records side
  by side. Each packed record is stored with an *identity word*, `keccak256(map, key)`, so a
  lookup can confirm it found the right record.

One more page, the **directory**, lists every packed record by a short fingerprint with its packed
index, up to 1,016 records, so a lookup can tell whether a key is packed and where.

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

### Finding a record

`find(key)` returns the record wherever it currently lives:

1. **With a hint**, it checks that one place first: a packed index against the identity word
   there, or, in a home-hint map, `HOME` against the flag on the home page.
2. **Otherwise**, or if the hint is wrong, it searches the directory. That loads the directory
   page once per transaction, then costs about 1,000 to 1,400 gas per search.
3. **If the directory doesn't list the key**, the record is at home.

Every path ends at an identity word or the flag, so a wrong or stale hint can cost gas but never
returns the wrong record. A lookup without a hint searches again even for a record found earlier
in the call, so look a record up once per call and pass its struct along, as long as nothing in
between could rebalance. The [reference](docs/reference.md#finding-a-record) has the full lookup
and search details.

### Hints

A hint tells `find` where to look: a packed record's index plus one, or `HOME` for a record that
isn't packed. An off-chain caller gets a batch's hints from `hintOf(key)` in one `eth_call` and
sends them with the transaction. The contract loads them once with `useHints`, and every lookup in
the transaction picks them up; `find(key, hint)` takes a single hint directly instead. Callers
who know the layout, such as a market maker or a settlement operator, pass hints; anyone else
passes none.

`HOME` only works in maps made with `PagePack.mapWithHomeHints`, which keep a flag on each packed
record's home page. A `HOME` hint then confirms a record isn't packed by reading its home page
alone, at the cost of [one extra storage slot](docs/reference.md#home-hints-or-compact-storage)
per packed record. Other maps ignore it.

### Rebalancing

The admin applies layouts chosen off-chain from observed activity (see `analysis/`) with
`rebalance(evictions, placements)`. A call names only the records that move and where each ends
up, and it applies as one step, so swaps and cycles work. Packing a one-slot record costs about
58,000 gas, mostly MIP-8's charge for new storage slots, and swapping two packed records about
60,000. The library has no access control: the contract using it decides who can call it. The
[reference](docs/reference.md#rebalancing) breaks down each step and its cost.

### Why records don't pack themselves

Packing records as they are created would group them by when they arrived, not by how they are
used:

- Each new record would pay for an identity word and a sorted directory insert, roughly 40,000
  gas or more, where starting at home costs what a mapping entry does.
- Records created together are rarely the ones used together.
- A map packs at most 1,016 records, and those should be the busiest, not the first.

So every record starts at home, and only the ones worth grouping are packed.

## Using records safely

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
- **Cost.** Packing costs about 39,000 gas per record plus 18,000 to 20,000 per nonzero slot, so
  large migrations take several transactions. Packing or evicting rebuilds the directory once per
  call, which costs more as it fills. The [reference](docs/reference.md#rebalancing) has the
  tables.
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
| `docs/` | Reference: lookup and rebalance details, and their costs. |
| `analysis/` | Off-chain tooling that chooses layouts from mainnet activity *(planned)*. |

## Development

Requires [Foundry](https://getfoundry.sh). All execution uses Monad's gas schedule
(`network = "monad"` in `foundry.toml`).

```bash
make test   # unit, fuzz and invariant tests
make gas    # benchmarks and the tables in this README and docs/
make fmt
```

CI checks gas snapshots. If a change moves any benchmark, run `make gas` and commit the updated
`snapshots/` along with the change.

## License

MIT
