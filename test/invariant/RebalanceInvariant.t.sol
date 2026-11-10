// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PagePack, PagedMap} from "pagepack/PagePack.sol";
import {EntryReader, KindedEntryStore, PlainEntryStore} from "../utils/EntryStore.sol";

/// A map's shape and the part of it a handler drives.
struct Geometry {
    // Tags per page, or 0 for the map's default.
    uint256 perPage;
    bool homeHints;
    // The sizes of the map's kinds. Keys take turns being each kind. One size makes a map of
    // one kind, whose keys are any 32 bytes.
    uint256[] sizes;
    uint256 keys;
    // The packed indices the handler uses: `indices` of them from `first`.
    uint256 first;
    uint256 indices;
}

/// Drives a store with random writes, rebalances and swaps, keeping a model of where every entry
/// should be and what it should hold. Keys take turns among several kinds, so pages mix sizes
/// and rebalancing has to find, and sometimes make, room. Rebalance requests are mostly valid,
/// with some deliberately broken ones; the model decides independently which should succeed.
contract RebalanceHandler is Test {
    uint256 public constant MAX_KEYS = 64;

    EntryReader public immutable store;

    uint256 public immutable PER_PAGE;
    uint256 public immutable DATA_SLOTS;
    uint256 public immutable KEYS;
    uint256 public immutable FIRST;
    uint256 public immutable INDICES;

    uint256[] internal sizes;
    bytes32[MAX_KEYS] internal keys;

    // The model: each key's packed index plus one (0 at home), the reverse, and the data.
    uint256[MAX_KEYS] public indexOf;
    mapping(uint256 index => uint256 key) internal keyAt;
    mapping(uint256 key => mapping(uint256 offset => uint256)) internal values;

    // Hints taken earlier, which later rebalances may have made stale.
    uint256[MAX_KEYS] public savedHint;
    bool[MAX_KEYS] public saved;

    uint256 public packed;
    uint256 public accepted;
    uint256 public rejected;
    uint256 public mismatches;

    constructor(EntryReader store_, Geometry memory geometry) {
        store = store_;
        PER_PAGE = store_.entriesPerPage();
        DATA_SLOTS = store_.dataSlotsPerPage();
        KEYS = geometry.keys;
        FIRST = geometry.first;
        INDICES = geometry.indices;
        sizes = geometry.sizes;

        for (uint256 i; i < KEYS; ++i) {
            // In a map of kinds, the kind in the top byte over 31 bytes of a hash. In a map of
            // one kind, the whole hash, whatever its top byte.
            bytes32 hash = keccak256(abi.encode("invariant", i));
            keys[i] = sizes.length == 1 ? hash : PagePack.hashedKindKey(i % sizes.length, hash);
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

    /// Keys take turns being each size.
    function slotsOf(uint256 k) public view returns (uint256) {
        return sizes[k % sizes.length];
    }

    /// The first page the handler uses, and how many.
    function pages() public view returns (uint256 firstPage, uint256 count) {
        firstPage = FIRST / PER_PAGE;
        count = (FIRST + INDICES - 1) / PER_PAGE - firstPage + 1;
    }

    // ------------------------------------------------------------------------------------------
    // Actions
    // ------------------------------------------------------------------------------------------

    /// Writes a data slot, zero a quarter of the time so rebalances also move empty slots.
    function write(uint256 k, uint256 w, uint256 value) external {
        k %= KEYS;
        w %= slotsOf(k);
        if (value % 4 == 0) value = 0;

        store.set(keys[k], w, value);
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
        (uint256 firstPage, uint256 pageCount) = pages();
        uint256 page = firstPage + _random(seed, 0) % pageCount;
        uint256 count = 1 + seed % 6;
        uint256 k = _random(seed, 1) % KEYS;

        uint256[] memory placedKeys = new uint256[](count);
        uint256[] memory placedAt = new uint256[](count);
        uint256 placements;

        for (uint256 i; i < count; ++i) {
            k = _homeKey(k, placedKeys, placements);
            if (k == KEYS) break;

            uint256 index = _freeIndexOn(page, _random(seed, 2 + i), placedAt, placements);
            if (index == type(uint256).max) break;

            placedKeys[placements] = k;
            placedAt[placements++] = index;
            k = (k + 1) % KEYS;
        }

        if (placements != 0) {
            _submit(new uint256[](0), 0, placedKeys, placedAt, placements, seed);
        }
    }

    /// On each of two or three pages, evicts every other entry narrower than the widest size,
    /// then fills the page with the widest entries at home, all in one request. The evictions
    /// leave gaps too small for the arrivals, so one call often has to make room on several
    /// pages.
    function packPages(uint256 seed) external {
        (uint256 firstPage, uint256 count) = pages();
        if (count < 2) return;

        uint256 n = count == 2 ? 2 : 2 + seed % 2;
        uint256 start = _random(seed, 0) % count;

        uint256[] memory evicted = new uint256[](KEYS);
        uint256[] memory placedKeys = new uint256[](KEYS);
        uint256[] memory placedAt = new uint256[](KEYS);
        uint256 evictions;
        uint256 placements;

        for (uint256 i; i < n; ++i) {
            uint256 page = firstPage + (start + i) % count;
            evictions = _thin(page, evicted, evictions);
            uint256 used = _usedOn(page, evicted, evictions);

            while (true) {
                uint256 k = _widestHomeKey(_random(seed, 20 + placements), placedKeys, placements);
                if (k == KEYS || used + slotsOf(k) > DATA_SLOTS) break;

                uint256 rand = _random(seed, 30 + placements);
                uint256 index = _freeIndexOn(page, rand, placedAt, placements);
                if (index == type(uint256).max) break;

                placedKeys[placements] = k;
                placedAt[placements++] = index;
                used += slotsOf(k);
            }
        }

        if (evictions + placements != 0) {
            _submit(evicted, evictions, placedKeys, placedAt, placements, seed);
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

    /// Takes a key's current hint and keeps it while later rebalances make it stale.
    function remember(uint256 k) external {
        k %= KEYS;
        savedHint[k] = store.hintOf(keys[k]);
        saved[k] = true;
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
            request[i] = PagePack.Placement(keys[evicted[i]], PagePack.HOME);
        }

        for (uint256 i; i < placements; ++i) {
            request[evictions + i] = PagePack.Placement(keys[placedKeys[i]], placedAt[i]);
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

    /// The rules from {PagePack.rebalance}, checked against the model rather than storage.
    function _isValid(
        uint256[] memory evicted,
        uint256 evictions,
        uint256[] memory placedKeys,
        uint256[] memory placedAt,
        uint256 placements
    ) internal view returns (bool) {
        bool[MAX_KEYS] memory named;
        bool[] memory claimed = new bool[](INDICES);

        for (uint256 i; i < evictions; ++i) {
            uint256 k = evicted[i];
            if (named[k] || indexOf[k] == 0) return false;

            named[k] = true;
        }

        for (uint256 i; i < placements; ++i) {
            uint256 k = placedKeys[i];
            uint256 index = placedAt[i];
            if (named[k] || index >= PagePack.MAX_INDEX) return false;
            if (_inRange(index) && claimed[index - FIRST]) return false;

            named[k] = true;
            if (_inRange(index)) claimed[index - FIRST] = true;
        }

        // Every target must be empty or held by an entry the request names.
        for (uint256 i; i < placements; ++i) {
            uint256 occupant = keyAt[placedAt[i]];
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
        uint256[MAX_KEYS] memory next = indexOf;

        for (uint256 i; i < evictions; ++i) {
            next[evicted[i]] = 0;
        }

        for (uint256 i; i < placements; ++i) {
            next[placedKeys[i]] = placedAt[i] + 1;
        }

        (uint256 firstPage, uint256 count) = pages();
        uint256[] memory used = new uint256[](count);

        for (uint256 k; k < KEYS; ++k) {
            if (next[k] == 0) continue;

            uint256 page = (next[k] - 1) / PER_PAGE - firstPage;
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

    function _inRange(uint256 index) internal view returns (bool) {
        return index >= FIRST && index < FIRST + INDICES;
    }

    /// A free index half the time, otherwise any index in range, and rarely one out of range.
    function _target(uint256 roll) internal view returns (uint256) {
        if (roll % 97 == 0) return PagePack.MAX_INDEX;

        uint256 offset = (roll >> 8) % INDICES;
        if ((roll >> 16) % 2 == 0) return FIRST + offset;

        for (uint256 i; i < INDICES && keyAt[FIRST + offset] != 0; ++i) {
            offset = (offset + 1) % INDICES;
        }

        return FIRST + offset;
    }

    /// Adds every other entry on `page` narrower than the widest size to `evicted`.
    function _thin(uint256 page, uint256[] memory evicted, uint256 evictions)
        internal
        view
        returns (uint256)
    {
        uint256 widest = _widest();
        uint256 end = _min((page + 1) * PER_PAGE, FIRST + INDICES);
        bool take;

        for (uint256 index = _max(page * PER_PAGE, FIRST); index < end; ++index) {
            uint256 occupant = keyAt[index];
            if (occupant == 0 || slotsOf(occupant - 1) == widest) continue;

            take = !take;
            if (take) evicted[evictions++] = occupant - 1;
        }

        return evictions;
    }

    /// Data slots taken on `page` by the entries the model has there, less those in `evicted`.
    function _usedOn(uint256 page, uint256[] memory evicted, uint256 evictions)
        internal
        view
        returns (uint256 used)
    {
        uint256 end = _min((page + 1) * PER_PAGE, FIRST + INDICES);

        for (uint256 index = _max(page * PER_PAGE, FIRST); index < end; ++index) {
            uint256 occupant = keyAt[index];
            if (occupant != 0 && !_contains(evicted, evictions, occupant - 1)) {
                used += slotsOf(occupant - 1);
            }
        }
    }

    /// The widest key at home and not yet in the request, searching from `from`, or KEYS if
    /// none is.
    function _widestHomeKey(uint256 from, uint256[] memory listed, uint256 count)
        internal
        view
        returns (uint256 best)
    {
        best = KEYS;

        for (uint256 i; i < KEYS; ++i) {
            uint256 k = (from + i) % KEYS;
            if (indexOf[k] != 0 || _contains(listed, count, k)) continue;
            if (best == KEYS || slotsOf(k) > slotsOf(best)) best = k;
        }
    }

    function _widest() internal view returns (uint256 widest) {
        for (uint256 i; i < sizes.length; ++i) {
            if (sizes[i] > widest) widest = sizes[i];
        }
    }

    /// The first key from `k` that is at home and not yet in the request, or KEYS if none is.
    function _homeKey(uint256 k, uint256[] memory listed, uint256 count)
        internal
        view
        returns (uint256)
    {
        for (uint256 tries; tries < KEYS; ++tries) {
            if (indexOf[k] == 0 && !_contains(listed, count, k)) return k;
            k = (k + 1) % KEYS;
        }

        return KEYS;
    }

    /// A free index in range on `page` that the request doesn't already use, or the largest
    /// uint256 if none is.
    function _freeIndexOn(uint256 page, uint256 rand, uint256[] memory used, uint256 count)
        internal
        view
        returns (uint256)
    {
        uint256 first = _max(page * PER_PAGE, FIRST);
        uint256 size = _min((page + 1) * PER_PAGE, FIRST + INDICES) - first;

        for (uint256 i; i < size; ++i) {
            uint256 index = first + (rand + i) % size;
            if (keyAt[index] == 0 && !_contains(used, count, index)) return index;
        }

        return type(uint256).max;
    }

    function _contains(uint256[] memory list, uint256 count, uint256 value)
        internal
        pure
        returns (bool)
    {
        for (uint256 i; i < count; ++i) {
            if (list[i] == value) return true;
        }

        return false;
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

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function _max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }
}

/// Runs once per geometry: page shapes, entry sizes, index ranges and both kinds of map.
abstract contract RebalanceInvariantTest is Test {
    EntryReader internal store;
    RebalanceHandler internal handler;
    Geometry internal geometry;

    function _geometry() internal pure virtual returns (Geometry memory);

    function setUp() public {
        geometry = _geometry();
        store = geometry.sizes.length == 1
            ? EntryReader(
                new PlainEntryStore(geometry.sizes[0], geometry.perPage, geometry.homeHints)
            )
            : EntryReader(
                new KindedEntryStore(geometry.sizes, geometry.perPage, geometry.homeHints)
            );
        handler = new RebalanceHandler(store, geometry);

        if (geometry.perPage != 0) assertEq(store.entriesPerPage(), geometry.perPage);
        assertEq(handler.DATA_SLOTS(), 128 - handler.PER_PAGE());
        assertLe(geometry.keys, handler.MAX_KEYS());
        assertLe(geometry.first + geometry.indices, PagePack.MAX_INDEX);

        // The model assumes no two entries share a fingerprint, so any request it accepts is
        // valid.
        for (uint256 i; i < handler.KEYS(); ++i) {
            for (uint256 j; j < i; ++j) {
                assertTrue(_fingerprint(i) != _fingerprint(j));
            }
        }

        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = RebalanceHandler.write.selector;
        selectors[1] = RebalanceHandler.rebalance.selector;
        selectors[2] = RebalanceHandler.swap.selector;
        selectors[3] = RebalanceHandler.pack.selector;
        selectors[4] = RebalanceHandler.packPages.selector;
        selectors[5] = RebalanceHandler.evict.selector;
        selectors[6] = RebalanceHandler.remember.selector;

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
            uint256 index = handler.indexOf(k);

            uint256 hint = index != 0 ? index : geometry.homeHints ? PagePack.HOME : 0;

            assertEq(store.hintOf(key), hint, "hint");
            assertEq(store.sizeOf(key), handler.slotsOf(k), "size");
            assertEq(_flag(k), index != 0 && geometry.homeHints ? 1 : 0, "packed flag");

            _assertHolds(k, store.readAll(key, 0), "no hint");
            _assertHolds(k, store.readAll(key, hint), "correct hint");
            _assertHolds(k, store.readAll(key, PagePack.HOME), "HOME hint");
        }
    }

    /// Hints taken before later rebalances still find their entries, passed to a lookup or
    /// loaded with {PagePack.useHints}: a stale hint costs a search, never a wrong entry.
    function invariant_savedHintsFindTheirEntries() public {
        // Each saved hint as {PagePack.useHints} takes it: 5 bytes, the key's fingerprint above
        // the hint.
        bytes memory hints;

        for (uint256 k; k < handler.KEYS(); ++k) {
            if (!handler.saved(k)) continue;

            uint256 packed = (store.fingerprintOf(handler.key(k)) << 11) | handler.savedHint(k);
            hints = bytes.concat(hints, bytes5(uint40(packed)));
        }

        for (uint256 k; k < handler.KEYS(); ++k) {
            if (!handler.saved(k)) continue;

            bytes32 key = handler.key(k);

            _assertHolds(k, store.readAll(key, handler.savedHint(k)), "saved hint");
            _assertHolds(k, store.readAllWithHints(hints, key), "saved hints loaded");
        }
    }

    /// Each packed page holds a tag for exactly the entries the model puts there, and their data
    /// lies after the tags without overlapping.
    function invariant_pagesHoldTheirEntries() public view {
        uint256 dir = uint256(keccak256(abi.encode(store.MAP()))) & ~uint256(127);
        uint256 perPage = handler.PER_PAGE();
        uint256 first = handler.FIRST();
        uint256 used;

        for (uint256 index = first; index < first + handler.INDICES(); ++index) {
            if (index == first || index % perPage == 0) used = 0;

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

    function _assertHolds(uint256 k, uint256[] memory data, string memory lookup) internal view {
        for (uint256 w; w < data.length; ++w) {
            assertEq(data[w], handler.valueOf(k, w), lookup);
        }
    }

    function _identity(uint256 k) internal view returns (uint256) {
        return uint256(keccak256(abi.encode(store.MAP(), handler.key(k))));
    }

    function _fingerprint(uint256 k) internal view returns (uint256) {
        return _identity(k) >> 234;
    }

    function _flag(uint256 k) internal view returns (uint256) {
        uint256 home = _identity(k) & ~uint256(127);
        return uint256(vm.load(address(store), bytes32(home + 127)));
    }

    function _sizes(uint256 a) internal pure returns (uint256[] memory list) {
        list = new uint256[](1);
        list[0] = a;
    }

    function _sizes(uint256 a, uint256 b) internal pure returns (uint256[] memory list) {
        list = new uint256[](2);
        (list[0], list[1]) = (a, b);
    }

    function _sizes(uint256 a, uint256 b, uint256 c, uint256 d)
        internal
        pure
        returns (uint256[] memory list)
    {
        list = new uint256[](4);
        (list[0], list[1], list[2], list[3]) = (a, b, c, d);
    }
}

/// A one-slot map: 64 tags and 64 data slots per page, entries of one to four slots. 100
/// indices spread over two packed pages and up to five directory words. Entries average 2.5
/// slots, so a page fills before its tags run out.
/// forge-config: default.invariant.runs = 32
/// forge-config: default.invariant.depth = 50
contract RebalanceInvariantDefaultTest is RebalanceInvariantTest {
    function _geometry() internal pure override returns (Geometry memory) {
        return Geometry(64, false, _sizes(1, 2, 3, 4), 64, 0, 100);
    }
}

/// The same, keeping home flags for HOME hints.
/// forge-config: default.invariant.runs = 32
/// forge-config: default.invariant.depth = 50
contract RebalanceInvariantHomeHintsTest is RebalanceInvariantTest {
    function _geometry() internal pure override returns (Geometry memory) {
        return Geometry(64, true, _sizes(1, 2, 3, 4), 64, 0, 100);
    }
}

/// One tag per page: every entry has a page to itself, up to the widest entry a page holds.
/// forge-config: default.invariant.runs = 32
/// forge-config: default.invariant.depth = 50
contract RebalanceInvariantOneTagTest is RebalanceInvariantTest {
    function _geometry() internal pure override returns (Geometry memory) {
        return Geometry(1, false, _sizes(1, 50, 2, 127), 32, 0, 40);
    }
}

/// Three tags per page and wide entries, so three of them rarely fit 125 data slots.
/// forge-config: default.invariant.runs = 32
/// forge-config: default.invariant.depth = 50
contract RebalanceInvariantThreeTagsTest is RebalanceInvariantTest {
    function _geometry() internal pure override returns (Geometry memory) {
        return Geometry(3, true, _sizes(1, 20, 41, 62), 32, 0, 24);
    }
}

/// The two-slot default of 42 tags, set by hand on a one-slot map of up to four slots: 86 data
/// slots for entries averaging 2.5.
/// forge-config: default.invariant.runs = 32
/// forge-config: default.invariant.depth = 50
contract RebalanceInvariantFortyTwoTagsTest is RebalanceInvariantTest {
    function _geometry() internal pure override returns (Geometry memory) {
        return Geometry(42, true, _sizes(1, 2, 3, 4), 64, 0, 100);
    }
}

/// Accounts and approvals: kinds of one and two slots, with the entries per page a map of those
/// kinds has by default, 50, and 78 data slots.
/// forge-config: default.invariant.runs = 32
/// forge-config: default.invariant.depth = 50
contract RebalanceInvariantFiftyTagsTest is RebalanceInvariantTest {
    function _geometry() internal pure override returns (Geometry memory) {
        return Geometry(0, false, _sizes(1, 2), 64, 0, 150);
    }

    function test_usesTheDefaultEntriesPerPage() public view {
        assertEq(store.entriesPerPage(), 50);
    }
}

/// A map of one kind made with `map`, three slots wide, with its default 32 entries per page.
/// Its keys are whole hashes, so their top bytes are arbitrary and mean nothing.
/// forge-config: default.invariant.runs = 32
/// forge-config: default.invariant.depth = 50
contract RebalanceInvariantOneKindTest is RebalanceInvariantTest {
    function _geometry() internal pure override returns (Geometry memory) {
        return Geometry(0, true, _sizes(3), 64, 0, 100);
    }

    function test_usesTheDefaultEntriesPerPage() public view {
        assertEq(store.entriesPerPage(), 32);
    }
}

/// Wide entries at the last indices a map has, 1,000 to 1,023, on its last three pages.
/// forge-config: default.invariant.runs = 32
/// forge-config: default.invariant.depth = 50
contract RebalanceInvariantHighIndicesTest is RebalanceInvariantTest {
    function _geometry() internal pure override returns (Geometry memory) {
        return Geometry(8, true, _sizes(8, 16, 30, 40), 32, 1000, 24);
    }
}
