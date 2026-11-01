// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PagePack} from "pagepack/PagePack.sol";
import {RecordStore} from "../utils/RecordStore.sol";

/// Drives a store with random writes, rebalances and swaps, keeping a model of where every record
/// should be and what it should hold. Rebalance requests are mostly valid, with some deliberately
/// broken ones; the model decides independently which should succeed.
contract RebalanceHandler is Test {
    uint256 public constant KEYS = 40;
    uint256 public constant WORDS = 2;

    // Spread over three packed pages and up to five directory words.
    uint256 public constant INDICES = 100;

    RecordStore public immutable store;
    bytes32[KEYS] internal keys;

    // The model: each key's packed index plus one (0 at home), the reverse, and the data.
    uint256[KEYS] public indexOf;
    uint256[INDICES] internal keyAt;
    uint256[WORDS][KEYS] internal values;

    uint256 public packed;
    uint256 public accepted;
    uint256 public rejected;
    uint256 public mismatches;

    constructor(RecordStore store_) {
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

    // ------------------------------------------------------------------------------------------
    // Actions
    // ------------------------------------------------------------------------------------------

    /// Writes a word, zero a quarter of the time so rebalances also move empty words.
    function write(uint256 k, uint256 w, uint256 value) external {
        k %= KEYS;
        w %= WORDS;
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
                // Occasionally evicts a record that isn't packed.
                evicted[evictions++] = k;
            } else {
                placedKeys[placements] = k;
                placedAt[placements++] = _target(roll);
            }
        }

        _submit(evicted, evictions, placedKeys, placedAt, placements);
    }

    /// Swaps two packed records, which is always valid.
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

        _submit(new uint256[](0), 0, placedKeys, placedAt, 2);
    }

    // ------------------------------------------------------------------------------------------
    // Model
    // ------------------------------------------------------------------------------------------

    function _submit(
        uint256[] memory evicted,
        uint256 evictions,
        uint256[] memory placedKeys,
        uint256[] memory placedAt,
        uint256 placements
    ) internal {
        bytes32[] memory evictionKeys = new bytes32[](evictions);
        PagePack.Placement[] memory request = new PagePack.Placement[](placements);

        for (uint256 i; i < evictions; ++i) {
            evictionKeys[i] = keys[evicted[i]];
        }

        for (uint256 i; i < placements; ++i) {
            request[i] = PagePack.Placement(keys[placedKeys[i]], placedAt[i]);
        }

        bool valid = _isValid(evicted, evictions, placedKeys, placedAt, placements);

        try store.rebalance(evictionKeys, request) {
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

        // Every target must be empty or held by a record the request names.
        for (uint256 i; i < placements; ++i) {
            uint256 index = placedAt[i];
            if (index >= INDICES) continue;

            uint256 occupant = keyAt[index];
            if (occupant != 0 && !named[occupant - 1]) return false;
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
        // Vacate every named record's old index before filling the new ones.
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

/// Runs once per kind of space: with home flags and HOME hints, and without.
abstract contract RebalanceInvariantTest is Test {
    RecordStore internal store;
    RebalanceHandler internal handler;

    function homeHints() internal pure virtual returns (bool);

    function setUp() public {
        store = new RecordStore(2, homeHints());
        handler = new RebalanceHandler(store);

        // The model assumes no two keys share a fingerprint, so any request it accepts is valid.
        for (uint256 i; i < handler.KEYS(); ++i) {
            for (uint256 j; j < i; ++j) {
                assertTrue(
                    store.fingerprintOf(handler.key(i)) != store.fingerprintOf(handler.key(j))
                );
            }
        }

        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = RebalanceHandler.write.selector;
        selectors[1] = RebalanceHandler.rebalance.selector;
        selectors[2] = RebalanceHandler.swap.selector;

        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    /// Rebalance succeeds exactly when the request describes a valid layout.
    function invariant_acceptsExactlyValidRequests() public view {
        assertEq(handler.mismatches(), 0);
    }

    /// Every record holds its data and is found where the model says, by every kind of lookup.
    /// Spaces without home flags never write one and ignore HOME hints.
    function invariant_recordsMatchModel() public view {
        assertEq(store.packedCount(), handler.packed());

        for (uint256 k; k < handler.KEYS(); ++k) {
            bytes32 key = handler.key(k);
            uint256 index = handler.indexOf(k);
            uint256 hint = index != 0 ? index : homeHints() ? PagePack.HOME : 0;

            assertEq(store.hintOf(key), hint, "hint");
            assertEq(_flag(key), index != 0 && homeHints() ? 1 : 0, "packed flag");

            for (uint256 w; w < handler.WORDS(); ++w) {
                uint256 expected = handler.valueOf(k, w);

                assertEq(store.get(key, w), expected, "no hint");
                assertEq(store.get(key, w, hint), expected, "correct hint");
                assertEq(store.get(key, w, PagePack.HOME), expected, "HOME hint");
            }
        }
    }

    function _flag(bytes32 key) internal view returns (uint256) {
        uint256 home = uint256(keccak256(abi.encode(store.SPACE(), key))) & ~uint256(127);
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
