pragma solidity ^0.7.1;

/**
 * @title   Library for constants used in the SwapMath and AMM.
 * @author  Primitive
 */

library SwapConstants {
    // Constants for math
    uint256 internal constant MINIMUM_LIQUIDITY = 1e3;
    uint32 internal constant MIN_FEE = uint32((1e6 * 1e9) / 4e9);
    uint32 internal constant PRECISION = 1e9;
    uint32 internal constant SECONDS_IN_YEAR = 31536000;
    uint32 internal constant MAX_UINT_32 = (2**32) - 1;
    uint256 internal constant MAX64 = 0x7FFFFFFFFFFFFFFF;
    uint128 internal constant MAX_UINT_128 = (2**128) - 1;
    int128 internal constant PRECISION_64x64 = 0x3b9aca000000000000000000;
    int64 internal constant LN_1E18 = 0x09a667e259;
}
