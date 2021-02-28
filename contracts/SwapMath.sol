// SPDX-License-Identifier: MIT
// Copyright 2021 Primitive Finance
//
// Permission is hereby granted, free of charge, to any person obtaining a copy of
// this software and associated documentation files (the "Software"), to deal in
// the Software without restriction, including without limitation the rights to
// use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
// of the Software, and to permit persons to whom the Software is furnished to do
// so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

pragma solidity ^0.7.1;

/**
 * @title   Library for math to determine swap outputs, exchange rates, and proportions.
 * @author  Primitive
 */

// Open Zeppelin & ABDK
import {SafeMath} from "@openzeppelin/contracts/math/SafeMath.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/SafeCast.sol";
import {ABDKMath64x64} from "./libraries/ABDKMath64x64.sol";

// Primitive
import {Math} from "./libraries/Math.sol";
import {SwapConstants} from "./SwapConstants.sol";

library SwapMath {
    using SafeMath for uint256;

    /**
     * @notice  Get exchange rate from swapping Short into Underlying.
     * @dev     Add short to total cached balance.
     */
    function shortRateIn(
        int256 anchor,
        int256 scalar,
        uint256 shortAmount,
        uint256 shortBalance,
        uint256 underlyingBalance
    ) internal pure returns (uint32) {
        if (shortBalance == 0 || underlyingBalance == 0) {
            return uint32(0);
        }
        // (shortBalance +/- shortAmount) / shortBalance + underlyingBalance
        uint256 shortProportion =
            shortProportionIn(shortAmount, shortBalance, underlyingBalance);
        return calculateRate(anchor, shortProportion, scalar);
    }

    /**
     * @notice  Get exchange rate for swapping Underlying into Short
     */
    function shortRateOut(
        int256 anchor,
        int256 scalar,
        uint256 shortAmount,
        uint256 shortBalance,
        uint256 underlyingBalance
    ) internal pure returns (uint32) {
        if (
            shortBalance == 0 ||
            underlyingBalance == 0 ||
            (shortAmount > shortBalance)
        ) {
            return uint32(0);
        }
        // (shortBalance +/- shortAmount) / shortBalance + underlyingBalance
        uint256 shortProportion =
            shortProportionOut(shortAmount, shortBalance, underlyingBalance);
        return calculateRate(anchor, shortProportion, scalar);
    }

    /**
     * @notice  Gets new short ratio relative to total token balance, after adding short.
     */
    function shortProportionIn(
        uint256 shortAmount,
        uint256 shortBalance,
        uint256 underlyingBalance
    ) internal pure returns (uint256) {
        uint256 numerator = shortBalance.add(shortAmount);
        return numerator.mul(1e18).div(shortBalance.add(underlyingBalance));
    }

    /**
     * @notice  Gets new short ratio relative to total token balance, after removing short.
     */
    function shortProportionOut(
        uint256 shortAmount,
        uint256 shortBalance,
        uint256 underlyingBalance
    ) internal pure returns (uint256) {
        uint256 numerator = shortBalance.sub(shortAmount);
        return numerator.mul(1e18).div(shortBalance.add(underlyingBalance));
    }

    /**
     * @notice  Gets the current short token balance relative to the total token balance.
     */
    function spotRate(
        int256 anchor,
        int256 scalar,
        uint256 shortBalance,
        uint256 underlyingBalance
    ) internal pure returns (uint256) {
        if (shortBalance == 0 && underlyingBalance == 0) return 0;
        uint256 shortProportion =
            shortBalance.mul(1e18).div(shortBalance.add(underlyingBalance));
        return calculateRate(anchor, shortProportion, scalar);
    }

    /**
     * @notice  Gets the exchange rate for a shortProportion.
     */
    function calculateRate(
        int256 anchor,
        uint256 shortProportion,
        int256 scalar
    ) internal pure returns (uint32) {
        // (p / 1 - p)
        shortProportion = shortProportion.mul(1e18).div(
            uint256(1e18).sub(shortProportion)
        );

        // ln(p / 1 - p)
        int256 logarithmProportion = _ln(shortProportion);
        if (logarithmProportion == int256(0)) return uint32(0);

        int256 exchangeRate =
            ((logarithmProportion - SwapConstants.LN_1E18) / scalar) + anchor;
        // Check if valid uint32.
        if (exchangeRate < 0 || exchangeRate > SwapConstants.MAX_UINT_32) {
            return uint32(0);
        } else {
            return uint32(exchangeRate);
        }
    }

    function convertShortToUnderlying(uint256 size, uint256 rate)
        internal
        pure
        returns (uint256)
    {
        return size.mul(1e9).div(rate);
    }

    /**
     * @notice  Adds fee to the exchange rate.
     * @dev     Selling short -> short in -> add fee
     */
    function executedRateIn(uint32 rate, uint256 fee)
        internal
        pure
        returns (uint256)
    {
        return rate + fee;
    }

    /**
     * @notice  Subtracts fee from the exchange rate.
     * @dev     Buying short -> short out -> sub fee
     */
    function executedRateOut(uint32 rate, uint256 fee)
        internal
        pure
        returns (uint256)
    {
        return rate - fee;
    }

    // calculates the ln(p / (1 - p)) and returns a uint64
    function _ln(uint256 shortProportion) internal pure returns (uint64) {
        if (shortProportion > SwapConstants.MAX64) return uint64(0);

        int128 convertedProportion = ABDKMath64x64.fromUInt(shortProportion);
        if (convertedProportion <= 0) return uint64(0);

        int256 logarithm = ABDKMath64x64.ln(convertedProportion);
        int256 shifted = (logarithm * SwapConstants.PRECISION_64x64) >> 64;

        if (
            shifted < ABDKMath64x64.MIN_64x64 ||
            shifted > ABDKMath64x64.MAX_64x64
        ) {
            return uint64(0);
        }

        return ABDKMath64x64.toUInt(int128(shifted));
    }

    // ===== Math =====

    function min(uint256 x, uint256 y) internal pure returns (uint256 z) {
        return Math.min(x, y);
    }

    function sqrt(uint256 y) internal pure returns (uint256 z) {
        return Math.sqrt(y);
    }

    // ===== Constants =====

    function precision() internal pure returns (uint32) {
        return SwapConstants.PRECISION;
    }

    function minLiquidity() internal pure returns (uint256) {
        return SwapConstants.MINIMUM_LIQUIDITY;
    }

    function minFee() internal pure returns (uint32) {
        return SwapConstants.MIN_FEE;
    }
}
