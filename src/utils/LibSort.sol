// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

/*
 * Copied from Solady v0.1.26, trimmed to `sort(uint256[])` and otherwise unchanged, so that
 * pagepack has no dependencies:
 * https://github.com/Vectorized/solady/blob/v0.1.26/src/utils/LibSort.sol
 *
 * MIT License
 *
 * Copyright (c) 2022-2025 Solady.
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 */

/// @notice Optimized sorts and operations for sorted arrays.
/// @author Solady (https://github.com/Vectorized/solady/blob/main/src/utils/LibSort.sol)
library LibSort {
    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                      INTRO-QUICKSORT                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    // - Faster on larger arrays (more than 32 elements).
    // - Robust performance.
    // - Larger bytecode.

    /// @dev Sorts the array in-place with intro-quicksort.
    function sort(uint256[] memory a) internal pure {
        /// @solidity memory-safe-assembly
        assembly {
            function swap(a_, b_) -> _a, _b {
                _b := a_
                _a := b_
            }
            function mswap(i_, j_) {
                let t_ := mload(i_)
                mstore(i_, mload(j_))
                mstore(j_, t_)
            }
            function sortInner(w_, l_, h_) {
                // Do insertion sort if `h_ - l_ <= 0x20 * 12`.
                // Threshold is fine-tuned via trial and error.
                if iszero(gt(sub(h_, l_), 0x180)) {
                    // Hardcode sort the first 2 elements.
                    let i_ := add(l_, 0x20)
                    if iszero(lt(mload(l_), mload(i_))) { mswap(i_, l_) }
                    for {} 1 {} {
                        i_ := add(i_, 0x20)
                        if gt(i_, h_) { break }
                        let k_ := mload(i_) // Key.
                        let j_ := add(i_, w_) // The slot before the current slot.
                        let v_ := mload(j_) // The value of `j_`.
                        if iszero(gt(v_, k_)) { continue }
                        for {} 1 {} {
                            mstore(add(j_, 0x20), v_)
                            j_ := add(j_, w_)
                            v_ := mload(j_)
                            if iszero(gt(v_, k_)) { break }
                        }
                        mstore(add(j_, 0x20), k_)
                    }
                    leave
                }
                // Pivot slot is the average of `l_` and `h_`.
                let p_ := add(shl(5, shr(6, add(l_, h_))), and(31, l_))
                // Median of 3 with sorting.
                {
                    let e0_ := mload(l_)
                    let e1_ := mload(p_)
                    if iszero(lt(e0_, e1_)) { e0_, e1_ := swap(e0_, e1_) }
                    let e2_ := mload(h_)
                    if iszero(lt(e1_, e2_)) {
                        e1_, e2_ := swap(e1_, e2_)
                        if iszero(lt(e0_, e1_)) { e0_, e1_ := swap(e0_, e1_) }
                    }
                    mstore(h_, e2_)
                    mstore(p_, e1_)
                    mstore(l_, e0_)
                }
                // Hoare's partition.
                {
                    // The value of the pivot slot.
                    let x_ := mload(p_)
                    p_ := h_
                    for { let i_ := l_ } 1 {} {
                        for {} 1 {} {
                            i_ := add(0x20, i_)
                            if iszero(gt(x_, mload(i_))) { break }
                        }
                        let j_ := p_
                        for {} 1 {} {
                            j_ := add(w_, j_)
                            if iszero(lt(x_, mload(j_))) { break }
                        }
                        p_ := j_
                        if iszero(lt(i_, p_)) { break }
                        mswap(i_, p_)
                    }
                }
                if iszero(eq(add(p_, 0x20), h_)) { sortInner(w_, add(p_, 0x20), h_) }
                if iszero(eq(p_, l_)) { sortInner(w_, l_, p_) }
            }

            for { let n := mload(a) } iszero(lt(n, 2)) {} {
                let w := not(0x1f) // `-0x20`.
                let l := add(a, 0x20) // Low slot.
                let h := add(a, shl(5, n)) // High slot.
                let j := h
                // While `mload(j - 0x20) <= mload(j): j -= 0x20`.
                for {} iszero(gt(mload(add(w, j)), mload(j))) {} { j := add(w, j) }
                // If the array is already sorted, break.
                if iszero(gt(j, l)) { break }
                // While `mload(j - 0x20) >= mload(j): j -= 0x20`.
                for { j := h } iszero(lt(mload(add(w, j)), mload(j))) {} { j := add(w, j) }
                // If the array is reversed sorted.
                if iszero(gt(j, l)) {
                    for {} 1 {} {
                        let t := mload(l)
                        mstore(l, mload(h))
                        mstore(h, t)
                        h := add(w, h)
                        l := add(l, 0x20)
                        if iszero(lt(l, h)) { break }
                    }
                    break
                }
                mstore(a, 0) // For insertion sort's inner loop to terminate.
                sortInner(w, l, h)
                mstore(a, n) // Restore the length of `a`.
                break
            }
        }
    }
}
