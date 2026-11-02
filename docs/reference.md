# Reference

Details behind the [README](../README.md): how a `PagedMap` stores and finds entries, what each
step costs, and what a layout planner needs to know. Numbers are from `make gas`, on Monad's gas
schedule.

## Results

Updating existing one-slot balances in one transaction:

| Entries updated in one tx | Mapping | pagepack, no hint | pagepack, hinted |
| --- | ---: | ---: | ---: |
| 1 entry | 33,556 | 43,572 (+30%) | 34,813 (+4%) |
| 2 entries | 45,321 | 46,439 (+2%) | 36,445 (-20%) |
| 10 entries | 139,537 | 67,616 (-52%) | 49,609 (-64%) |
| 30 entries | 375,029 | 123,085 (-67%) | 82,441 (-78%) |
| 64 entries, a full page | 775,423 | 215,318 (-72%) | 138,313 (-82%) |
| 30 entries, 3 pages | 375,029 | 141,802 (-62%) | 104,401 (-72%) |
| 2 unpacked entries | 45,309 | 56,398 (+24%) | – |
| 2 unpacked entries, home-hint map | 45,309 | 57,547 (+27%) | 47,871 (+6%) |

The saving grows with batch size. Without hints, single-entry writes and entries that were never
packed cost more than a mapping, because finding an entry costs gas too. In a map that keeps home
flags, a `HOME` hint brings an entry that was never packed within 6% of a mapping entry, at a
[storage cost](#home-hints-or-compact-storage).

## Storage layout

Every entry is in one of two places:

- **Home**, at `keccak256(map, key)` rounded down to the start of a page. Rounding keeps an entry
  of up to 127 slots on one page.
- **Packed**, at a numbered index on the map's packed pages. Each packed entry is stored after an
  *identity word*, `keccak256(map, key)`, so a lookup can confirm it found the right entry.

The **directory** lists every packed entry by a 22-bit fingerprint with its packed index, up to
1,016 entries:

```
  directory: one page per map
  ┌───────┬────────────┬────────────┬─────┐
  │ count │ fp → index │ fp → index │ ... │   a fingerprint and packed index for each packed
  └───────┴────────────┴────────────┴─────┘   entry, sorted by fingerprint, 8 per slot

  packed pages: entries used together, side by side
  ┌────┬──────┬────┬──────┬─────┬────┬──────┬────────┐
  │ id │ data │ id │ data │ ... │ id │ data │ unused │   floor(128 / (width + 1)) entries
  └────┴──────┴────┴──────┴─────┴────┴──────┴────────┘   per page: 42 for two-slot entries
   index 0     index 1           index 41

  home pages: one per entry at keccak256(map, key), like a mapping entry
  ┌──────┬──────────────────────────────────────┬──────┐
  │ data │ unused                               │ flag │   data until the entry is packed;
  └──────┴──────────────────────────────────────┴──────┘   flag while packed (home-hint maps)
```

## Finding an entry

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

A hint is a packed entry's index plus one, or `HOME` for an entry that isn't packed. An
off-chain caller gets a batch's hints from `hintOf(key)` in one `eth_call`. The contract loads
them with `useHints`, which keeps them in transient storage so every lookup in the transaction
picks its hint up; `find(key, hint)` takes a single hint directly. `HOME` only works in maps made
with `mapWithHomeHints`; other maps ignore it.

A lookup without a hint searches the directory again even for an entry found earlier in the
call, so look an entry up once per call and pass its struct along, as long as nothing in between
could rebalance.

The directory lists entries sorted by fingerprint, 8 to a storage word. Fingerprints are evenly
spread hash bits, so a search interpolates which word should hold the key's fingerprint, reads it
and compares all 8 entries at once. A miss rules out everything on one side of that word, so the
next guess is close. Entries at home cost the same to search for as packed ones. Over random
directories, with the page already loaded:

| Directory and entry | Probes, mean | Probes, max | Gas, mean | Gas, max |
| --- | ---: | ---: | ---: | ---: |
| 64 packed, packed entry | 1.25 | 3 | 968 | 1,998 |
| 64 packed, entry at home | 1.33 | 3 | 1,006 | 2,012 |
| 512 packed, packed entry | 1.81 | 4 | 1,294 | 2,592 |
| 512 packed, entry at home | 1.92 | 4 | 1,348 | 2,601 |
| 1016 packed, packed entry | 1.94 | 4 | 1,362 | 2,592 |
| 1016 packed, entry at home | 1.96 | 4 | 1,368 | 2,606 |

Probes are the directory words read after the count. Fingerprints chosen to defeat the guess, as
keys ground to be packed could be, make the search fall back to bisection after five probes,
which caps it at 12.

## Rebalancing

```
  rebalance(evictions: [a], placements: [b at index 0, c at index 1])

  before                                  after
  ┌──────────┬──────────┐                 ┌──────────┬──────────┐
  │ index 0  │ index 1  │   home          │ index 0  │ index 1  │   home
  │ a        │ b        │   c             │ b        │ c        │   a
  └──────────┴──────────┘                 └──────────┴──────────┘

  1. plan    find each named entry and check the final layout is valid
  2. clear   read every moving entry into memory and clear its old slots
  3. write   write each entry to its new slots, so b can take a's index while a leaves
  4. index   packed-to-packed moves rewrite their directory entry in place;
             packing or evicting rebuilds the directory once
```

Because every old slot is cleared before any new one is written, moves within a page also avoid
MIP-8's state-growth charge.

Packing an entry from home costs about 39,000 gas plus 18,000 to 20,000 for each nonzero slot it
holds, mostly MIP-8's charge for new storage slots. Slots that are still zero cost nothing:

| Packing from home, 16 entries per call | Gas per entry |
| --- | ---: |
| 1-slot entries | 58,472 |
| 3-slot entries | 94,481 |
| 8-slot entries | 185,948 |
| 8-slot entries, 1 slot set | 62,636 |
| 1-slot entries, never written | 38,056 |
| 1-slot entries, never written, home-hint map | 58,396 |

Filling a map of 1,016 one-slot entries takes about 55M gas, so split large migrations into
transactions sized from the table above; listing new entries in fingerprint order also skips a
sort. After that, a rebalance costs what it changes. Swapping two entries costs about 60,000 gas
at any size. Packing or evicting rebuilds the directory once per call, which grows with the
number of packed entries. Evicting also pays 17,000 gas for the entry's home slot in a default
map:

| Operation (one-slot entries, incl. 21,000 tx base) | 64 packed | 512 packed | 1,016 packed |
| --- | ---: | ---: | ---: |
| Empty rebalance | 22,883 | 22,883 | 22,883 |
| Swap two entries | 59,458 | 60,047 | 61,206 |
| Move one entry | 97,680 | 98,269 | 98,286 |
| Evict one entry | 93,923 | 158,582 | 230,362 |
| Replace one entry with another | 114,331 | 175,331 | 250,472 |
| Resubmit the whole layout | 146,888 | 1,008,208 | 1,980,980 |

### Why entries don't pack themselves

Packing entries as they are created would group them by when they arrived, not by how they are
used:

- Each new entry would pay for an identity word and a sorted directory insert, roughly 40,000
  gas or more, where starting at home costs about what a mapping entry does.
- Entries created together are rarely the ones used together.
- A map packs at most 1,016 entries, and those should be the busiest, not the first.

## Home hints or compact storage

A default map empties an entry's home page when it packs it. A map made with `mapWithHomeHints`
leaves a flag there instead, so a `HOME` hint can confirm an entry isn't packed without loading
the directory. Each flag is a live storage slot that keeps its home page occupied:

| 512 nonzero one-slot entries | Live storage slots | Occupied pages |
| --- | ---: | ---: |
| Mapping | 512 | 512 |
| pagepack, all packed | 1,089 | 9 |
| pagepack with home hints, all packed | 1,601 | 521 |

These are logical counts of nonzero slots, not database bytes. Flags pay off when transactions
often touch entries that aren't packed and would load the directory only for them, like the
long-tail takers in the exchange example. They also make evicting cheaper, since the home slot
stays occupied. The choice is part of the map, like its width: the two kinds never share storage,
so switching means migrating.

## Planning layouts

pagepack applies layouts; choosing them happens off-chain. What a planner needs to know:

- **Capacity.** A map packs up to 1,016 entries, at indices below 1,024. The rest stay at home,
  a page each like mapping entries, and finding one still searches the directory unless it has a
  `HOME` hint.
- **Fingerprint collisions.** Two entries with the same fingerprint can't both be packed. Among
  1,016 random keys there's an 11.6% chance some pair collides (3.1% at 512, 0.1% at 100). Check
  new placements with `fingerprintOf` and leave one of each pair at home; otherwise `rebalance`
  reverts with `FingerprintCollision(key)`.
- **Entry width.** All entries in a map have the same width, plus one identity word each when
  packed, so a page holds `floor(128 / (width + 1))` of them: 64 one-slot entries, 42 two-slot or
  32 three-slot. Put fields that are used together in one entry, and rarely used fields in a
  map of their own.
- **Cost.** Packing costs about 39,000 gas per entry plus 18,000 to 20,000 per nonzero slot, so
  large migrations take several transactions. Packing or evicting rebuilds the directory once per
  call, which costs more as it fills. See [Rebalancing](#rebalancing) for the tables.
- **Payback.** A rebalance pays off when the page loads it saves before the next one exceed its
  cost. Measure that against the current layout, not against mappings: moving an entry that
  already shares a page with the entries it is used with saves nothing.

## Typed maps

A typed map module, like [`BalanceMap.sol`](../examples/orderbook/BalanceMap.sol), wraps a
`PagedMap` in its own type and returns its struct from `find`.

- **Width.** The module measures its struct by array stride: in a `T[2] storage` array placed at
  slot 0, element 1's slot is T's size in slots. That counts arrays, nested structs and fields
  added later. The helper must be `view`, since the compiler treats indexing a storage array as a
  possible read (error 2527), but it reads nothing;
  [`test/TypedEntries.t.sol`](../test/TypedEntries.t.sol) checks that and shows what a wider
  struct breaks.
- **Fields.** Solidity reads and writes each field separately. To load the slot only once, read
  the fields you need in one statement and write the changed ones together, after any checks.
  Each extra field written still costs about 100 gas, where a hand-packed word is written once.

## Using `PagedMap` directly

A typed map is a thin layer over `PagedMap` and `Entry`. `find(key)` on a `PagedMap` returns an
`Entry`, the slot where the entry's data starts, and `read` and `write` use it a slot at a time:

```solidity
import {Entry, PagePack, PagedMap} from "pagepack/PagePack.sol";

PagedMap internal immutable BALANCES = PagePack.map("vault.balances", 1);

function credit(bytes32 key, uint256 amount) internal {
    Entry e = BALANCES.find(key);
    e.write(0, e.read(0) + amount);
}
```

`read` and `write` offsets must stay below the map's width.
