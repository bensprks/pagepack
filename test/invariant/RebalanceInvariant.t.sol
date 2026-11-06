// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PagePack, PagedMap} from "pagepack/PagePack.sol";
import {EntryStore} from "../utils/EntryStore.sol";

/// Drives a store with random writes, rebalances and swaps, keeping a model of where every entry
/// should be and what it should hold. Entries are one to four slots, so pages mix sizes and
/// rebalancing has to find, and sometimes make, room. Rebalance requests are mostly valid, with
/// some deliberately broken ones; the model decides independently which should succeed.
contract RebalanceHandler is Test {
    uint256 public constant KEYS = 64;
    uint256 public constant MAX_SLOTS = 4;

    // A map of one-slot entries: 64 tags and 64 data slots per page. 100 indices spread over two
    // packed pages and up to five directory words. Entries average 2.5 slots, so a page fills
    // before its tags run out.
    uint256 public constant PER_PAGE = 64;
    uint256 public constant DATA_SLOTS = 64;
    uint256 public constant INDICES = 100;

    EntryStore public immutable store;
    bytes32[KEYS] internal keys;

    // The model: each key's packed index plus one (0 at home), the reverse, and the data.
    uint256[KEYS] public indexOf;
    uint256[INDICES] internal keyAt;
    uint256[MAX_SLOTS][KEYS] internal values;

    uint256 public packed;
    uint256 public accepted;
    uint256 public rejected;
    uint256 public mismatches;

    constructor(EntryStore store_) {
        store = store_;

        for (uint256 i; i < KEYS; ++i) {
            keys[i] = keccak256(abi.encode("invariant", i));
        }
    }

    function key(uint256 k) external view returns (bytes32) {
        return keys[k];
    }

    function valueOf(uint256 k, uint256 w) external view returns (uint256) {
        return values[k][w];
    }

    function keyAtIndex(uint256 index) external view returns (uint256) {
        return keyAt[index];
    }

    /// Keys take turns being one, two, three and four slots.
    function slotsOf(uint256 k) public pure returns (uint256) {
        return 1 + k % MAX_SLOTS;
    }

    // ------------------------------------------------------------------------------------------
    // Actions
    // ------------------------------------------------------------------------------------------

    /// Writes a data slot, zero a quarter of the time so rebalances also move empty slots.
    function write(uint256 k, uint256 w, uint256 value) external {
        k %= KEYS;
        w %= slotsOf(k);
        if (value % 4 == 0) value = 0;

        store.setSized(keys[k], slotsOf(k), w, value);
        values[k][w] = value;
    }

    /// Submits a random request of up to six items.
    function rebalance(uint256 seed) external {
        uint256 count = 1 + seed % 6;
        uint256 first = _random(seed, 0) % KEYS;
        uint256 step = 1 + 2 * (_random(seed, 1) % (KEYS / 2));

        uint256[] memory evicted = new uint256[](count);
        uint256[] memory placedKeys = new uint256[](count);
        uint256[] memory placedAt = new uint256[](count);
        uint256 evictions;
        uint256 placements;

        for (uint256 i; i < count; ++i) {
            // Distinct keys, except for an occasional deliberate repeat.
            uint256 k = (first + i * step) % KEYS;
            if (i != 0 && _random(seed, 100 + i) % 16 == 0) k = (first + (i - 1) * step) % KEYS;

            uint256 roll = _random(seed, 200 + i);

            if (roll % 4 == 0) {
                // Occasionally evicts an entry that isn't packed.
                evicted[evictions++] = k;
            } else {
                placedKeys[placements] = k;
                placedAt[placements++] = _target(roll);
            }
        }

        _submit(evicted, evictions, placedKeys, placedAt, placements, seed);
    }

    /// Packs up to six entries from home at free indices on one page, so pages fill up and
    /// later requests have to find, or make, room. Valid unless the page is too full.
    function pack(uint256 seed) external {
        uint256 count = 1 + seed % 6;
        uint256 page = _random(seed, 0) % 2;
        uint256 k = _random(seed, 1) % KEYS;

        uint256[] memory placedKeys = new uint256[](count);
        uint256[] memory placedAt = new uint256[](count);
        uint256 placements;

        for (uint256 i; i < count; ++i) {
            for (uint256 tries; tries < KEYS && indexOf[k] != 0; ++tries) {
                k = (k + 1) % KEYS;
            }

            uint256 index = _freeIndexOn(page, _random(seed, 2 + i), placedAt, placements);
            if (indexOf[k] != 0 || index == INDICES) break;

            placedKeys[placements] = k;
            placedAt[placements++] = index;
            k = (k + 1) % KEYS;
        }

        if (placements != 0) {
            _submit(new uint256[](0), 0, placedKeys, placedAt, placements, seed);
        }
    }

    /// Evicts one or two packed entries, leaving gaps that later entries may not fit.
    function evict(uint256 a, uint256 b) external {
        if (packed == 0) return;

        uint256[] memory evicted = new uint256[](2);
        evicted[0] = _packedKey(a);
        evicted[1] = _packedKey(b);
        uint256 evictions = evicted[0] == evicted[1] || packed == 1 ? 1 : 2;

        _submit(evicted, evictions, new uint256[](0), new uint256[](0), 0, a);
    }

    /// Swaps two packed entries. Entries of different sizes on different pages may not fit.
    function swap(uint256 a, uint256 b) external {
        if (packed < 2) return;

        uint256 first = _packedKey(a);
        uint256 second = _packedKey(b);
        if (first == second) return;

        uint256[] memory placedKeys = new uint256[](2);
        uint256[] memory placedAt = new uint256[](2);
        placedKeys[0] = first;
        placedAt[0] = indexOf[second] - 1;
        placedKeys[1] = second;
        placedAt[1] = indexOf[first] - 1;

        _submit(new uint256[](0), 0, placedKeys, placedAt, 2, a);
    }

    // ------------------------------------------------------------------------------------------
    // Model
    // ------------------------------------------------------------------------------------------

    function _submit(
        uint256[] memory evicted,
        uint256 evictions,
        uint256[] memory placedKeys,
        uint256[] memory placedAt,
        uint256 placements,
        uint256 seed
    ) internal {
        PagePack.Placement[] memory request = new PagePack.Placement[](evictions + placements);

        for (uint256 i; i < evictions; ++i) {
            request[i] =
                PagePack.Placement(keys[evicted[i]], _slots(evicted[i], seed, i), PagePack.HOME);
        }

        for (uint256 i; i < placements; ++i) {
            uint256 k = placedKeys[i];
            request[evictions + i] =
                PagePack.Placement(keys[k], _slots(k, seed, 50 + i), placedAt[i]);
        }

        bool valid = _isValid(evicted, evictions, placedKeys, placedAt, placements);

        try store.rebalance(request) {
            if (!valid) ++mismatches;
            ++accepted;

            _apply(evicted, evictions, placedKeys, placedAt, placements);
        } catch {
            if (valid) ++mismatches;
            ++rejected;
        }
    }

    /// The size a request names for key `k`: its own, or sometimes 0 for a one-slot key, which
    /// means the map's own size.
    function _slots(uint256 k, uint256 seed, uint256 salt) internal pure returns (uint256) {
        if (slotsOf(k) == 1 && _random(seed, 300 + salt) % 2 == 0) return 0;
        return slotsOf(k);
    }

    /// The rules from {PagePack.rebalance}, checked against the model rather than storage.
    function _isValid(
        uint256[] memory evicted,
        uint256 evictions,
        uint256[] memory placedKeys,
        uint256[] memory placedAt,
        uint256 placements
    ) internal view returns (bool) {
        bool[KEYS] memory named;
        bool[INDICES] memory claimed;

        for (uint256 i; i < evictions; ++i) {
            uint256 k = evicted[i];
            if (named[k] || indexOf[k] == 0) return false;

            named[k] = true;
        }

        for (uint256 i; i < placements; ++i) {
            uint256 k = placedKeys[i];
            uint256 index = placedAt[i];
            if (named[k] || index >= PagePack.MAX_INDEX) return false;
            if (index < INDICES && claimed[index]) return false;

            named[k] = true;
            if (index < INDICES) claimed[index] = true;
        }

        // Every target must be empty or held by an entry the request names.
        for (uint256 i; i < placements; ++i) {
            uint256 index = placedAt[i];
            if (index >= INDICES) continue;

            uint256 occupant = keyAt[index];
            if (occupant != 0 && !named[occupant - 1]) return false;
        }

        return _fits(evicted, evictions, placedKeys, placedAt, placements);
    }

    /// Whether every page's entries fit its data slots once the request applies.
    function _fits(
        uint256[] memory evicted,
        uint256 evictions,
        uint256[] memory placedKeys,
        uint256[] memory placedAt,
        uint256 placements
    ) internal view returns (bool) {
        uint256[KEYS] memory next = indexOf;

        for (uint256 i; i < evictions; ++i) {
            next[evicted[i]] = 0;
        }

        for (uint256 i; i < placements; ++i) {
            next[placedKeys[i]] = placedAt[i] + 1;
        }

        uint256[INDICES / PER_PAGE + 1] memory used;

        for (uint256 k; k < KEYS; ++k) {
            if (next[k] == 0) continue;

            uint256 page = (next[k] - 1) / PER_PAGE;
            used[page] += slotsOf(k);
            if (used[page] > DATA_SLOTS) return false;
        }

        return true;
    }

    function _apply(
        uint256[] memory evicted,
        uint256 evictions,
        uint256[] memory placedKeys,
        uint256[] memory placedAt,
        uint256 placements
    ) internal {
        // Vacate every named entry's old index before filling the new ones.
        for (uint256 i; i < evictions; ++i) {
            _vacate(evicted[i]);
        }

        for (uint256 i; i < placements; ++i) {
            _vacate(placedKeys[i]);
        }

        for (uint256 i; i < placements; ++i) {
            indexOf[placedKeys[i]] = placedAt[i] + 1;
            keyAt[placedAt[i]] = placedKeys[i] + 1;
            ++packed;
        }
    }

    function _vacate(uint256 k) internal {
        if (indexOf[k] == 0) return;

        keyAt[indexOf[k] - 1] = 0;
        indexOf[k] = 0;
        --packed;
    }

    /// A free index half the time, otherwise any index, and rarely one out of range.
    function _target(uint256 roll) internal view returns (uint256 index) {
        if (roll % 97 == 0) return PagePack.MAX_INDEX;

        index = (roll >> 8) % INDICES;
        if ((roll >> 16) % 2 == 0) return index;

        for (uint256 i; i < INDICES && keyAt[index] != 0; ++i) {
            index = (index + 1) % INDICES;
        }
    }

    /// A free index on `page` that the request doesn't already use, or INDICES if none is.
    function _freeIndexOn(uint256 page, uint256 rand, uint256[] memory used, uint256 count)
        internal
        view
        returns (uint256)
    {
        uint256 first = page * PER_PAGE;
        uint256 size = page == 0 ? PER_PAGE : INDICES - PER_PAGE;

        for (uint256 i; i < size; ++i) {
            uint256 index = first + (rand + i) % size;
            if (keyAt[index] != 0) continue;

            bool taken;
            for (uint256 j; j < count; ++j) {
                if (used[j] == index) taken = true;
            }

            if (!taken) return index;
        }

        return INDICES;
    }

    function _packedKey(uint256 seed) internal view returns (uint256 k) {
        k = seed % KEYS;

        while (indexOf[k] == 0) {
            k = (k + 1) % KEYS;
        }
    }

    function _random(uint256 seed, uint256 salt) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(seed, salt)));
    }
}

