# pagepack

A Solidity library for Monad that moves storage entries used together onto shared pages, so
transactions that touch many of them cost less.

[MIP-8](https://github.com/monad-crypto/MIPs/blob/main/MIPs/MIP-8.md) prices storage by the
128-slot page: the first slot a transaction touches on a page costs 8,100 gas, and every other
slot on that page 100. A Solidity mapping puts each entry on its own page, so updating 30
balances pays for 30 pages.

pagepack's core type, `PagedMap`, works like a mapping, except that an admin can `rebalance` it:
move the busiest entries side by side onto shared pages. The same update then loads one page.

```
  mapping: one entry per page           PagedMap, after a rebalance
  ┌───┐ ┌───┐ ┌───┐       ┌────┐        ┌───┬───┬───┬─────┬────┐
  │ 1 │ │ 2 │ │ 3 │  ...  │ 30 │        │ 1 │ 2 │ 3 │ ... │ 30 │
  └───┘ └───┘ └───┘       └────┘        └───┴───┴───┴─────┴────┘
  30 page loads                         1 page load, with hints
```

It pays off when:

- **Transactions touch many entries.** A trade pays a dozen makers, a settlement nets many
  accounts, a keeper updates a batch of positions. A struct already keeps one owner's fields on
  one page; pagepack groups many owners' entries. A transaction touching one entry costs more
  than with a mapping (4% with a hint, 30% without), so if most of yours touch one, use a
  mapping.
- **A small set of entries is busy, and that set shifts.** An off-chain planner
  ([planned](analysis/)) watches which entries are used together, and the admin rebalances as
  that changes. Up to 1,016 entries can be packed; the rest stay one to a page, like mapping
  entries.

## Results

Updating existing one-slot balances in one transaction, from `make gas` on Monad's gas schedule:

| Entries updated in one tx | Mapping | pagepack, no hint | pagepack, hinted |
| --- | ---: | ---: | ---: |
| 1 entry | 33,556 | 43,572 (+30%) | 34,813 (+4%) |
| 2 entries | 45,321 | 46,439 (+2%) | 36,445 (-20%) |
| 10 entries | 139,537 | 67,616 (-52%) | 49,609 (-64%) |
| 30 entries | 375,029 | 123,085 (-67%) | 82,441 (-78%) |
| 64 entries, a full page | 775,423 | 215,318 (-72%) | 138,313 (-82%) |
| 2 unpacked entries | 45,309 | 56,398 (+24%) | – |

A page holds 64 packed one-slot entries, because each is stored with an identity word. Entries
that aren't packed cost more than mapping entries, since a lookup still searches the directory;
[the full table](docs/reference.md#results) includes maps whose `HOME` hints bring them within
6%.

## Usage

```bash
forge install bensprks/pagepack
```

Add `pagepack/=lib/pagepack/src/` to `remappings.txt`. Then copy
[`examples/orderbook/BalanceMap.sol`](examples/orderbook/BalanceMap.sol) for each struct you
store, renaming the struct, key and functions. Here an order book pays the makers a buy fills:

```solidity
import {PagePack} from "pagepack/PagePack.sol";
import {BalanceMap, balanceMap} from "./BalanceMap.sol";

contract OrderBook {
    BalanceMap internal immutable BALANCES = balanceMap("book.balances");

    modifier withHints(PagePack.Hint[] calldata hints) {
        BALANCES.map().useHints(hints);
        _;
    }

    function buy(uint64[] calldata askIds, PagePack.Hint[] calldata hints)
        external
        withHints(hints)
    {
        for (uint256 i; i < askIds.length; ++i) {
            Order storage ask = orders[askIds[i]];
            BALANCES.find(ask.maker).quote += ask.size * ask.price;
        }
        // ... charge the taker, remove the filled asks
    }
}
```

The same contract on a mapping:

```solidity
contract OrderBook {
    mapping(address account => Balance) internal balances;

    function buy(uint64[] calldata askIds) external {
        for (uint256 i; i < askIds.length; ++i) {
            Order storage ask = orders[askIds[i]];
            balances[ask.maker].quote += ask.size * ask.price;
        }
        // ... charge the taker, remove the filled asks
    }
}
```

`balances[maker]` becomes `BALANCES.find(maker)`, and hints are optional. The admin packs the
busiest makers with `BALANCES.map().rebalance(evictions, placements)`.

Entries share pages only within one map, so put entities used together, such as an account and
its positions, in one map with a getter per kind. The exchange's
[`ExchangeMap.sol`](examples/exchange/ExchangeMap.sol) does this, checking each struct against
the map's width with `requireFits` at deploy. To work with raw slots instead of structs, see
[using `PagedMap` directly](docs/reference.md#using-pagedmap-directly).

## How it works

An entry lives in one of two places:

- **Home**, at `keccak256(map, key)` rounded down to a page start: a page per entry, like a
  mapping. Every entry starts here.
- **Packed**, side by side on the map's packed pages, where `rebalance` puts it. Each packed
  entry follows an identity word, `keccak256(map, key)`, so a page holds
  `floor(128 / (width + 1))` entries: 64 one-slot or 42 two-slot.

A **directory** page lists the packed entries by fingerprint. `find(key)` checks the hint if
there is one, otherwise searches the directory (about 1,000 to 1,400 gas once its page is
loaded), and falls back to home if the key isn't listed. Hints are verified, so a wrong one costs
gas but never returns the wrong entry.

**Hints** let a lookup skip the directory. Callers get them off-chain from `hintOf(key)` and send
them with the transaction, and the contract loads them once with `useHints`. Maps made with
`mapWithHomeHints` also accept `HOME` for entries that aren't packed.

**Rebalancing** names only the entries that move and applies as one step, so swaps work. Packing
a one-slot entry costs about 58,000 gas and swapping two about 60,000. pagepack has no access
control: your contract decides who rebalances. Entries never pack themselves, because the
busiest entries are rarely the first ones created.

The [reference](docs/reference.md) covers the storage layout, each step's cost, and planning
layouts.

## Using entries safely

A struct from `find` is a raw storage pointer:

- **Fixed-size fields only.** Mappings, dynamic arrays, strings and bytes live at slots derived
  from the entry's location, so a move leaves them behind.
- **Fit the width.** The slot after a packed entry is the next one's identity word. A map of one
  kind takes its width from the struct; a map of several kinds checks each with `requireFits`.
- **Cast or bit-pack keys.** pagepack hashes keys already, so hash only keys over 32 bytes, and
  tag each key with its kind in a map of several kinds.
- **Look entries up again after anything that could rebalance**, including an external call that
  might re-enter.

## Upgrades

Proxies aren't supported yet. A map's name, home-hint mode, width and key encoding decide where
its entries live, so they can't change once entries are written, and pagepack's storage format
may change before 1.0. A pinned-width variant may become the upgrade path.

## Development

Requires [Foundry](https://getfoundry.sh). Everything runs on Monad's gas schedule.

```bash
make test   # unit, fuzz and invariant tests
make gas    # benchmarks; CI fails if snapshots/ is out of date
make fmt
```

## Audits

pagepack has not been audited.

## License

MIT
