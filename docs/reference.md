# Reference

Details behind the [README](../README.md): how a `PagedMap` stores and finds entries, what each
step costs, and what a layout planner needs to know. Numbers are from `make gas`, on Monad's gas
schedule.

## Results

Updating existing one-slot balances in one transaction:

| Entries updated in one tx | Regular mapping | pagepack, no hint | pagepack, hinted |
| --- | ---: | ---: | ---: |
| 1 entry | 33,556 | 43,071 (+28%) | 34,846 (+4%) |
| 2 entries | 45,321 | 45,997 (+1%) | 36,485 (-19%) |
| 10 entries | 139,537 | 67,739 (-51%) | 49,705 (-64%) |
| 30 entries | 375,029 | 127,596 (-66%) | 82,677 (-78%) |
| 64 entries, a full page | 775,423 | 227,992 (-71%) | 138,787 (-82%) |
| 30 entries, 3 pages | 375,029 | 149,747 (-60%) | 104,637 (-72%) |
| 2 unpacked entries | 45,309 | 57,126 (+26%) | – |
| 2 unpacked entries, home-hint map | 45,309 | 55,948 (+23%) | 47,079 (+4%) |

The saving grows with batch size. Without hints, single-entry writes and entries that were never
packed cost more than a mapping, because finding an entry costs gas too. In a map that keeps home
flags, a `HOME` hint brings an entry that was never packed within 4% of a mapping entry, at a
[storage cost](#home-hints-or-compact-storage).

Spending from two-slot accounts under one-slot approvals, every entry packed and hinted, with the
accounts and approvals stored three ways:

| Accounts in one tx | Two maps | One map, width 2 | One map of both sizes |
| --- | ---: | ---: | ---: |
| 10 accounts | 93,132 | 84,315 (-9%) | 84,385 (-9%) |
| 25 accounts | 166,002 | 171,720 (+3%) | 161,095 (-3%) |

Two maps put accounts and approvals on pages of their own, so a spend always loads two. One map
pinned to two slots wastes a slot per approval and holds 42 entries a page, so 25 accounts and
their approvals spill onto a second page. One map of both sizes, with 50 entries per page, keeps
them on one.

## Storage layout

Every entry is in one of two places:

- **Home**, at `keccak256(map, key)` rounded down to the start of a page. Rounding keeps an entry
  of up to 127 slots on one page.
- **Packed**, at a numbered index on the map's packed pages. Each packed page starts with a
  one-slot *tag* for each of its indices, and the entries' data fills the rest of the page. A tag
  holds the entry's identity, `keccak256(map, key)`, so a lookup can confirm it found the right
  entry, with its low 14 bits replaced by where the entry's data starts on the page and its size.

The **directory** lists every packed entry by a 22-bit fingerprint with its packed index, up to
1,016 entries:

```
  directory: one page per map
  ┌───────┬────────────┬────────────┬─────┐
  │ count │ fp → index │ fp → index │ ... │   a fingerprint and packed index for each packed
  └───────┴────────────┴────────────┴─────┘   entry, sorted by fingerprint, 8 per slot

  packed pages: entries used together, side by side
  ┌─────┬─────┬─────┬─────┬────────┬────────┬───────┬────────┐
  │ tag │ tag │ ... │ tag │ data a │ data b │  ...  │ unused │   entriesPerPage() tags, then
  └─────┴─────┴─────┴─────┴────────┴────────┴───────┴────────┘   dataSlotsPerPage() slots
   index 0  1        41    each tag says where its entry's      of data: 42 tags and 86 data
                           data starts and how long it is       slots for two-slot entries

  home pages: one per entry at keccak256(map, key), like a mapping entry
  ┌──────┬──────────────────────────────────────┬──────┐
  │ data │ unused                               │ flag │   data until the entry is packed;
  └──────┴──────────────────────────────────────┴──────┘   flag while packed (home-hint maps)
```

Lookups read tags only from the tag region, which no entry's data reaches. An entry's data can
hold anything, including a word shaped like a tag, and a lookup will never read it as one.

A tag keeps 242 bits of the identity. Two keys whose identities share those bits would resolve
to the same packed entry, and finding such a pair, for example among CREATE2 addresses an
attacker controls, takes about 2^121 hashes.

### Entry sizes

A map's width is the size of the entries it looks up by default, and sets how many tags a page
has. `m.sized(slots)` returns a view of the same map for entries of another size. Lookups, hints
and fingerprints work on a view as on the map, and every size shares the map's directory and
pages.

An entry's size is part of its identity: `keccak256(map, key)` hashes a handle that includes it.
The same key looked up at two sizes names two entries, and a placement that names the wrong size
moves an empty entry, never part of a real one.

By default a page has as many tags as entries of the map's width fit on it, each with its tag:
64 for one-slot entries, 42 for two-slot. A map of several sizes can set its own count with
`map(name, slots, perPage)`, from 1 to 64, to suit its mix. Each page then has `perPage` tags and
`128 - perPage` data slots.

### Storage schema

The handle an entry's identity hashes holds the map's name, width, entries per page and
home-hint mode, plus the entry's size. Together they are the map's storage schema. Change any of
them and the entries they cover get new identities, with new homes and no packed index: the old
entries stay in storage, unreachable, and the new ones read as zero.

- Changing a map's name, width, entries per page or home-hint mode moves every entry in it.
- Changing a struct's size, by adding or widening a field, moves every entry of that kind, and
  every entry in the map if the map takes its width from that struct. A typed map measures sizes
  from its structs, so any upgrade that changes a struct's layout does this.

Treat the schema as fixed once a map holds data. To change it, give the map a new name, such as
`"vault.balances.v2"`, and migrate: read each entry through the old handle and write it through
the new one.

## Finding an entry

```
                                  find(key)
                                      │
          ┌───────────────────────────┼────────────────────────────┐
          │ hint = index + 1          │ hint = HOME                │ no hint
          v                           v                            │
  tag at index belongs          packed flag on home                │
  to this key?                  page is clear?                     │
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
                                     tag matches?               home
                                             │
                                        ┌────┴────┐
                                        │ yes     │ no
                                        v         v
                                     packed      home
```

A hint is a packed entry's index plus one, or `HOME` for an entry that isn't packed. An
offchain caller gets a batch's hints from `hintOf(key)` in one `eth_call`. The contract loads
them with `useHints`, which keeps them in transient storage so every lookup in the transaction
picks its hint up. `find(key, hint)` takes a single hint directly. `HOME` only works in maps made
with `mapWithHomeHints`. Other maps ignore it.

A hint from a view of another size than the map's own also holds that size, shifted left by 11
bits, so one `useHints` list can carry hints for every size. Hints for entries of the map's own
size are plain indices.

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
  rebalance([a to HOME, b to index 0, c to index 1])

  before                                  after
  ┌──────────┬──────────┐                 ┌──────────┬──────────┐
  │ index 0  │ index 1  │   home          │ index 0  │ index 1  │   home
  │ a        │ b        │   c             │ b        │ c        │   a
  └──────────┴──────────┘                 └──────────┴──────────┘

  1. plan      find each named entry and check the final layout is valid
  2. allocate  give each entry arriving on a page a run of free data slots
  3. clear     read every moving entry into memory and clear its old slots
  4. write     write each entry to its new slots, so b can take a's index while a leaves
  5. index     packed-to-packed moves rewrite their directory entry in place;
               packing or evicting rebuilds the directory once
```

Each placement names an entry's key, its size and its new index, or `HOME` to send it home. Size 0
means the size of the handle `rebalance` is called on: the map's own, or a view's from `sized`.
The request describes which entry holds each index after the call, so its order doesn't change
that.

pagepack picks where on the page each entry's data goes. It reads the tags of each page that
receives entries, then gives each arriving entry the first gap that fits, in placement order, so
the order can change where data lands and what the call costs. An entry moving to another index
on its own page keeps its data, so only its tag moves. If a page has enough free slots for an
entry but no gap that fits, the entries staying on it slide together first. Their indices don't
change, so their hints stay valid, but their data moves although the request didn't name them.
Treat every rebalance as moving every entry in the map: a contract must look entries up again
after it. If the page doesn't have enough free slots, `rebalance` reverts with `PageFull(page)`.

Because every old slot is cleared before any new one is written, moves within a page also avoid
MIP-8's state-growth charge.

Packing an entry from home costs about 42,000 gas plus 18,000 to 20,000 for each nonzero slot it
holds, mostly MIP-8's charge for new storage slots. Slots that are still zero cost nothing:

| Packing from home, 16 entries per call | Gas per entry |
| --- | ---: |
| 1-slot entries | 62,041 |
| 3-slot entries | 98,043 |
| 8-slot entries | 189,138 |
| 8-slot entries, 1 slot set | 66,288 |
| 1-slot entries, never written | 41,691 |
| 1-slot entries, never written, home-hint map | 62,169 |

Filling a map of 1,016 one-slot entries takes about 58M gas, so split large migrations into
transactions sized from the table above. Listing new entries in fingerprint order also skips a
sort. After that, a rebalance costs what it changes. Swapping two entries on a page costs about
62,000 gas at any size, since only their tags move. Moving an entry to another page also reads
that page's tags. Packing or evicting rebuilds the directory once per call, which grows with the
number of packed entries. Evicting also pays 17,000 gas for the entry's home slot in a default
map:

| Operation (one-slot entries, incl. 21,000 tx base) | 64 packed | 512 packed | 1,016 packed |
| --- | ---: | ---: | ---: |
| Empty rebalance | 22,075 | 22,075 | 22,075 |
| Swap two entries | 61,354 | 61,919 | 62,542 |
| Move one entry | 112,306 | 112,306 | 120,405 |
| Evict one entry | 95,331 | 152,651 | 218,270 |
| Replace one entry with another | 141,003 | 207,602 | 268,249 |
| Resubmit the whole layout | 187,179 | 1,333,427 | 2,626,743 |

Sliding entries together costs about 2,000 gas per slot moved, and only the call that needs it
pays. On a full page of a one-slot map, with two one-slot gaps apart:

| Operation | Gas |
| --- | ---: |
| Pack a 1-slot entry into a gap | 116,120 |
| Pack a 2-slot entry, moving 62 slots | 254,432 |

### Why entries don't pack themselves

Packing entries as they are created would group them by when they arrived, not by how they are
used:

- Each new entry would pay for a tag and a sorted directory insert, roughly 40,000 gas or more,
  where starting at home costs about what a mapping entry does.
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

pagepack applies layouts. Choosing them happens offchain. What a planner needs to know:

- **Capacity.** A map packs up to 1,016 entries, at indices below 1,024. The rest stay at home,
  a page each like mapping entries, and finding one still searches the directory unless it has a
  `HOME` hint. A map of several sizes can fill its pages' data before their tags, which lowers
  that limit: a one-slot map holding only four-slot entries packs 16 to a page, 256 in all.
- **Page space.** Entries with the same `index / entriesPerPage()` share a page. A page fits a
  layout if the sizes of its entries add up to at most `dataSlotsPerPage()`. By default that is
  as many entries of the map's width as there are tags: 64 one-slot entries, 42 two-slot or 32
  three-slot. In a map of several sizes, set entries per page for the mix you pack. Put fields
  that are used together in one entry, and rarely used fields in a map of their own.
- **Fingerprint collisions.** Two entries with the same fingerprint can't both be packed. Among
  1,016 random keys there's an 11.6% chance some pair collides (3.1% at 512, 0.1% at 100). Check
  new placements with `fingerprintOf` and leave one of each pair at home. Otherwise `rebalance`
  reverts with `FingerprintCollision(key)`. Keys can also be chosen: anyone who controls keys,
  such as addresses they create, can find one with a given fingerprint in about 2^22 hashes, to
  keep a particular entry from being packed or to make an unchecked layout revert. A clash never
  makes one entry read as another, since lookups check the tag. On a clash, pack whichever entry
  saves more; one already packed has no claim to its fingerprint.
- **Cost.** Packing costs about 42,000 gas per entry plus 18,000 to 20,000 per nonzero slot, so
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
  possible read (error 2527), but it reads nothing.
  [`test/TypedEntries.t.sol`](../test/TypedEntries.t.sol) checks that and shows what a wider
  struct breaks.
- **Fields.** Solidity reads and writes each field separately. To load the slot only once, read
  the fields you need in one statement and write the changed ones together, after any checks.
  Each extra field written still costs about 100 gas, where a hand-packed word is written once.

### Typed maps of several sizes

A module holding kinds of different sizes, like
[`AccountMap.sol`](../examples/accounts/AccountMap.sol), creates its map at the smallest kind's
size and looks each kind up at its own struct's size with `sized`, so a struct always fits its
entry:

```solidity
function accountMap(string memory name) view returns (AccountMap) {
    // Two-slot accounts with one-slot approvals, one each: 50 tags fit 25 of each on a page.
    return AccountMap.wrap(PagedMap.unwrap(PagePack.map(name, approvalSlots(), 50)));
}

function account(AccountMap entries, address owner) view returns (Account storage entry) {
    Entry e = entries.map().sized(accountSlots()).find(accountKey(owner));

    assembly ("memory-safe") {
        entry.slot := e
    }
}
```

Integrators' code is the same as for a map of one kind: `ACCOUNTS.account(owner).balance`.

`sized` costs a few opcodes per lookup and reverts if a struct grows past a page's data region.

A placement's size is part of the entry it names: a wrong size names another, usually empty,
entry and leaves the intended one where it is. Give the module a placement and a hint helper per
kind, so code that drives the layout never handles a size:

```solidity
function accountPlacement(address owner, uint256 index) view returns (PagePack.Placement memory) {
    return PagePack.Placement(accountKey(owner), accountSlots(), index);
}

function accountHint(AccountMap entries, address owner) view returns (PagePack.Hint memory) {
    bytes32 key = accountKey(owner);
    return PagePack.Hint(key, entries.map().sized(accountSlots()).hintOf(key));
}
```

Hints from a view carry their size, so the contract loads every kind's hints with one `useHints`
call on the map.

A map whose kinds all have the same size, like the exchange's, can instead pin its width and
check each struct against it with `requireFits` when it is created.

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

`read` and `write` offsets must stay below the size the entry was looked up at: the map's width,
or the size passed to `sized`.
