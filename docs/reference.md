# Reference

Details behind the [README](../README.md): how lookups and rebalances work step by step, and what
they cost. Numbers are from `make gas`, on Monad's gas schedule.

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

The directory lists a 22-bit fingerprint and packed index for each packed entry, sorted by
fingerprint, 8 to a storage word. Fingerprints are evenly spread hash bits, so a search
interpolates which word should hold the key's fingerprint, reads it and compares all 8 entries at
once. A miss rules out everything on one side of that word, so the next guess is close. Entries
at home cost the same to search for as packed ones. Over random directories, with the page
already loaded:

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
