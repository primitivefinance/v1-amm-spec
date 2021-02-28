pragma solidity ^0.7.1;

/**
 * @title   The Primitive AMM for Short Option Tokens.
 * @author  Primitive
 */

// Open Zeppelin
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import {SafeMath} from "@openzeppelin/contracts/math/SafeMath.sol";
import {
    ReentrancyGuard
} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {PrimitiveERC20} from "./PrimitiveERC20.sol";
import {SwapMath} from "./SwapMath.sol";

import "hardhat/console.sol";

contract PrimitiveAmm is PrimitiveERC20, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    event Mint(
        address indexed from,
        uint256 shortAmount,
        uint256 underlyingAmount
    );
    event Burn(
        address indexed from,
        uint256 shortAmount,
        uint256 underlyingAmount,
        address indexed receiver
    );
    event SwapToShort(
        address indexed from,
        uint256 shortAmount,
        uint256 underlyingAmount,
        address indexed receiver
    );
    event SwapFromShort(
        address indexed from,
        uint256 shortAmount,
        uint256 underlyingAmount,
        address indexed receiver
    );
    event UpdatedCaches(uint256 postShortCache, uint256 postUnderlyingCache);

    // Pool variables.
    uint32 public liquidityFee; //0.30%
    int256 public scalar;
    int256 public anchor;

    uint256 public underlyingCache;
    uint256 public shortCache;
    address public shortToken;
    address public underlyingToken;

    constructor() {}

    function initialize(
        address shortToken_,
        address underlyingToken_,
        uint256 scalar_,
        uint256 anchor_
    ) public {
        require(
            underlyingCache == 0 && shortCache == 0,
            "PrimitiveV2: INITIALIZED"
        );
        shortToken = shortToken_;
        underlyingToken = underlyingToken_;
        scalar = int256(scalar_);
        anchor = int256(anchor_);
        liquidityFee = SwapMath.minFee();
    }

    function getCaches() public view returns (uint256, uint256) {
        return (shortCache, underlyingCache);
    }

    function _updateCaches(uint256 updatedShort, uint256 updatedUnderlying)
        internal
    {
        shortCache = updatedShort;
        underlyingCache = updatedUnderlying;
        emit UpdatedCaches(updatedShort, updatedUnderlying);
    }

    /**
     * @dev Updates the cached balances to match the actual current balances.
     * Attempting to transfer tokens to this contract directly, in a separate transaction,
     * is incorrect and could result in loss of funds. Calling this function will permanently lock any excess
     * underlying or strike tokens which were erroneously sent to this contract.
     */
    function updateCacheBalances() external nonReentrant {
        _updateCaches(
            IERC20(shortToken).balanceOf(address(this)),
            IERC20(underlyingToken).balanceOf(address(this))
        );
    }

    // optimistic pro-rata liquidity token implementation
    function mint(address receiver)
        external
        nonReentrant
        returns (uint256 liquidity)
    {
        (uint256 shortCache_, uint256 underlyingCache_) = getCaches();
        uint256 shortBalance = IERC20(shortToken).balanceOf(address(this));
        uint256 underlyingBalance =
            IERC20(underlyingToken).balanceOf(address(this));
        uint256 shortAmount = shortBalance.sub(shortCache_);
        uint256 underlyingAmount = underlyingBalance.sub(underlyingCache_);
        uint256 _totalSupply = totalSupply;
        if (_totalSupply == 0) {
            liquidity = SwapMath.sqrt(shortAmount.mul(underlyingAmount)).sub(
                SwapMath.minLiquidity()
            );
            _mint(address(0), SwapMath.minLiquidity()); // prevent monopolization of pool
        } else {
            liquidity = SwapMath.min(
                shortAmount.mul(_totalSupply) / shortCache_,
                underlyingAmount.mul(_totalSupply) / underlyingCache_
            );
        }
        require(liquidity > 0, "PrimitiveV2: LIQUIDITY_ZERO");
        _mint(receiver, liquidity);

        _updateCaches(shortBalance, underlyingBalance);
        emit Mint(msg.sender, shortAmount, underlyingAmount);
    }

    // optimistic pro-rata liquidity token implementation
    function burn(address receiver)
        external
        nonReentrant
        returns (uint256 shortAmount, uint256 underlyingAmount)
    {
        (uint256 shortCache_, uint256 underlyingCache_) = getCaches();
        address shortToken_ = shortToken;
        address underlyingToken_ = underlyingToken;
        uint256 shortBalance = IERC20(shortToken_).balanceOf(address(this));
        uint256 underlyingBalance =
            IERC20(underlyingToken_).balanceOf(address(this));
        uint256 liquidity = balanceOf[address(this)];

        uint256 _totalSupply = totalSupply;
        shortAmount = liquidity.mul(shortBalance) / _totalSupply;
        underlyingAmount = liquidity.mul(underlyingBalance) / _totalSupply;
        require(
            shortAmount > 0 && underlyingAmount > 0,
            "PrimitiveV2: ZERO_BURNED"
        );
        _burn(address(this), liquidity);
        IERC20(shortToken_).safeTransfer(receiver, shortAmount);
        IERC20(underlyingToken_).safeTransfer(receiver, underlyingAmount);
        shortBalance = IERC20(shortToken_).balanceOf(address(this));
        underlyingBalance = IERC20(underlyingToken_).balanceOf(address(this));

        _updateCaches(shortBalance, underlyingBalance);
        emit Burn(msg.sender, shortAmount, underlyingAmount, receiver);
    }

    // sells short for underlying.
    // isSellingShort = true
    function swapShortToUnderlying(uint256 amountShortIn, address receiver)
        external
        nonReentrant
        returns (uint256, bool)
    {
        require(amountShortIn > 0, "PrimitiveV2: AMOUNT_ZERO");
        (uint256 cache0, uint256 cache1) = getCaches();
        uint256 shortBalance;
        uint256 underlyingBalance;
        // get quantity of underlying paid
        uint256 quote = _quoteIn(amountShortIn);
        // pay out underlying
        IERC20(underlyingToken).safeTransfer(receiver, quote);
        shortBalance = IERC20(shortToken).balanceOf(address(this));
        underlyingBalance = IERC20(underlyingToken).balanceOf(address(this));
        // short
        uint256 amount0In = shortBalance > cache0 ? shortBalance - cache0 : 0;
        // underlying
        uint256 amount1In =
            underlyingBalance > cache1 - quote
                ? underlyingBalance - (cache1 - quote)
                : 0;
        require(
            amount0In > 0 || amount1In > 0,
            "PrimitiveV2: RETURNED_AMOUNT_ZERO"
        );
        // make sure underlying payout is either returned with liquidity fee
        // or `amountShortIn` of short tokens was paid
        // assert invariant
        require(
            amount0In >= amountShortIn ||
                amount1In >= quote.add(quote.div(liquidityFee))
        );
        // update caches
        _updateCaches(shortBalance, underlyingBalance);
        emit SwapFromShort(msg.sender, amountShortIn, quote, receiver);
    }

    // buys short for underlying
    // isSellingShort = false
    function swapUnderlyingToShort(uint256 amountShortOut, address receiver)
        external
        nonReentrant
        returns (uint256, bool)
    {
        require(amountShortOut > 0, "PrimitiveV2: AMOUNT_ZERO");
        (uint256 cache0, uint256 cache1) = getCaches();
        uint256 shortBalance;
        uint256 underlyingBalance;
        // get quantity of underlying paid
        uint256 quote = _quoteOut(amountShortOut);
        // pay out short
        IERC20(shortToken).safeTransfer(receiver, amountShortOut);
        shortBalance = IERC20(shortToken).balanceOf(address(this));
        underlyingBalance = IERC20(underlyingToken).balanceOf(address(this));
        // short
        uint256 amount0In =
            shortBalance > cache0 - amountShortOut
                ? shortBalance - (cache0 - amountShortOut)
                : 0;
        // underlying
        uint256 amount1In =
            underlyingBalance > cache1 ? underlyingBalance - cache1 : 0;
        require(
            amount0In > 0 || amount1In > 0,
            "PrimitiveV2: RETURNED_AMOUNT_ZERO"
        );
        // make sure underlying payout is either returned with liquidity fee
        // or `amountShortOut` of short tokens was paid
        // assert invariant
        require(
            amount0In >= amountShortOut.add(amountShortOut.div(liquidityFee)) ||
                amount1In >= quote,
            "PrimitiveV2: INVARIANT"
        );
        // update caches
        _updateCaches(shortBalance, underlyingBalance);
        emit SwapToShort(msg.sender, amountShortOut, quote, receiver);
    }

    // ===== Quotes =====

    function _quoteIn(uint256 size) internal view returns (uint256) {
        uint256 executedRate = getExchangeRateIn(size);
        if (executedRate == 0) return 0;
        return SwapMath.convertShortToUnderlying(size, executedRate);
    }

    function _quoteOut(uint256 size) internal view returns (uint256) {
        uint256 executedRate = getExchangeRateOut(size);
        if (executedRate == 0) return 0;
        return SwapMath.convertShortToUnderlying(size, executedRate);
    }

    // a trade selling short for underlying / buying underlying for short. short -> under
    function getShortToUnderlyingQuote(uint256 shortAmount)
        public
        view
        returns (uint256)
    {
        return _quoteIn(shortAmount);
    }

    // a trade buying short for underlying / selling underlying for short. under -> short
    function getUnderlyingToShortQuote(uint256 shortAmount)
        public
        view
        returns (uint256)
    {
        return _quoteOut(shortAmount);
    }

    // ===== Proportions =====

    // shortCache / (shortCache + underlyingCache)
    function getProportion() public view returns (uint256) {
        if (shortCache == 0 && underlyingCache == 0) return 0;
        return shortCache.mul(1e18).div(shortCache.add(underlyingCache));
    }

    function getShortProportionIn(uint256 amount)
        public
        view
        returns (uint256)
    {
        return SwapMath.shortProportionIn(amount, shortCache, underlyingCache);
    }

    function getShortProportionOut(uint256 amount)
        public
        view
        returns (uint256)
    {
        return SwapMath.shortProportionOut(amount, shortCache, underlyingCache);
    }

    // ===== Exchange Rates =====

    // shortTokens / exchangeRate = underlyingTokens
    // 1 / exchangeRate = underlyingTokens / shortTokens
    function getSpotExchangeRate() public view returns (uint256) {
        return SwapMath.spotRate(anchor, scalar, shortCache, underlyingCache);
    }

    function getSpotRate() public view returns (uint256) {
        uint256 spotExchangeRate = getSpotExchangeRate();
        if (spotExchangeRate == 0) return 0;
        uint256 inverse = uint256(1e18).div(spotExchangeRate);
        return uint256(SwapMath.precision() - inverse);
    }

    function getRateIn(uint256 amount) internal view returns (uint32) {
        return
            SwapMath.shortRateIn(
                anchor,
                scalar,
                amount,
                shortCache,
                underlyingCache
            );
    }

    function getRateOut(uint256 amount) internal view returns (uint32) {
        return
            SwapMath.shortRateOut(
                anchor,
                scalar,
                amount,
                shortCache,
                underlyingCache
            );
    }

    function getExchangeRateIn(uint256 amount) public view returns (uint256) {
        uint32 rate = getRateIn(amount);
        return SwapMath.executedRateIn(rate, liquidityFee);
    }

    function getExchangeRateOut(uint256 amount) public view returns (uint256) {
        uint32 rate = getRateOut(amount);
        return SwapMath.executedRateOut(rate, liquidityFee);
    }
}