/// Runs once per kind of map: with home flags and HOME hints, and without.
abstract contract RebalanceInvariantTest is Test {
    EntryStore internal store;
    RebalanceHandler internal handler;

    function homeHints() internal pure virtual returns (bool);

    function setUp() public {
        store = new EntryStore(1, 0, homeHints());
        handler = new RebalanceHandler(store);

        assertEq(store.entriesPerPage(), handler.PER_PAGE());
        assertEq(store.dataSlotsPerPage(), handler.DATA_SLOTS());

        // The model assumes no two entries share a fingerprint, so any request it accepts is
        // valid.
        for (uint256 i; i < handler.KEYS(); ++i) {
            for (uint256 j; j < i; ++j) {
                assertTrue(_fingerprint(i) != _fingerprint(j));
            }
        }

        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = RebalanceHandler.write.selector;
        selectors[1] = RebalanceHandler.rebalance.selector;
        selectors[2] = RebalanceHandler.swap.selector;
        selectors[3] = RebalanceHandler.pack.selector;
        selectors[4] = RebalanceHandler.evict.selector;

        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    /// Rebalance succeeds exactly when the request describes a valid layout.
    function invariant_acceptsExactlyValidRequests() public view {
        assertEq(handler.mismatches(), 0);
    }

    /// Every entry holds its data and is found where the model says, by every kind of lookup.
    /// Maps without home flags never write one and ignore HOME hints.
    function invariant_entriesMatchModel() public view {
        assertEq(store.packedCount(), handler.packed());

        for (uint256 k; k < handler.KEYS(); ++k) {
            bytes32 key = handler.key(k);
            uint256 slots = handler.slotsOf(k);
            uint256 index = handler.indexOf(k);

            uint256 hint = index != 0 ? index : homeHints() ? PagePack.HOME : 0;
            if (hint != 0 && slots != 1) hint |= slots << 11;

            assertEq(store.hintOfSized(key, slots), hint, "hint");
            assertEq(_flag(k), index != 0 && homeHints() ? 1 : 0, "packed flag");

            for (uint256 w; w < slots; ++w) {
                uint256 expected = handler.valueOf(k, w);

                assertEq(store.get(key, slots, w, 0), expected, "no hint");
                assertEq(store.get(key, slots, w, hint), expected, "correct hint");
                assertEq(store.get(key, slots, w, PagePack.HOME), expected, "HOME hint");
            }
        }
    }

    /// Each packed page holds a tag for exactly the entries the model puts there, and their data
    /// lies after the tags without overlapping.
    function invariant_pagesHoldTheirEntries() public view {
        uint256 handle = uint256(PagedMap.unwrap(store.MAP()));
        uint256 dir = uint256(keccak256(abi.encode(handle & ~uint256(0xff00)))) & ~uint256(127);
        uint256 perPage = handler.PER_PAGE();
        uint256 used;

        for (uint256 index; index < handler.INDICES(); ++index) {
            if (index % perPage == 0) used = 0;

            uint256 start = dir + 128 * (index / perPage + 1);
            uint256 tag = uint256(vm.load(address(store), bytes32(start + index % perPage)));
            uint256 k = handler.keyAtIndex(index);

            if (k == 0) {
                assertEq(tag, 0, "tag of an empty index");
                continue;
            }

            uint256 slots = handler.slotsOf(k - 1);
            uint256 offset = (tag >> 7) & 127;
            uint256 range = ((1 << slots) - 1) << offset;

            assertEq(tag >> 14, _identity(k - 1) >> 14, "tag identity");
            assertEq(tag & 127, slots, "tag size");
            assertGe(offset, perPage, "data in the tag region");
            assertLe(offset + slots, 128, "data past the page");
            assertEq(used & range, 0, "overlapping data");

            used |= range;
        }
    }

    function _identity(uint256 k) internal view returns (uint256) {
        uint256 handle = uint256(PagedMap.unwrap(store.MAP())) & ~uint256(0xff00);
        handle |= handler.slotsOf(k) << 8;

        return uint256(keccak256(abi.encode(handle, handler.key(k))));
    }

    function _fingerprint(uint256 k) internal view returns (uint256) {
        return _identity(k) >> 234;
    }

    function _flag(uint256 k) internal view returns (uint256) {
        uint256 home = _identity(k) & ~uint256(127);
        return uint256(vm.load(address(store), bytes32(home + 127)));
    }
}

/// forge-config: default.invariant.runs = 32
/// forge-config: default.invariant.depth = 50
contract RebalanceInvariantDefaultTest is RebalanceInvariantTest {
    function homeHints() internal pure override returns (bool) {
        return false;
    }
}

/// forge-config: default.invariant.runs = 32
/// forge-config: default.invariant.depth = 50
contract RebalanceInvariantHomeHintsTest is RebalanceInvariantTest {
    function homeHints() internal pure override returns (bool) {
        return true;
    }
}
