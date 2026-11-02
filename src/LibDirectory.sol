// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {LibSort} from "./utils/LibSort.sol";

/// @title LibDirectory
/// @notice The directory of a PagePack map: one page mapping a short fingerprint of every packed
///         record to its packed index.
///
/// Layout, from a page-aligned slot `dir`:
///
///   dir + 0              number of entries
///   dir + 1 .. dir + 127 entries, 8 per slot, the first in the lowest 32 bits
///
/// An entry is 32 bits: a 22-bit fingerprint (the top bits of the record's identity) above a
/// 10-bit packed index. Entries are kept sorted, which sorts them by fingerprint, and no two share
/// a fingerprint.
library LibDirectory {
    /// Entry slots after the header, times 8 entries per slot.
    uint256 internal constant CAPACITY = 127 * 8;

    /// Packed indices are stored in 10 bits.
    uint256 internal constant INDEX_LIMIT = 1 << 10;

    // Plain literals, so that inline assembly can use them.
    uint256 private constant INDEX_BITS = 10;
    uint256 private constant INDEX_MASK = 0x3ff;
    uint256 private constant FINGERPRINT_SHIFT = 234;
    uint256 private constant ENTRY_BITS = 32;
    uint256 private constant ENTRY_MASK = 0xffffffff;
    uint256 private constant ENTRIES_PER_SLOT = 8;

    // Search rounds that interpolate before falling back to bisection.
    uint256 private constant INTERPOLATION_ROUNDS = 5;

    // For comparing a word's 8 entries at once: a 1 at the bottom of each 64-bit field, and the
    // low 32 bits of each.
    uint256 private constant FIELD_ONES =
        0x0000000000000001000000000000000100000000000000010000000000000001;
    uint256 private constant FIELD_LOW_HALVES =
        0x00000000ffffffff00000000ffffffff00000000ffffffff00000000ffffffff;

    /// @notice Number of entries.
    function length(uint256 dir) internal view returns (uint256) {
        return _load(dir);
    }

    /// @notice The fingerprint the directory keeps for a record identity.
    function fingerprintOf(uint256 id) internal pure returns (uint256) {
        return id >> FINGERPRINT_SHIFT;
    }

    /// @notice An insertion for {rebuild}: the entry for `id` at `index`, with the caller's
    ///         `tag` (below 2^32) in the low bits so a collision can be traced back to it.
    function taggedEntry(uint256 id, uint256 index, uint256 tag) internal pure returns (uint256) {
        uint256 entry = ((id >> FINGERPRINT_SHIFT) << INDEX_BITS) | index;

        return (entry << ENTRY_BITS) | tag;
    }

    /// @notice Finds the entry with `id`'s fingerprint: its packed index and its position.
    /// @dev The header and entries share a page, so only the first read pays for a page load;
    ///      each further probe is a 100 gas read.
    ///
    ///      Each probe loads a word and compares the fingerprint with all 8 of its entries. The
    ///      word is chosen by interpolation: fingerprints are hash bits, spread evenly, so the
    ///      guess usually lands on the right word or next to it, and a miss still rules out
    ///      everything on one side of the word. Over random directories of up to 1,016 entries
    ///      a search takes 1.3 to 2 probes on average and almost never more than 4, whether or
    ///      not the fingerprint is listed. A skewed set of fingerprints (e.g. ground by an
    ///      attacker hoping to be packed) can defeat interpolation, so after a few rounds the
    ///      search falls back to bisection, and no search takes more than 12 probes.
    ///
    ///      This is the hot path for every lookup without a hint, hence the assembly: in checked
    ///      Solidity the arithmetic cost several times the storage reads.
    function search(uint256 dir, uint256 id)
        internal
        view
        returns (bool found, uint256 index, uint256 position)
    {
        assembly ("memory-safe") {
            // How many of the first `lanes` entries in `word` have a fingerprint below
            // `fingerprint`. Even and odd entries are compared separately, each in the low half
            // of a 64-bit field, so subtracting one from (fingerprint << 10) + 2^32 - 1 sets bit
            // 32 of its field exactly when the entry is smaller, without borrowing from the next
            // field. Entries from `lanes` on are filled with ones, so they never count.
            function lanesBelow(word, lanes, fingerprint) -> count {
                word := or(word, shl(shl(5, lanes), not(0)))

                let target := mul(add(shl(INDEX_BITS, fingerprint), ENTRY_MASK), FIELD_ONES)
                let even := shr(32, sub(target, and(word, FIELD_LOW_HALVES)))
                let odd := shr(32, sub(target, and(shr(32, word), FIELD_LOW_HALVES)))

                // Multiplying by FIELD_ONES adds up the four fields in the top one.
                count := shr(192, mul(add(and(even, FIELD_ONES), and(odd, FIELD_ONES)), FIELD_ONES))
            }

            let fingerprint := shr(FINGERPRINT_SHIFT, id)
            let low := 0
            let high := sload(dir)

            // Every fingerprint at positions [low, high) lies in [lowFp, highFp). Probes move the
            // bounds to word boundaries, so a probed word never holds entries below low, and only
            // the directory's last word can run past high.
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

                // Entry `mid` is in directory word mid / 8, whose entries from `first` to
                // `first + lanes - 1` are in range.
                let first := and(mid, not(7))
                let word := sload(add(add(dir, 1), shr(3, mid)))
                let lanes := sub(high, first)
                if gt(lanes, ENTRIES_PER_SLOT) { lanes := ENTRIES_PER_SLOT }

                // The first entry at or above the fingerprint, if the word has one.
                let lane := lanesBelow(word, lanes, fingerprint)

                // Above the whole word.
                if eq(lane, lanes) {
                    let lastEntry := and(shr(shl(5, sub(lanes, 1)), word), ENTRY_MASK)

                    low := add(first, lanes)
                    lowFp := add(shr(INDEX_BITS, lastEntry), 1)
                    continue
                }

                let entry := and(shr(shl(5, lane), word), ENTRY_MASK)
                let laneFp := shr(INDEX_BITS, entry)

                if eq(laneFp, fingerprint) {
                    found := 1
                    index := and(entry, INDEX_MASK)
                    position := add(first, lane)
                    break
                }

                // Below the whole word, or else between two of its entries and so not listed.
                if iszero(lane) {
                    high := first
                    highFp := laneFp
                    continue
                }

                break
            }
        }
    }

    /// @notice Points the entry at `position` to a new packed index. Its fingerprint, and so the
    ///         order, doesn't change.
    function setIndex(uint256 dir, uint256 position, uint256 index) internal {
        uint256 location = dir + 1 + position / ENTRIES_PER_SLOT;
        uint256 shift = (position % ENTRIES_PER_SLOT) * ENTRY_BITS;

        _store(location, (_load(location) & ~(INDEX_MASK << shift)) | (index << shift));
    }

    /// @notice Rewrites the directory without the entries at the positions marked in `removed`
    ///         (`removedCount` of them) and with `insertions`, each a {taggedEntry}, merged in.
    ///         Two records with the same fingerprint can't both be listed, because lookups could
    ///         not tell them apart: on a clash nothing is written, and the tags of both entries
    ///         come back, ~0 for an entry already stored. The caller checks capacity first.
    /// @dev Sorts `insertions` in place. The sort returns early on sorted input, so listing new
    ///      records in fingerprint order saves gas.
    function rebuild(
        uint256 dir,
        uint256[4] memory removed,
        uint256 removedCount,
        uint256[] memory insertions
    ) internal returns (bool collided, uint256 tag, uint256 otherTag) {
        uint256 count = _load(dir);
        uint256 nextCount = count - removedCount + insertions.length;

        LibSort.sort(insertions);

        uint256[] memory stored = _loadWords(dir, count);
        uint256[] memory merged = new uint256[]((nextCount + 7) / ENTRIES_PER_SLOT);

        (collided, tag, otherTag) = _merge(stored, count, removed, insertions, merged);
        if (collided) return (collided, tag, otherTag);

        _writeWords(dir, stored, merged);
        if (nextCount != count) _store(dir, nextCount);
    }

    function _loadWords(uint256 dir, uint256 count) private view returns (uint256[] memory words) {
        words = new uint256[]((count + 7) / ENTRIES_PER_SLOT);

        for (uint256 w; w < words.length; ++w) {
            words[w] = _load(dir + 1 + w);
        }
    }

    /// Writes back only the words that changed, clearing any a shorter directory leaves behind.
    function _writeWords(uint256 dir, uint256[] memory stored, uint256[] memory merged) private {
        uint256 words = stored.length > merged.length ? stored.length : merged.length;

        for (uint256 w; w < words; ++w) {
            uint256 word = w < merged.length ? merged[w] : 0;
            if (w >= stored.length || stored[w] != word) _store(dir + 1 + w, word);
        }
    }

    /// Merges the stored entries, minus removed ones, with the sorted insertions, packing the
    /// result 8 to a word into `merged`. Two records with the same fingerprint can't both be
    /// packed, because lookups could not tell them apart, so a clash stops the merge and reports
    /// the tags of both entries (~0 for a stored one).
    ///
    /// This walks the whole directory, so it is assembly: in Solidity, bounds checks and checked
    /// arithmetic cost several hundred gas per entry, over a million for a full directory. Most
    /// stored words hold no change at all, and those are copied 8 entries at a time.
    function _merge(
        uint256[] memory stored,
        uint256 count,
        uint256[4] memory removed,
        uint256[] memory insertions,
        uint256[] memory merged
    ) private pure returns (bool collided, uint256 tag, uint256 lastTag) {
        assembly ("memory-safe") {
            let words := add(stored, 0x20)
            let next := add(insertions, 0x20)
            let end := add(next, shl(5, mload(insertions)))
            let out := add(merged, 0x20)

            let position := 0
            let produced := 0
            let word := 0
            let lastFingerprint := not(0)
            lastTag := not(0)

            for {} 1 {} {
                // Fast path: a whole stored word with nothing removed from it, every entry below
                // the next insertion's fingerprint, and no clash with the entry before it.
                for {} and(iszero(and(position, 7)), iszero(gt(add(position, 8), count))) {} {
                    let source := mload(add(words, shl(5, shr(3, position))))
                    let bits := mload(add(removed, shl(5, shr(8, position))))

                    if and(shr(and(position, 255), bits), 0xff) { break }
                    if eq(shr(INDEX_BITS, and(source, ENTRY_MASK)), lastFingerprint) { break }

                    // Lane 7 holds the word's largest entry.
                    let lastInWord := shr(224, source)

                    if lt(next, end) {
                        let insertion := shr(ENTRY_BITS, mload(next))
                        if iszero(gt(shr(INDEX_BITS, insertion), shr(INDEX_BITS, lastInWord))) {
                            break
                        }
                    }

                    // The word fills the rest of the output word and spills into the next.
                    let lanes := shl(5, and(produced, 7))
                    mstore(add(out, shl(5, shr(3, produced))), or(word, shl(lanes, source)))
                    word := shr(sub(256, lanes), source)

                    produced := add(produced, 8)
                    position := add(position, 8)
                    lastFingerprint := shr(INDEX_BITS, lastInWord)
                    lastTag := not(0)
                }

                // Skip removed entries. Positions stay below 1,024, inside the bitmap.
                for {} lt(position, count) { position := add(position, 1) } {
                    let bits := mload(add(removed, shl(5, shr(8, position))))
                    if iszero(and(shr(and(position, 255), bits), 1)) { break }
                }

                // The next stored entry, or ~0 once they run out, which sorts after everything.
                let kept := not(0)
                if lt(position, count) {
                    let source := mload(add(words, shl(5, shr(3, position))))
                    kept := and(shr(shl(5, and(position, 7)), source), ENTRY_MASK)
                }

                let entry := kept
                tag := not(0)

                switch lt(next, end)
                case 1 {
                    let insertion := mload(next)

                    if lt(shr(ENTRY_BITS, insertion), kept) {
                        entry := shr(ENTRY_BITS, insertion)
                        tag := and(insertion, ENTRY_MASK)
                        next := add(next, 0x20)
                    }
                }
                default { if eq(kept, not(0)) { break } }

                if eq(tag, not(0)) { position := add(position, 1) }

                let fingerprint := shr(INDEX_BITS, entry)
                if eq(fingerprint, lastFingerprint) {
                    collided := 1
                    break
                }

                lastFingerprint := fingerprint
                lastTag := tag

                word := or(word, shl(shl(5, and(produced, 7)), entry))
                produced := add(produced, 1)

                if iszero(and(produced, 7)) {
                    mstore(add(out, shl(5, sub(shr(3, produced), 1))), word)
                    word := 0
                }
            }

            if and(produced, 7) { mstore(add(out, shl(5, shr(3, produced))), word) }
        }
    }

    function _load(uint256 slot) private view returns (uint256 value) {
        assembly ("memory-safe") {
            value := sload(slot)
        }
    }

    function _store(uint256 slot, uint256 value) private {
        assembly ("memory-safe") {
            sstore(slot, value)
        }
    }
}
