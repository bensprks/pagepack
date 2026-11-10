# Reference

Details behind the [README](../README.md): how a `PagedMap` stores and finds entries, what each
step costs, and what a layout planner needs to know. Numbers are from `make gas`, on Monad's gas
schedule.

## Results

Updating existing one-slot balances in one transaction. Each figure is the whole transaction's
gas, so it includes the calldata that carries the keys and the hints. Hinted transactions pass
each lookup a 2-byte hint, the cheapest style. [Hint styles](#hint-styles) compares it with
loading hints once with `useHints`, which is simpler and is what the README's usage example does:

| Entries updated in one tx | Regular mapping | pagepack, no hint | pagepack, hinted |
| --- | ---: | ---: | ---: |
| 1 entry | 33,556 | 43,068 (+28%) | 34,773 (+4%) |
| 2 entries | 45,321 | 45,402 (+0%) | 36,254 (-20%) |
| 10 entries | 139,537 | 65,908 (-53%) | 48,210 (-65%) |
| 30 entries | 375,029 | 118,598 (-68%) | 78,150 (-79%) |
| 64 entries, a full page | 775,423 | 208,844 (-73%) | 129,144 (-83%) |
| 30 entries, 3 pages | 375,029 | 139,073 (-63%) | 100,110 (-73%) |
| 2 unpacked entries | 45,309 | 56,562 (+25%) | – |
| 2 unpacked entries, home-hint map | 45,309 | 57,120 (+26%) | 46,882 (+3%) |

The saving grows with batch size. Without hints, single-entry writes and entries that were never
packed cost more than a mapping, because finding an entry costs gas too. In a map that keeps home
flags, a `HOME` hint brings an entry that was never packed within 4% of a mapping entry, at a
[storage cost](#home-hints-or-compact-storage).

The table uses one set of keys. Without a hint, a lookup searches the directory, and how many
words it reads depends on the packed entries' fingerprints, so another key set can cost several
percent more or less. Over 16 key sets, each with 494 entries packed:

| Entries updated in one tx | No hint, mean | No hint, lowest | No hint, highest | Hinted, mean |
| --- | ---: | ---: | ---: | ---: |
| 10 entries | 68,282 | 66,420 | 70,534 | 48,209 |
| 64 entries, a full page | 216,860 | 200,574 | 230,193 | 129,125 |

Compare unhinted costs across versions or layouts by their mean. Hinted lookups skip the search,
so their cost barely depends on the keys.

Spending from two-slot accounts under one-slot approvals, against Solidity mappings of account
structs and approvals, with a hint loaded for every packed entry and the pagepack entries stored
three ways:

| Accounts in one tx | Mappings | Two maps | One map, width 2 | One map of both sizes |
| --- | ---: | ---: | ---: | ---: |
| 10 accounts | 256,407 | 79,579 (-69%) | 68,255 (-73%) | 69,513 (-73%) |
| 25 accounts | 607,662 | 131,781 (-78%) | 131,365 (-78%) | 123,578 (-80%) |

A mapping keeps an account's two slots together but puts every account and approval on a page of
its own. Two maps put accounts and approvals on pages of their own, so a spend always loads two.
One map pinned to two slots wastes a slot per approval and holds 42 entries a page, so 25
accounts and their approvals spill onto a second page. One map of both kinds, with 50 entries per
page, keeps them on one.

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

### Kinds and sizes

A map made with `map(name, slots)` holds entries of one size, its width, under keys of any 32
bytes. A map made with `mapOfKinds(name)` holds several kinds of entry, each with its own size:

```solidity
PagePack.mapOfKinds("token.accounts").withKind(APPROVAL, 1).withKind(ACCOUNT, 2).build();
```

The top byte of a key names its kind, over 31 bytes of the caller's choosing. So an entry's size
follows from the map and the key, and nothing passes one: lookups, hints and placements name an
entry by its key alone, and can't disagree about how big it is. `sizeOf(key)` returns it.

Because that byte picks the entry and its size, it must come from a constant and never from
input. A getter that ORs a caller's 32-byte id under its kind lets the caller set the byte, reach
another kind's entry, and write a wider struct over that entry's neighbours. Build keys with
`kindKey(kind, value)`, which reverts if the value doesn't fit in 31 bytes, or
`hashedKindKey(kind, hash)`, which keeps a hash's first 31 bytes.

Listing a kind decides whether its entries can be packed, not whether they can be used. A key
whose kind the map doesn't list is read and written at its home like any entry that isn't
packed, and `hintOf` answers for it, but `sizeOf` and `rebalance` revert with
`UnknownKind(kind)`. To catch a kind left out of the list when the map is created, check it
with `requireFits(kind, slots)`.

A map lists at most eight kinds, numbered 0 to 7. Kinds of the same size can share a number and
tell their keys apart in the next byte, so the limit is eight sizes, not eight entities.

By default a page has as many tags as entries fit on it, each with its tag, taking a map's kinds
in equal numbers: 64 for one-slot entries, 42 for two-slot, and 50 for a map of one- and two-slot
kinds, 25 of each. `withEntriesPerPage(perPage)` on the built map sets another count, from 1 to
64, for a mix the default doesn't suit. Each page then has `perPage` tags and `128 - perPage`
data slots, and every kind must fit those.

### Storage schema

The handle an entry's identity hashes holds the map's name, its kinds' sizes, entries per page
and home-hint mode. Together they are the map's storage schema. Change any of them and every
entry in the map gets a new identity, with a new home and no packed index: the old entries stay
in storage, unreachable, and the new ones read as zero.

- Changing a map's name, entries per page or home-hint mode does this.
- So does adding a kind, which also changes the default entries per page, or changing a struct's
  size by adding or widening a field. A typed map measures sizes from its structs, so any
  upgrade that changes a struct's layout does this.
- Giving an entry another kind changes its key, so it is another entry.

pagepack doesn't support upgrades, so the schema is fixed once a map holds data: list every kind
the map will need when it is created. To change it anyway, give the map a new name, such as
`"vault.balances.v2"`, and migrate: read each entry through the old handle and write it through
the new one.

### Limits

| Limit | Value |
| --- | --- |
| Packed entries per map | 1,016, at indices below 1,024. The rest stay at home |
| Entry size | 1 to 127 slots, fixed-size fields only |
| Entries per page | 1 to 64. A page's entries also have to fit its `128 - perPage` data slots |
| Kinds per map | 8, numbered 0 to 7. Kinds of one size can share a number |
| Keys | 32 bytes in a map of one kind. 31 bytes under the kind in a map of kinds |
| Schema | Fixed once the map holds data. No upgrades or proxies |
| Map name | Hashed to 176 bits |
| Tag | 242 bits of an entry's identity |
| Fingerprint | 22 bits. Two entries that share one can't both be packed |
| Hint | 11 bits: a packed index plus one, or `HOME`, 1,025 |
| Hint in calldata | 5 bytes loaded with `useHints`, or 2 bytes passed to a lookup with `hintAt` |

Two keys that resolve to one packed entry take about 2^121 hashes to find, and two hashed keys
that agree on their 31 bytes about 2^124. Two map names that hash to the same 176 bits take about
2^88, so name maps with constants, not with text a user supplies.

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

A hint is a packed entry's index plus one, or `HOME` for an entry that isn't packed. `HOME` only
works in maps made with `mapWithHomeHints`. Other maps ignore it. `hintOf(key)` returns an
entry's hint, or 0 if there is none to give. Hints are the same for every kind. A lookup checks
every hint, against the entry's tag or, for `HOME`, its home flag, so a wrong or stale hint
costs gas but never returns the wrong entry. [Hint styles](#hint-styles) covers the two ways a
hint reaches a lookup, and what each costs.

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

### Hint styles

A contract takes hints in one of two ways:

- **Loaded with `useHints`.** The caller sends one `bytes` argument, 5 bytes for each entry, and
  the contract loads it once, usually in a modifier. Every `find(key)` in the transaction then
  picks its hint up from transient storage. Each hint is big-endian: 7 zero bits, the entry's
  22-bit fingerprint, then its 11-bit hint. So the caller sends no keys, and the hints can come
  in any order, for entries of every kind. `packedHintsOf(keys)` builds the argument: expose it
  in a view function, and one `eth_call` returns a transaction's hints. Use this style when
  lookups are spread through the code, as in the [exchange example](../examples/exchange).
- **Passed to each lookup.** A function that already loops over its keys calls
  `find(keys[i], hint)`. `PagePack.hintAt(hints, i)` reads hint `i` from a `bytes` argument of
  2-byte big-endian hints, each its key's `hintOf`, in the order of the lookups. `hintsOf(keys)`
  builds that argument. A key with no hint still takes 2 bytes, as zero, so the hints after it
  keep their positions. Past the end `hintAt` returns 0, no hint. This style costs the least,
  because nothing is stored and read back, but the caller has to know the order of the lookups.
  A typed map needs a getter that takes the hint and passes it to `find(key, hint)`.

The same batch update with each style, and with a `uint256[]` that spends a word on each hint:

| Entries updated in one tx | No hint | `useHints`, 5 bytes a hint | `find(key, hint)`, a word a hint | `find(key, hint)`, 2 bytes a hint |
| --- | ---: | ---: | ---: | ---: |
| 1 entry | 43,068 | 35,267 (-18%) | 34,890 (-19%) | 34,773 (-19%) |
| 10 entries | 65,908 | 51,712 (-22%) | 49,542 (-25%) | 48,210 (-27%) |
| 30 entries | 118,598 | 88,208 (-26%) | 82,054 (-31%) | 78,150 (-34%) |
| 64 entries, a full page | 208,844 | 150,386 (-28%) | 137,382 (-34%) | 129,144 (-38%) |

A loaded hint is kept in transient storage at the directory's slot plus the fingerprint, so two
keys with the same fingerprint share one. That is safe because a lookup checks a loaded hint
like any other: the key it wasn't loaded for finds another entry's tag there, or its own home
flag set, and falls back to the directory. Malformed hints are harmless too. `useHints` checks
nothing: a hint for a fingerprint no lookup asks about is never read, one out of range is
ignored, and bytes left after the last whole hint are dropped.

**Calldata.** Hints are calldata, and calldata is part of what a hinted transaction costs: 4 gas
for a zero byte and 16 for any other. A transaction also pays at least 21,000 gas plus 10 for
each calldata token, where a zero byte is one token and any other byte four (EIP-7623), however
little it executes. A batch that sends many bytes and does little with each entry sits on that
floor, where a hint saves nothing and each of its nonzero bytes costs 40 gas. Hints are a few
bytes and carry no key for that reason. The benchmarks measure whole transactions, so every
figure includes its calldata and, where it applies, the floor.

**Gas limits.** Monad charges a transaction for its gas limit, not for the gas it uses. A caller
who sets the limit from an estimate made with fresh hints leaves no room for a rebalance that
lands first and makes them stale. A stale hint still finds its entry, but through the directory:
one page load, 8,100 gas, if nothing else in the transaction loaded it, plus a search of about
1,000 to 1,400 gas for each lookup. Before that it reads the tag or flag it pointed at, which is
another page load if the transaction doesn't otherwise touch that page. Leave headroom for
stale hints in the limit, or the transaction can run out of gas.

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

Each placement names an entry's key and its new index, or `HOME` to send it home. The entry's
size is the map's width, or the size of the kind in the key's top byte. The request describes
which entry holds each index after the call, so its order doesn't change that.

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

Packing an entry from home costs about 41,000 gas plus 18,000 to 20,000 for each nonzero slot it
holds, mostly MIP-8's charge for new storage slots. Slots that are still zero cost nothing:

| Packing from home, 16 entries per call | Gas per entry |
| --- | ---: |
| 1-slot entries | 61,425 |
| 3-slot entries | 97,227 |
| 8-slot entries | 188,246 |
| 8-slot entries, 1 slot set | 65,396 |
| 1-slot entries, never written | 41,075 |
| 1-slot entries, never written, home-hint map | 61,446 |

Filling a map of 1,016 one-slot entries takes about 57M gas, so split large migrations into
transactions sized from the table above. Listing new entries in fingerprint order also skips a
sort. After that, a rebalance costs what it changes. Swapping two entries on a page costs about
60,000 gas at any size, since only their tags move. Moving an entry to another page also reads
that page's tags, about 200 gas each: 13,000 for a page of 64. Packing or evicting rebuilds the
directory once per call, which grows with the number of packed entries. Evicting also pays
17,000 gas for the entry's home slot in a default map:

| Operation (one-slot entries, incl. 21,000 tx base) | 64 packed | 512 packed | 1,016 packed |
| --- | ---: | ---: | ---: |
| Empty rebalance | 22,006 | 22,006 | 22,006 |
| Swap two entries | 59,751 | 60,886 | 60,934 |
| Move one entry | 111,560 | 112,125 | 120,243 |
| Evict one entry | 95,123 | 157,058 | 227,826 |
| Replace one entry with another | 138,745 | 199,852 | 269,676 |
| Resubmit the whole layout | 160,950 | 1,122,846 | 2,208,766 |

Sliding entries together costs 6,000 to 7,000 gas for each entry moved, plus about 2,000 for each
of its slots after the first, and only the call that needs it pays. So a page of many small
entries costs more to compact than a page of a few wide ones. On a full page of 64 tags and 64
data slots, after some of its entries left:

| Page before the call | Operation | Gas |
| --- | --- | ---: |
| Entries of 30 and 32 slots, two one-slot gaps | Pack a 1-slot entry into a gap | 115,568 |
| | Pack a 2-slot entry, moving 62 slots | 242,255 |
| 32 one-slot entries, 16 two-slot gaps | Pack a 2-slot entry into a gap | 161,775 |
| 32 one-slot entries, 32 one-slot gaps | Pack a 2-slot entry, moving 32 entries | 347,655 |

One call can make room on many pages, and a page costs the same to compact whatever else the
call does. Take full pages of 64 one-slot entries, and a call that on each page evicts 32 of them
and packs 16 two-slot entries. Evicted two by two, they leave gaps that fit. Evicted every other
one, they leave none, so every page compacts:

| Pages in one call | Gaps fit | Pages compact | Compacting, per page |
| --- | ---: | ---: | ---: |
| 1 page | 1,553,716 | 1,777,574 | 223,858 |
| 8 pages | 12,324,514 | 14,098,698 | 221,773 |

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
  `HOME` hint. A map of several kinds can fill its pages' data before their tags, which lowers
  that limit: pages of 64 tags holding only four-slot entries pack 16 each, 256 in all.
- **Page space.** Entries with the same `index / entriesPerPage()` share a page. A page fits a
  layout if the sizes of its entries add up to at most `dataSlotsPerPage()`. By default that is
  as many entries of the map's width as there are tags: 64 one-slot entries, 42 two-slot or 32
  three-slot. A map of several kinds has room for the same number of each by default. If you
  pack another mix, set entries per page for it. Put fields that are used together in one entry,
  and rarely used fields in a map of their own.
- **Fingerprint collisions.** Two entries with the same fingerprint can't both be packed. Among
  1,016 random keys there's an 11.6% chance some pair collides (3.1% at 512, 0.1% at 100). Check
  new placements with `fingerprintOf` and leave one of each pair at home. Otherwise `rebalance`
  reverts with `FingerprintCollision(key)`. Keys can also be chosen: anyone who controls keys,
  such as addresses they create, can find one with a given fingerprint in about 2^22 hashes, to
  keep a particular entry from being packed or to make an unchecked layout revert. A clash never
  makes one entry read as another, since lookups check the tag. On a clash, pack whichever entry
  saves more; one already packed has no claim to its fingerprint.
- **Cost.** Packing costs about 41,000 gas per entry plus 18,000 to 20,000 per nonzero slot, so
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

### Typed maps of several kinds

A module holding kinds of different sizes, like
[`AccountMap.sol`](../examples/accounts/AccountMap.sol), lists each kind with its struct's size
when it creates the map, and builds each key with its kind in the top byte, so a struct always
fits its entry:

```solidity
uint256 constant APPROVAL = 0;
uint256 constant ACCOUNT = 1;

function accountMap(string memory name) view returns (AccountMap) {
    PagedMap entries = PagePack.mapOfKinds(name)
        .withKind(APPROVAL, approvalSlots())
        .withKind(ACCOUNT, accountSlots())
        .build();

    return AccountMap.wrap(PagedMap.unwrap(entries));
}

function accountKey(address owner) pure returns (bytes32) {
    return PagePack.kindKey(ACCOUNT, uint160(owner));
}

function approvalKey(address owner, address spender) pure returns (bytes32) {
    return PagePack.hashedKindKey(APPROVAL, keccak256(abi.encode(owner, spender)));
}

function account(AccountMap entries, address owner) view returns (Account storage entry) {
    Entry e = entries.map().find(accountKey(owner));

    assembly ("memory-safe") {
        entry.slot := e
    }
}
```

Integrators' code is the same as for a map of one kind: `ACCOUNTS.account(owner).balance`.

Use the same constant for a kind in `withKind` and in its key functions, as above: that is what
ties a struct to its entry's size. Every getter builds its key through a key function, and no
key function lets its input reach the top byte. A map whose sizes are set by hand, not taken
from structs, checks each struct with `requireFits(kind, slots)` when it is created.

Code that drives the layout names entries by key alone, with the module's key functions:
`PagePack.Placement(accountKey(owner), index)` for a placement, and
`ACCOUNTS.map().packedHintsOf(keys)` for a transaction's hints. The contract loads every kind's
hints with one `useHints` call.

A map whose kinds all have the same size, like the exchange's, can instead pin its width with
`map(name, slots)` and check each struct against it with `requireFits` when it is created. Its
keys are any 32 bytes, so its kinds are only a convention, but the same rule holds for them:
keep input out of the byte that tells kinds apart.

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

`read` and `write` offsets must stay below the entry's size: the map's width, or `sizeOf(key)`
in a map of several kinds.
