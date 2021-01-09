pragma solidity >=0.7.0;

/**
 * @title The Primitive AMM for Option Tokens.
 * @author Primitive
 */

import {ABDKMath64x64} from "./libraries/ABDKMath64x64.sol";
import {SafeMath} from "./libraries/SafeMath.sol";
import {SafeCast} from "./libraries/SafeCast.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {PrimitiveERC20} from "./PrimitiveERC20.sol";
import {Math} from "./libraries/Math.sol";
import "hardhat/console.sol";

contract PrimitiveAmm is PrimitiveERC20 {
    using SafeMath for uint;

    event Mint(address indexed from, uint shortAmount, uint underlyingAmount);
    event Burn(address indexed from, uint shortAmount, uint underlyingAmount, address indexed receiver);
    event SwapToShort(address indexed from, uint shortAmount, uint underlyingAmount, address indexed receiver);
    event SwapFromShort(address indexed from, uint shortAmount, uint underlyingAmount, address indexed receiver);
    event UpdatedCaches(uint postShortCache, uint postUnderlyingCache);
    
    // Selector
    bytes4 private constant SELECTOR = bytes4(keccak256(bytes('transfer(address,uint256)')));

    // Constants for math
    uint256 internal constant MINIMUM_LIQUIDITY = 1e3;
    uint256 internal constant MAX64 = 0x7FFFFFFFFFFFFFFF;
    uint128 internal constant MAX_UINT_128 = (2**128) - 1;
    uint32 internal constant MAX_UINT_32 = (2**32) - 1;
    uint32 internal constant PRECISION = 1e9;
    uint32 internal constant SECONDS_IN_YEAR = 31536000;
    uint32 internal constant MIN_FEE = uint32(1e6 * 1e9 / 4e9);
    int64 internal constant LN_1E18 = 0x09a667e259;
    int128 internal constant PRECISION_64x64 = 0x3b9aca000000000000000000;

    // Pool variables.
    uint32 public liquidityFee; //0.30%
    int256 public scalar;
    int256 public anchor;

    uint256 public underlyingCache;
    uint256 public shortCache;
    address public shortToken;
    address public underlyingToken;

    // internal variables
    uint private notEntered = 1;

    constructor() public {}

    modifier nonReentrant() {
        require(notEntered == 1, "PrimitiveV2: NON_REENTRANT");
        notEntered = 0;
        _;
        notEntered = 1;
    }

    function initialize(address shortToken_, address underlyingToken_, uint scalar_, uint anchor_) public {
        require(underlyingCache == 0 && shortCache == 0, 'PrimitiveV2: INITIALIZED');
        shortToken = shortToken_;
        underlyingToken = underlyingToken_;
        scalar = int256(scalar_);
        anchor = int256(anchor_);
        liquidityFee = MIN_FEE;
    }

    function _safeTransfer(address token, address to, uint value) private {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(SELECTOR, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'PrimitiveV2: TRANSFER_FAILED');
    }

    function getCaches() public view returns (uint, uint) {
        return (shortCache, underlyingCache);
    }

    function _updateCaches(uint updatedShort, uint updatedUnderlying) internal {
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
    function mint(address receiver) external nonReentrant returns (uint liquidity) {
        (uint shortCache_, uint underlyingCache_) = getCaches(); 
        uint shortBalance = IERC20(shortToken).balanceOf(address(this));
        uint underlyingBalance = IERC20(underlyingToken).balanceOf(address(this));
        uint shortAmount = shortBalance.sub(shortCache_);
        uint underlyingAmount = underlyingBalance.sub(underlyingCache_);
        uint _totalSupply = totalSupply;
        if (_totalSupply == 0) {
            liquidity = Math.sqrt(shortAmount.mul(underlyingAmount)).sub(MINIMUM_LIQUIDITY);
           _mint(address(0), MINIMUM_LIQUIDITY); // prevent monopolization of pool
        } else {
            liquidity = Math.min(shortAmount.mul(_totalSupply) / shortCache_, underlyingAmount.mul(_totalSupply) / underlyingCache_);
        }
        require(liquidity > 0, 'PrimitiveV2: LIQUIDITY_ZERO');
        _mint(receiver, liquidity);

        _updateCaches(shortBalance, underlyingBalance);
        emit Mint(msg.sender, shortAmount, underlyingAmount);
    }


    // optimistic pro-rata liquidity token implementation
    function burn(address receiver) external nonReentrant returns (uint shortAmount, uint underlyingAmount) {
        (uint shortCache_, uint underlyingCache_) = getCaches(); 
        address shortToken_ = shortToken;                           
        address underlyingToken_ = underlyingToken;                            
        uint shortBalance = IERC20(shortToken_).balanceOf(address(this));
        uint underlyingBalance = IERC20(underlyingToken_).balanceOf(address(this));
        uint liquidity = balanceOf[address(this)];

        uint _totalSupply = totalSupply; 
        shortAmount = liquidity.mul(shortBalance) / _totalSupply; 
        underlyingAmount = liquidity.mul(underlyingBalance) / _totalSupply; 
        require(shortAmount > 0 && underlyingAmount > 0, 'PrimitiveV2: ZERO_BURNED');
        _burn(address(this), liquidity);
        _safeTransfer(shortToken_, receiver, shortAmount);
        _safeTransfer(underlyingToken_, receiver, underlyingAmount);
        shortBalance = IERC20(shortToken_).balanceOf(address(this));
        underlyingBalance = IERC20(underlyingToken_).balanceOf(address(this));

        _updateCaches(shortBalance, underlyingBalance);
        emit Burn(msg.sender, shortAmount, underlyingAmount, receiver);
    }

    // sells short for underlying.
    // isSellingShort = true
    function swapShortToUnderlying(uint amountShortIn, address receiver) external nonReentrant returns (uint, bool) {
        require(amountShortIn > 0, 'PrimitiveV2: AMOUNT_ZERO');
        (uint cache0, uint cache1) = getCaches();
        uint shortBalance;
        uint underlyingBalance;
        // get quantity of underlying paid
        uint quote = _quote(amountShortIn, true);
        // pay out underlying
        _safeTransfer(underlyingToken, receiver, quote);
        shortBalance = IERC20(shortToken).balanceOf(address(this));
        underlyingBalance = IERC20(underlyingToken).balanceOf(address(this));
        // short
        uint amount0In = shortBalance > cache0 ? shortBalance - cache0 : 0;
        // underlying
        uint amount1In = underlyingBalance > cache1 - quote ? underlyingBalance - (cache1 - quote) : 0;
        require(amount0In > 0 || amount1In > 0, 'PrimitiveV2: RETURNED_AMOUNT_ZERO');
        // make sure underlying payout is either returned with liquidity fee
        // or `amountShortIn` of short tokens was paid
        // assert invariant
        require(amount0In >= amountShortIn || amount1In >= quote.add(quote.div(liquidityFee)));
        // update caches
        _updateCaches(shortBalance, underlyingBalance);
        emit SwapFromShort(msg.sender, amountShortIn, quote, receiver);
    }

    // buys short for underlying
    // isSellingShort = false
    function swapUnderlyingToShort(uint amountShortOut, address receiver) external nonReentrant returns (uint, bool) {
        require(amountShortOut > 0, 'PrimitiveV2: AMOUNT_ZERO');
        (uint cache0, uint cache1) = getCaches();
        uint shortBalance;
        uint underlyingBalance;
        // get quantity of underlying paid
        uint quote = _quote(amountShortOut, false);
        // pay out short
        _safeTransfer(shortToken, receiver, amountShortOut);
        shortBalance = IERC20(shortToken).balanceOf(address(this));
        underlyingBalance = IERC20(underlyingToken).balanceOf(address(this));
        // short
        uint amount0In = shortBalance > cache0 - amountShortOut ? shortBalance - (cache0 - amountShortOut) : 0;
        // underlying
        uint amount1In = underlyingBalance > cache1  ? underlyingBalance - cache1 : 0;
        require(amount0In > 0 || amount1In > 0, 'PrimitiveV2: RETURNED_AMOUNT_ZERO');
        // make sure underlying payout is either returned with liquidity fee
        // or `amountShortOut` of short tokens was paid
        // assert invariant
        require(amount0In >= amountShortOut.add(amountShortOut.div(liquidityFee)) || amount1In >= quote, "PrimitiveV2: INVARIANT");
        // update caches
        _updateCaches(shortBalance, underlyingBalance);
        emit SwapToShort(msg.sender, amountShortOut, quote, receiver);
    }

    // sell: adding amount for numerator indicates selling short tokens and increasing the short cache
    // buy: subtracting amount for numerator indicates buying short tokens and reducing short cache
    function _getExchangeRate(uint shortAmount, bool isSellingShort) internal view returns (uint32, bool) {
        if(shortCache == 0 || underlyingCache == 0 || (shortAmount > shortCache && !isSellingShort)) {
            return (0, false);
        }
        // (shortCache +/- shortAmount) / shortCache + underlyingCache
        uint proportion = getExecutedProportion(shortAmount, isSellingShort);
        // (p / 1 - p)
        proportion = proportion.mul(1e18).div(uint(1e18).sub(proportion));

        // ln(p / 1 - p)
        (int256 logarithmProportion, bool success) = _ln(proportion);
        if(!success) return (0, false);

        int256 exchangeRate = ((logarithmProportion - LN_1E18) / scalar) + anchor;
        // Check if valid uint32.
        if (exchangeRate < 0 || exchangeRate > MAX_UINT_32) {
            return (0, false);
        } else {
            return (uint32(exchangeRate), true);
        }
    }

    function _getSpotExchangeRate() internal view returns (uint32, bool) {
        if(shortCache == 0 || underlyingCache == 0) {
            return (0, false);
        }
        // (shortCache +/- shortAmount) / shortCache + underlyingCache
        uint proportion = getProportion();
        // (p / 1 - p)
        proportion = proportion.mul(1e18).div(uint(1e18).sub(proportion));

        // ln(p / 1 - p)
        (int256 logarithmProportion, bool success) = _ln(proportion);
        if(!success) return (0, false);

        int256 exchangeRate = ((logarithmProportion - LN_1E18) / scalar) + anchor;
        // Check if valid uint32.
        if (exchangeRate < 0 || exchangeRate > MAX_UINT_32) {
            return (0, false);
        } else {
            return (uint32(exchangeRate), true);
        }
    }


    // sell: adding amount for numerator indicates selling short tokens and increasing the short cache
    // buy: subtracting amount for numerator indicates buying short tokens and increasing the underlying cache
    function _quote(uint size, bool isSellingShort) internal view returns (uint) {
        uint executedRate = getExecutedExchangeRate(size, isSellingShort);
        if(executedRate == 0) return 0;
        uint underlyingAmount = (size.mul(1e9).div(executedRate));
        return underlyingAmount;
    }

    // calculates the ln(p / (1 - p)) and returns a uint64 and boolean
    function _ln(uint proportion) internal pure returns(uint64, bool) {
        if(proportion > MAX64) return (0, false);

        int128 convertedProportion = ABDKMath64x64.fromUInt(proportion);
        if(convertedProportion <= 0) return (0, false);

        int256 logarithm = ABDKMath64x64.ln(convertedProportion);
        int256 shifted = (logarithm * PRECISION_64x64) >> 64;

        // check for overflows
        if(shifted < ABDKMath64x64.MIN_64x64 || shifted > ABDKMath64x64.MAX_64x64) {
            return (0, false);
        }
        
        return (ABDKMath64x64.toUInt(int128(shifted)), true);
    }

    // a trade selling short for underlying / buying underlying for short. short -> under
    function getShortToUnderlyingQuote(uint shortAmount) public view returns (uint) {
        return _quote(shortAmount, true);
    }

    // a trade buying short for underlying / selling underlying for short. under -> short
    function getUnderlyingToShortQuote(uint shortAmount) public view returns (uint) {
        return _quote(shortAmount, false);
    }

    // shortCache / (shortCache + underlyingCache)
    function getProportion() public view returns (uint) {
        if(shortCache == 0 && underlyingCache == 0) return 0;
        return shortCache.mul(1e18).div(shortCache.add(underlyingCache));
    }

    // selling short: add
    // buying short: subtract
    // ( shortCache +/- amount ) / ( shortCache + underlyingCache )
    function getExecutedProportion(uint shortAmount, bool isSellingShort) public view returns (uint) {
        uint numerator = isSellingShort ? shortCache.add(shortAmount): shortCache.sub(shortAmount);
        uint denominator = shortCache.add(underlyingCache);
        return numerator.mul(1e18).div(denominator);
    }

    // exchangeRate +/- liquidity fee
    // selling short: add
    // buying short: subtract
    function getExecutedExchangeRate(uint shortAmount, bool isSellingShort) public view returns (uint) {
        (uint32 rate, bool success) = _getExchangeRate(shortAmount, isSellingShort);
        if(!success) return 0;
        uint liquidityFee_ = liquidityFee;
        return isSellingShort ? rate + liquidityFee_ : rate - liquidityFee_;
    }

    // shortTokens / exchangeRate = underlyingTokens
    // 1 / exchangeRate = underlyingTokens / shortTokens
    function getSpotExchangeRate() public view returns (uint) {
        (uint32 rate, bool success) = _getSpotExchangeRate();
        if(!success) return 0;
        return rate;
    }

    function getSpotRate() public view returns (uint) {
        (uint32 spotExchangeRate, bool success) = _getSpotExchangeRate();
        if(spotExchangeRate == 0) return 0;
        uint inverse = uint(1e18).div(spotExchangeRate);
        console.log(spotExchangeRate, inverse);
        return uint256(PRECISION - inverse);
    }
}