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
| 1 record | 33,556 | 43,126 (+29%) | 34,813 (+4%) |
| 2 records | 45,321 | 45,930 (+1%) | 36,445 (-20%) |
| 10 records | 139,537 | 69,210 (-50%) | 49,609 (-64%) |
| 30 records | 375,029 | 138,956 (-63%) | 82,441 (-78%) |
| 30 records, 3 pages | 375,065 | 148,356 (-60%) | 104,437 (-72%) |
| 2 unpacked records | 45,333 | 57,860 (+28%) | – |
| 2 unpacked records, home-hint space | 45,333 | 57,470 (+27%) | 47,895 (+6%) |

The saving grows with batch size, which is the case pagepack is built for, e.g. a protocol that
settles 1 to 30 accounts every few hundred milliseconds. Without hints, single-record writes and
records that were never packed cost more than a mapping, because finding a record costs gas too.
In a space that keeps home flags, a hint brings a record that was never packed within 6% of a
mapping entry, at a storage cost described under [Planning layouts](#planning-layouts).

In the [order-book exchange example](examples/exchange), modelled on the transactions that
dominate Perpl on mainnet, a market maker's re-quote costs 51% less and a taker filling against
14 makers 52% less than the same exchange on mappings.

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
  │ data │ unused                               │ flag │   data until the record is packed;
  └──────┴──────────────────────────────────────┴──────┘   flag while packed (home-hint spaces)
```

- **Spaces.** A space is a family of fixed-width records (say, one-word balances). Records only
  share pages with records in the same space, so put entities used together in one space.
- **Home and packed locations.** Every record starts on its home page, derived from its key. An
  admin calls `rebalance` to move hot records into numbered slots on packed pages. A record is
  never split across pages. In a home-hint space, a flag on the home page marks it as packed.
- **Identity words.** Each packed record is stored with its identity, `keccak256(space, key)`,
  so any lookup can confirm it found the right record. Stale data can't be returned.
- **Directory.** One page per space lists a 22-bit fingerprint and packed index for up to 1,016
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
checked against the identity word. In a home-hint space, a record that isn't packed has the hint
`HOME`, checked against its packed flag, so it costs what a mapping entry does; other spaces
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
record up once per call and pass the `Record` along, as long as nothing in between could
rebalance (see [Using records safely](#using-records-safely)).

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
batch with one `eth_call`. `find(key, hint)` takes one hint directly instead. To give records
that aren't packed a hint too, create the space with `PagePack.spaceWithHomeHints(name, words)`;
see [Planning layouts](#planning-layouts) for what that costs.

### Using records safely

`read` and `write` take a word offset. For named fields, declare a struct as wide as the space
and lay it over the record, and Solidity handles the field offsets and packing:

```solidity
struct Account {
    uint128 balance;
    uint64 nonce;
    uint64 updatedAt;
}

Space internal immutable ACCOUNTS = PagePack.space("vault.accounts", 1);

function _account(bytes32 key) internal view returns (Account storage account) {
    Record r = ACCOUNTS.find(key);
    assembly ("memory-safe") {
        account.slot := r
    }
}
```

Solidity reads and writes each field separately. To load the slot only once, read the fields you
need in one statement and write the changed ones together, after any checks. Each extra field
written still costs about 100 gas, where a hand-packed word is written once. The
[exchange example](examples/exchange/Exchange.sol) keeps all of its records this way.

A `Record` is a raw storage pointer, and so is a struct laid over one. A few rules keep them safe:

- **Fixed-size fields only.** Mappings, dynamic arrays, strings and bytes keep their contents at
  slots derived from the record's location, so a move would leave them behind. Keep them in their
  own storage, keyed by the record's key.
- **Match the width.** A struct must be exactly as wide as its space, and `read` and `write`
  offsets must stay below the width: offset `width` is already the next record's identity word.
  Nothing checks either, so test each struct's size. Two elements of a storage array sit exactly
  one struct apart, so the second one's slot is the size, counting arrays, nested structs and any
  field added later:

  ```solidity
  function _accountWords() internal view returns (uint256 words) {
      Account[2] storage pair;
      assembly ("memory-safe") {
          pair.slot := 0
      }

      Account storage second = pair[1];
      assembly ("memory-safe") {
          words := second.slot
      }
  }

  // In a test: assertEq(_accountWords(), ACCOUNTS.width());
  ```

  Declare the helper `view`, not `pure`: the compiler treats indexing a storage array as a
  possible storage read and rejects `pure` (error 2527). The helper still reads and writes no
  storage, because indexing a fixed-size array only computes a slot.

  [`test/TypedRecords.t.sol`](test/TypedRecords.t.sol) checks that it touches no storage and
  shows what a wider struct breaks. The exchange's tests run the same check on each of its
  records.
- **Look records up again after anything that could rebalance.** A `Record`, and a struct laid
  over one, points wherever the record was when you looked it up. Look it up again after anything
  in the same transaction that could rebalance, including an external call that might re-enter.

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
- **Schema changes.** A space's location comes from its name, width and mode, so widening a
  record makes a new space rather than appending to the old one. Moving to it means copying
  records.
- **Home hints or compact storage.** A default space empties a record's home page when it packs
  it. A space made with `spaceWithHomeHints` leaves a flag there instead, so a `HOME` hint can
  confirm a record isn't packed without loading the directory. Each flag is a live storage word
  that keeps its home page occupied:

  | 512 nonzero one-word records | Live storage words | Occupied pages |
  | --- | ---: | ---: |
  | Mapping | 512 | 512 |
  | pagepack, all packed | 1,089 | 9 |
  | pagepack with home hints, all packed | 1,601 | 521 |

  These are logical counts of nonzero slots, not database bytes. Flags pay off when transactions
  often touch records that aren't packed and would load the directory only for them, like the
  long-tail takers in the exchange example. They also make evicting cheaper, since the home slot
  stays occupied. The choice is part of the space, like its width: the two kinds never share
  storage, so switching means migrating.
- **Gas.** Packing a record from home costs about 39,000 gas plus 18,000 to 20,000 for each
  nonzero word it holds, mostly MIP-8's charge for new storage slots. Words that are still zero
  cost nothing:

  | Packing from home, 16 records per call | Gas per record |
  | --- | ---: |
  | 1-word records | 59,241 |
  | 3-word records | 94,922 |
  | 8-word records | 186,309 |
  | 8-word records, 1 word set | 62,997 |
  | 1-word records, never written | 38,825 |
  | 1-word records, never written, home-hint space | 59,107 |

  Filling a space of 1,016 one-word records takes about 55M gas, so split large migrations into
  transactions sized from the table above; listing new records in fingerprint order also skips a
  sort. After that, a rebalance costs what it changes. Swapping two records costs about 60,000
  gas at any size. Packing or evicting rebuilds the directory once per call, which grows with the
  number of packed records. Evicting also pays 17,000 gas for the record's home slot in a default
  space:

  | Operation (one-word records, incl. 21,000 tx base) | 64 packed | 512 packed | 1,016 packed |
  | --- | ---: | ---: | ---: |
  | Empty rebalance | 22,861 | 22,861 | 22,861 |
  | Swap two records | 59,726 | 63,102 | 61,648 |
  | Move one record | 97,413 | 101,179 | 98,589 |
  | Evict one record | 93,656 | 161,492 | 230,665 |
  | Replace one record with another | 114,303 | 178,279 | 250,839 |
  | Resubmit the whole layout | 146,866 | 1,008,186 | 1,980,958 |

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
