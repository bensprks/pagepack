// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// A family of fixed-width records, such as "balances" or "allowances".
///
/// Records can only share a page with records in the same space, so put entities that are used
/// together into one space. The low byte holds the record width in words.
type Space is bytes32;

/// The first data word of a record, wherever the record currently lives.
type Record is uint256;

using PagePack for Space global;
using PagePack for Record global;

/// @title PagePack
/// @notice Packs storage records that are used together onto shared MIP-8 pages.
///
/// MIP-8 prices storage by 128-slot page: the first touch of a page in a transaction costs
/// 8,100 gas and every later slot on it costs 100. A mapping puts each entry on its own page, so
/// touching N entries costs N page loads. PagePack lets an admin move hot records onto shared
/// pages, so a transaction touching N packed records on k pages pays for k loads instead.
///
/// A record lives in one of two places:
///
///   home     keccak256(space, key), rounded down to a page boundary. Every record starts here,
///            and it costs the same as a mapping entry.
///   packed   a numbered slot in the space's packed region, placed there by {rebalance}. Each
///            packed record is an identity word followed by its data, so a lookup can confirm it
///            found the right record.
///
/// Each space keeps one directory page mapping a short fingerprint of every packed record to its
/// index. A lookup without a hint searches the directory, paying for that page once per
/// transaction. A lookup with a correct hint skips the directory entirely.
///
/// Storage layout of a space, all page-aligned:
///
///   D = keccak256(space) rounded down to a page boundary
///   D + 0              number of packed records
///   D + 1 .. D + 127   directory entries, 8 per slot, sorted by fingerprint
///   D + 128 ...        packed pages, floor(128 / (width + 1)) records each
library PagePack {
    struct Placement {
        bytes32 key;
        uint256 index;
    }

    error InvalidWidth(uint256 width);
    error IndexOutOfRange(uint256 index);
    error IndexTaken(uint256 index);
    error NotPacked(bytes32 key);
    error FingerprintCollision(uint256 fingerprint);
    error DirectoryFull();

    uint256 internal constant PAGE_SIZE = 128;
    uint256 internal constant MAX_WIDTH = 127;

    /// Directory slots after the header, times 8 entries per slot.
    uint256 internal constant MAX_PACKED = 127 * 8;

    /// Packed indices are stored in 10 bits.
    uint256 internal constant MAX_INDEX = 1 << 10;

    // A directory entry is 32 bits: a 22-bit fingerprint above a 10-bit packed index. Sorting
    // entries numerically therefore sorts them by fingerprint. These are plain literals so that
    // inline assembly can use them.
    uint256 private constant INDEX_BITS = 10;
    uint256 private constant INDEX_MASK = 0x3ff;
    uint256 private constant FINGERPRINT_SHIFT = 234;
    uint256 private constant ENTRY_BITS = 32;
    uint256 private constant ENTRY_MASK = 0xffffffff;
    uint256 private constant ENTRIES_PER_SLOT = 8;

    // Directory search rounds that interpolate before falling back to bisection.
    uint256 private constant INTERPOLATION_ROUNDS = 4;

    // Marks a directory entry as moved or evicted while a rebalance is in progress.
    uint256 private constant REMOVED = 1 << 255;

    // ------------------------------------------------------------------------------------------
    // Spaces
    // ------------------------------------------------------------------------------------------

    /// @notice Creates a space of records that are `words` words wide.
    /// @dev Intended for an immutable: `Space immutable BALANCES = PagePack.space("x", 1);`
    function space(string memory name, uint256 words) internal pure returns (Space) {
        if (words == 0 || words > MAX_WIDTH) revert InvalidWidth(words);

        return Space.wrap((keccak256(bytes(name)) & ~bytes32(uint256(0xff))) | bytes32(words));
    }

    /// @notice Number of data words in each record.
    function width(Space s) internal pure returns (uint256) {
        return uint256(Space.unwrap(s)) & 0xff;
    }

    /// @notice Number of packed records that fit on one page.
    function recordsPerPage(Space s) internal pure returns (uint256) {
        return PAGE_SIZE / (s.width() + 1);
    }

    /// @notice Number of records currently packed.
    function packedCount(Space s) internal view returns (uint256) {
        return _load(_directory(s));
    }

    // ------------------------------------------------------------------------------------------
    // Lookup
    // ------------------------------------------------------------------------------------------

    // Lookups run on every record access, so their arithmetic is unchecked. Widths are at most
    // 127, indices below 1024 and slots come from hashes, so none of it can overflow in practice.

    /// @notice Locates the record for `key`.
    function find(Space s, bytes32 key) internal view returns (Record) {
        unchecked {
            uint256 id = _identity(s, key);
            uint256 dir = _directory(s);

            (bool found, uint256 index) = _search(dir, id);

            if (found) {
                uint256 location = _packedSlot(dir, s.width() + 1, index);

                // Fingerprints are short, so a match is only a candidate until the identity
                // agrees.
                if (_load(location) == id) return Record.wrap(location + 1);
            }

            return Record.wrap(_home(id));
        }
    }

    /// @notice Locates the record for `key`, checking `hint` before the directory.
    /// @dev A hint is the value returned by {hintOf}; 0 means no hint. A wrong or stale hint
    ///      falls back to the directory, so it can cost gas but never returns the wrong record.
    function find(Space s, bytes32 key, uint256 hint) internal view returns (Record) {
        unchecked {
            // hint - 1 wraps to a huge number when hint is 0, so one comparison rejects both
            // "no hint" and out-of-range hints.
            if (hint - 1 < MAX_INDEX) {
                uint256 location = _packedSlot(_directory(s), s.width() + 1, hint - 1);

                if (_load(location) == _identity(s, key)) return Record.wrap(location + 1);
            }

            return find(s, key);
        }
    }

    /// @notice The hint for `key`: its packed index plus one, or 0 if it is not packed.
    /// @dev Meant to be called off-chain (via an eth_call wrapper) to build hints for a batch.
    function hintOf(Space s, bytes32 key) internal view returns (uint256) {
        uint256 id = _identity(s, key);
        uint256 dir = _directory(s);

        (bool found, uint256 index) = _search(dir, id);

        if (found && _load(_packedSlot(dir, s.width() + 1, index)) == id) return index + 1;

        return 0;
    }

    // ------------------------------------------------------------------------------------------
    // Records
    // ------------------------------------------------------------------------------------------

    function read(Record r, uint256 offset) internal view returns (uint256 value) {
        assembly ("memory-safe") {
            value := sload(add(r, offset))
        }
    }

    function write(Record r, uint256 offset, uint256 value) internal {
        assembly ("memory-safe") {
            sstore(add(r, offset), value)
        }
    }

    /// @notice The storage slot of the record's first data word.
    function slot(Record r) internal pure returns (uint256) {
        return Record.unwrap(r);
    }

    // ------------------------------------------------------------------------------------------
    // Rebalancing
    // ------------------------------------------------------------------------------------------

    /// @notice Moves records between their homes and packed slots, then rewrites the directory.
    /// @dev Applies every eviction first, then each placement in order. A placement's target slot
    ///      must be empty when it is reached, so move a record out of a slot before moving another
    ///      in. Placing a record at the index it already occupies does nothing, so a caller can
    ///      resubmit a whole layout. There is no access control here: the calling contract
    ///      decides who may rebalance.
    function rebalance(Space s, bytes32[] memory evictions, Placement[] memory placements)
        internal
    {
        uint256 dir = _directory(s);
        uint256 stride = s.width() + 1;

        uint256[] memory entries = _loadEntries(dir);
        uint256[] memory added = new uint256[](placements.length);
        uint256 addedCount;

        for (uint256 i; i < evictions.length; ++i) {
            uint256 id = _identity(s, evictions[i]);
            (uint256 from, uint256 position) = _locatePacked(entries, dir, stride, id);

            if (from == 0) revert NotPacked(evictions[i]);

            _move(from + 1, _home(id), stride - 1);
            _store(from, 0);
            entries[position] |= REMOVED;
        }

        for (uint256 i; i < placements.length; ++i) {
            Placement memory p = placements[i];
            if (p.index >= MAX_INDEX) revert IndexOutOfRange(p.index);

            uint256 id = _identity(s, p.key);
            uint256 to = _packedSlot(dir, stride, p.index);

            uint256 occupant = _load(to);
            if (occupant == id) continue;
            if (occupant != 0) revert IndexTaken(p.index);

            (uint256 from, uint256 position) = _locatePacked(entries, dir, stride, id);

            if (from != 0) {
                _move(from + 1, to + 1, stride - 1);
                _store(from, 0);
                entries[position] |= REMOVED;
            } else {
                _move(_home(id), to + 1, stride - 1);
            }

            _store(to, id);
            added[addedCount++] = ((id >> FINGERPRINT_SHIFT) << INDEX_BITS) | p.index;
        }

        uint256 oldCount = entries.length;
        _writeEntries(dir, oldCount, _merge(entries, added, addedCount));
    }

    // ------------------------------------------------------------------------------------------
    // Layout
    // ------------------------------------------------------------------------------------------

    /// Identifies a record in packed storage and derives its home and fingerprint. Hashing the
    /// space in means the same key in two spaces never collides, and the result is never zero in
    /// practice, so zero can mark an empty packed slot.
    function _identity(Space s, bytes32 key) private pure returns (uint256 id) {
        assembly ("memory-safe") {
            mstore(0x00, s)
            mstore(0x20, key)
            id := keccak256(0x00, 0x40)
        }
    }

    function _directory(Space s) private pure returns (uint256 dir) {
        assembly ("memory-safe") {
            mstore(0x00, s)
            dir := and(keccak256(0x00, 0x20), not(127))
        }
    }

    /// Page-aligned, so a record of up to 128 words never straddles two pages.
    function _home(uint256 id) private pure returns (uint256) {
        return id & ~(PAGE_SIZE - 1);
    }

    /// Records never straddle pages: each page holds floor(128 / stride) whole records and the
    /// remainder is left unused.
    ///
    /// Runs on every packed lookup. stride is 2..128 and index < 1024, so nothing can overflow
    /// or divide by zero, and skipping Solidity's checks here saves a few hundred gas per call.
    function _packedSlot(uint256 dir, uint256 stride, uint256 index)
        private
        pure
        returns (uint256 location)
    {
        assembly ("memory-safe") {
            let perPage := div(PAGE_SIZE, stride)
            let page := add(1, div(index, perPage))

            location := add(add(dir, shl(7, page)), mul(mod(index, perPage), stride))
        }
    }

    // ------------------------------------------------------------------------------------------
    // Directory
    // ------------------------------------------------------------------------------------------

    /// Searches the sorted storage directory. The header and entries share a page, so only the
    /// first read pays for a page load; each further probe is a 100 gas read.
    ///
    /// Fingerprints are hash bits, so they are spread evenly and interpolation finds most entries
    /// in two or three probes, against ~10 for bisection over a full directory. A skewed set of
    /// fingerprints (e.g. ground by an attacker hoping to be packed) can defeat interpolation, so
    /// after a few rounds the search falls back to bisection and stays O(log n).
    ///
    /// This is the hot path for every lookup without a hint, hence the assembly: in checked
    /// Solidity the arithmetic cost several times the storage reads.
    function _search(uint256 dir, uint256 id) private view returns (bool found, uint256 index) {
        assembly ("memory-safe") {
            let fingerprint := shr(FINGERPRINT_SHIFT, id)
            let low := 0
            let high := sload(dir)

            // Every fingerprint at positions [low, high) lies in [lowFp, highFp).
            let lowFp := 0
            let highFp := shl(22, 1)

            for { let round := 0 } lt(low, high) { round := add(round, 1) } {
                let mid

                // fingerprint is in [lowFp, highFp), so the interpolated mid is in [low, high).
                switch lt(round, INTERPOLATION_ROUNDS)
                case 1 {
                    let span := sub(high, low)
                    mid := add(low, div(mul(sub(fingerprint, lowFp), span), sub(highFp, lowFp)))
                }
                default { mid := shr(1, add(low, high)) }

                // Entry `mid` is lane mid % 8 of directory word mid / 8.
                let word := sload(add(add(dir, 1), shr(3, mid)))
                let entry := and(shr(shl(5, and(mid, 7)), word), ENTRY_MASK)
                let midFp := shr(INDEX_BITS, entry)

                if eq(midFp, fingerprint) {
                    found := 1
                    index := and(entry, INDEX_MASK)
                    break
                }

                switch lt(midFp, fingerprint)
                case 1 {
                    low := add(mid, 1)
                    lowFp := add(midFp, 1)
                }
                default {
                    high := mid
                    highFp := midFp
                }
            }
        }
    }

    function _entryAt(uint256 dir, uint256 position) private view returns (uint256) {
        uint256 word = _load(dir + 1 + position / ENTRIES_PER_SLOT);

        return (word >> ((position % ENTRIES_PER_SLOT) * ENTRY_BITS)) & ENTRY_MASK;
    }

    function _loadEntries(uint256 dir) private view returns (uint256[] memory entries) {
        entries = new uint256[](_load(dir));

        for (uint256 i; i < entries.length; ++i) {
            entries[i] = _entryAt(dir, i);
        }
    }

    /// Finds a live packed record in the in-memory directory. Returns its identity slot, or 0 if
    /// the record is not packed.
    function _locatePacked(uint256[] memory entries, uint256 dir, uint256 stride, uint256 id)
        private
        view
        returns (uint256 location, uint256 position)
    {
        uint256 fingerprint = id >> FINGERPRINT_SHIFT;
        uint256 low;
        uint256 high = entries.length;

        while (low < high) {
            position = (low + high) >> 1;

            // Removed entries keep their fingerprint bits, so the array stays sorted.
            uint256 entry = entries[position];
            uint256 midFingerprint = (entry & ENTRY_MASK) >> INDEX_BITS;

            if (midFingerprint == fingerprint) {
                if (entry & REMOVED != 0) return (0, 0);

                location = _packedSlot(dir, stride, entry & INDEX_MASK);

                return _load(location) == id ? (location, position) : (0, 0);
            }

            if (midFingerprint < fingerprint) low = position + 1;
            else high = position;
        }

        return (0, 0);
    }

    /// Merges live entries with the newly added ones into a single sorted list. Two records with
    /// the same fingerprint can't both be packed, because lookups could not tell them apart.
    function _merge(uint256[] memory entries, uint256[] memory added, uint256 addedCount)
        private
        pure
        returns (uint256[] memory merged)
    {
        _sort(added, 0, addedCount);

        merged = new uint256[](entries.length + addedCount);
        uint256 count;
        uint256 i;
        uint256 j;

        while (i < entries.length || j < addedCount) {
            uint256 next;

            if (i < entries.length && entries[i] & REMOVED != 0) {
                ++i;
                continue;
            }

            if (j == addedCount || (i < entries.length && entries[i] < added[j])) {
                next = entries[i++];
            } else {
                next = added[j++];
            }

            if (count != 0 && (merged[count - 1] >> INDEX_BITS) == (next >> INDEX_BITS)) {
                revert FingerprintCollision(next >> INDEX_BITS);
            }

            merged[count++] = next;
        }

        if (count > MAX_PACKED) revert DirectoryFull();

        assembly ("memory-safe") {
            mstore(merged, count)
        }
    }

    /// Writes the directory back, touching only words that changed and clearing any left over
    /// from a longer previous directory.
    function _writeEntries(uint256 dir, uint256 oldCount, uint256[] memory entries) private {
        _store(dir, entries.length);

        uint256 longest = entries.length > oldCount ? entries.length : oldCount;
        uint256 words = (longest + ENTRIES_PER_SLOT - 1) / ENTRIES_PER_SLOT;

        for (uint256 w; w < words; ++w) {
            uint256 word;

            for (uint256 lane; lane < ENTRIES_PER_SLOT; ++lane) {
                uint256 position = w * ENTRIES_PER_SLOT + lane;
                if (position >= entries.length) break;

                word |= entries[position] << (lane * ENTRY_BITS);
            }

            if (_load(dir + 1 + w) != word) _store(dir + 1 + w, word);
        }
    }

    // ------------------------------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------------------------------

    /// Copies `count` words to an empty destination and clears the source. Zero words are
    /// skipped since the destination already holds zero there.
    function _move(uint256 from, uint256 to, uint256 count) private {
        for (uint256 i; i < count; ++i) {
            uint256 value = _load(from + i);

            if (value != 0) {
                _store(to + i, value);
                _store(from + i, 0);
            }
        }
    }

    /// In-place quicksort of a[low..high). The middle element is the pivot, so input that is
    /// already sorted (the common case for a resubmitted layout) stays O(n log n).
    function _sort(uint256[] memory a, uint256 low, uint256 high) private pure {
        if (high - low < 2) return;

        uint256 last = high - 1;
        (a[(low + high) / 2], a[last]) = (a[last], a[(low + high) / 2]);

        uint256 pivot = a[last];
        uint256 boundary = low;

        for (uint256 i = low; i < last; ++i) {
            if (a[i] < pivot) {
                (a[i], a[boundary]) = (a[boundary], a[i]);
                ++boundary;
            }
        }

        (a[boundary], a[last]) = (a[last], a[boundary]);

        _sort(a, low, boundary);
        _sort(a, boundary + 1, high);
    }

    function _load(uint256 slot_) private view returns (uint256 value) {
        assembly ("memory-safe") {
            value := sload(slot_)
        }
    }

    function _store(uint256 slot_, uint256 value) private {
        assembly ("memory-safe") {
            sstore(slot_, value)
        }
    }
}
