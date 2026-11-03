# pagepack

A Solidity library for Monad that lets you move storage entries that are used together onto the
same MIP-8 pages, to reduce gas costs by up to 83%.

**Storage on Monad.** Under [MIP-8](https://github.com/monad-crypto/MIPs/blob/main/MIPs/MIP-8.md),
Monad groups each contract's storage into pages of 128 consecutive slots. The first slot a
transaction touches on a page costs 8,100 gas. Every other slot on that page costs 100.

**Problem.** A Solidity mapping stores each value at `keccak256(key, slot)`
([Solidity docs](https://docs.soliditylang.org/en/latest/internals/layout_in_storage.html#mappings-and-dynamic-arrays)),
so its values land on unrelated slots, almost always on different pages. A transaction that
updates 30 mapping entries loads 30 pages and pays the 8,100 gas for each.

**Solution.** pagepack's core type, `PagedMap`, works like a mapping, except that an admin can
`rebalance` it: move entries that are used together side by side onto shared pages. The same 30
updates then load one page.

```
  mapping: one entry per page           PagedMap, after a rebalance
  ┌───┐ ┌───┐ ┌───┐       ┌────┐        ┌───┬───┬───┬─────┬────┐
  │ 1 │ │ 2 │ │ 3 │  ...  │ 30 │        │ 1 │ 2 │ 3 │ ... │ 30 │
  └───┘ └───┘ └───┘       └────┘        └───┴───┴───┴─────┴────┘
  30 page loads                         1 page load, with hints
```

It pays off when:

- **Transactions touch entries under many different keys.** A mapping of structs already keeps
  one key's fields on one page. pagepack puts entries under different keys on the same page. A
  transaction that touches one entry costs more than with a regular mapping: +3% with a hint, +30%
  without.
- **A small set of entries gets most of the traffic, and that set changes over time.** An
  offchain planner tracks which entries are used together, and the admin calls `rebalance` to
  repack them. Up to 1,016 entries can be packed. The rest stay one per page, as in a regular
  mapping.

## Results

Updating existing one-slot balances in one transaction, from `make gas` on Monad's gas schedule,
compiled with Solar 0.3.0. With solc 0.8.38, each figure is 1% to 12% higher:

| Entries updated in one tx | Regular mapping | pagepack, no hint | pagepack, hinted |
| --- | ---: | ---: | ---: |
| 1 entry | 33,210 | 43,034 (+30%) | 34,133 (+3%) |
| 2 entries | 44,836 | 45,609 (+2%) | 35,474 (-21%) |
| 10 entries | 137,940 | 64,589 (-53%) | 46,310 (-66%) |
| 30 entries | 370,652 | 114,376 (-69%) | 73,322 (-80%) |
| 64 entries, a full page | 766,320 | 197,135 (-74%) | 126,700 (-83%) |
| 2 unpacked entries | 44,824 | 55,447 (+24%) | – |

A page holds 64 one-slot entries, not 128, because each packed entry is stored next to a one-slot
identity word. Entries that aren't packed cost more than in a regular mapping, because the lookup
still searches the directory. In a map created with `mapWithHomeHints`, a `HOME` hint reduces this
to +3% (see the [full table](docs/reference.md#results)).

## Usage

Example: when a buy order fills several asks, the order book credits each ask's maker.
`BalanceMap` is a small module you copy into your project (see [Setup](#setup)).

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

### Setup

1. Install pagepack:

   ```bash
   forge install bensprks/pagepack
   ```

2. Add `pagepack/=lib/pagepack/src/` to `remappings.txt`.
3. Compile with Solidity 0.8.24 or later and `evm_version` set to `cancun` or later. pagepack
   uses transient storage. Cancun is the default from Solidity 0.8.25.
4. Copy [`examples/orderbook/BalanceMap.sol`](examples/orderbook/BalanceMap.sol) once for each
   struct you store, and rename the struct, key and functions.

## How it works

An entry lives in one of two places:

- **Home**: `keccak256(map, key)`, rounded down to the start of a page. Each entry has its own
  home page, as in a regular mapping. Every entry starts at home.
- **Packed**: a position on the map's packed pages, assigned by `rebalance`. Each packed entry is
  stored after an identity word, `keccak256(map, key)`, so a page holds
  `floor(128 / (width + 1))` entries: 64 one-slot or 42 two-slot.

A **directory** page lists the packed entries by fingerprint. `find(key)` checks the hint if
there is one, otherwise searches the directory (about 850 to 1,250 gas once its page is
loaded), and falls back to home if the key isn't listed. Hints are verified, so a wrong one costs
gas but never returns the wrong entry.

**Hints** let a lookup skip the directory. Callers get them offchain from `hintOf(key)` and send
them with the transaction, and the contract loads them once with `useHints`. Maps made with
`mapWithHomeHints` also accept `HOME` for entries that aren't packed.

**Rebalancing** takes a list of entries to move and their new positions, and applies all moves at
once, so two entries can swap positions. Packing a one-slot entry costs about 57,000 gas. Swapping
two packed entries costs about 56,000. pagepack has no access control: your contract decides who
rebalances. New entries always start on their home pages. Only `rebalance` packs them.

The [reference](docs/reference.md) covers the storage layout, each step's cost, and planning
layouts.

## Using entries safely

A struct from `find` is a raw storage pointer:

- **Fixed-size fields only.** Mappings, dynamic arrays, strings and bytes live at slots derived
  from the entry's location, so a move leaves them behind.
- **Fit the width.** The slot after a packed entry is the next one's identity word. A map of one
  kind takes its width from the struct. A map of several kinds checks each struct with
  `requireFits`.
- **Cast or bit-pack keys.** pagepack already hashes the key, so don't hash keys that fit in 32
  bytes. In a map of several kinds, include the kind in the key so keys of different kinds can't
  collide.
- **Look entries up again after anything that could rebalance**, including an external call that
  might re-enter.

## Upgrades

Proxies aren't supported yet. A map's name, home-hint mode, width and key encoding determine where
its entries are stored, so they can't change after entries are written. pagepack's own storage
format may change before 1.0. A future version may support upgrades using maps with a fixed width
set in advance, leaving room for structs to grow.

## Development

Requires [Foundry](https://getfoundry.sh) v1.9.0 or later, the version CI uses. `foundry.toml`
compiles with Solar, which ships with Foundry, and sets `network = "monad"`, so tests and
benchmarks run on Monad's gas schedule. CI also runs the tests with solc 0.8.38.

```bash
make test   # unit, fuzz and invariant tests
make gas    # benchmarks; CI fails if snapshots/ is out of date
make fmt
```

## Audits

pagepack has not been audited.

## License

MIT
