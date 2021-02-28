const hre = require('hardhat')
const ethers = hre.ethers
const { parseEther, formatEther, formatUnits } = ethers.utils
const { expect } = require('chai')
const { parseUnits } = require('ethers/lib/utils')

const SCALE = 'gwei'
const PRECISION = parseUnits('1', SCALE)
const ACCURACY = 1e-4 // need to analyze further
const DEFAULT_PARAMS = {
  scalar: 100,
  anchor: 1.01e9,
  fee: '0.00025',
}

const getInstance = async (name, args) => {
  const contract = await ethers.getContractFactory(name)
  const pool = await contract.deploy(...args)
  return pool
}

const calculateP = (shortCache, underlyingCache) => {
  return formatEther(shortCache.mul(parseEther('1')).div(shortCache.add(underlyingCache)))
}

const calculateTradeP = (size, shortCache, underlyingCache, isSellingShort) => {
  const numerator = isSellingShort ? shortCache.add(size) : shortCache.sub(size)
  return formatEther(numerator.mul(parseEther('1')).div(shortCache.add(underlyingCache)))
}

const getExchangeRate = (size, scalar, anchor, fee, shortCache, underlyingCache, isSellingShort) => {
  const proportion = calculateTradeP(size, shortCache, underlyingCache, isSellingShort)
  const lnProportion = Math.log(parseFloat(proportion) / (1 - parseFloat(proportion)))
  fee = isSellingShort ? +fee : +fee * -1
  const rate = lnProportion / parseFloat(scalar) + parseFloat(formatRate(anchor)) + fee
  //console.log({ rate, scalar, anchor, fee })
  return +rate.toPrecision(10)
}

const getSpotExchangeRate = (scalar, anchor, shortCache, underlyingCache) => {
  const proportion = calculateP(shortCache, underlyingCache)
  const lnProportion = Math.log(parseFloat(proportion) / (1 - parseFloat(proportion)))
  const rate = lnProportion / parseFloat(scalar) + parseFloat(formatRate(anchor))
  return +rate.toPrecision(10)
}

const getSpotRate = (exchangeRate) => {
  return PRECISION.sub(parseEther('1').div(parseUnits(exchangeRate.toString(), SCALE)))
}

const quote = (size, exchangeRate) => {
  const amount = parseFloat(formatEther(size)) / exchangeRate
  return amount
}

const logBalance = async (token, account) => {
  const bal = await token.balanceOf(account)
  const symbol = await token.symbol()
  console.log(`
  Balance of ${symbol} is ${formatEther(bal)}
  `)
  return bal
}

const logCaches = async (pool) => {
  const [cache0, cache1] = await pool.getCaches()
  console.log(`
  ${formatEther(cache0)} short ${formatEther(cache1)} under
  `)
  return [cache0, cache1]
}

const formatRate = (rate) => {
  return parseFloat(formatUnits(rate, SCALE))
}

const parseRate = (rate) => {
  return parseFloat(parseUnits(rate, SCALE))
}

const runTrade = async (initialParams) => {
  // Deploy the pool
  const pool = await getInstance('PrimitiveAmm', [])
  // Get the initial pool cache sizes
  const initialShort = initialParams.shortCache
  const initialUnderlying = initialParams.underlyingCache
  // Deploy the tokens
  const shortToken = await getInstance('ERC20', [initialShort])
  const underlyingToken = await getInstance('ERC20', [initialUnderlying])
  const short = shortToken.address
  const underlying = underlyingToken.address
  // Transfer the tokens to the pool to initialize it.
  await shortToken.transfer(pool.address, initialShort)
  await underlyingToken.transfer(pool.address, initialUnderlying)
  // Initialize it
  await pool.initialize(short, underlying, initialParams.scalar, initialParams.anchor)
  await pool.mint(initialParams.to)
  // Check that the caches match the passed in values
  expect(await pool.shortCache()).to.equal(initialShort)
  expect(await pool.underlyingCache()).to.equal(initialUnderlying)

  const amount = initialParams.tradeSize
  // get the off-chain values
  const expProportion = calculateP(initialShort, initialUnderlying)
  const expTradeP = calculateTradeP(amount, initialShort, initialUnderlying, initialParams.isSellingShort)
  const expBuyRate = getExchangeRate(
    amount,
    initialParams.scalar,
    initialParams.anchor,
    initialParams.fee,
    initialShort,
    initialUnderlying,
    false
  )
  const expSellRate = getExchangeRate(
    amount,
    initialParams.scalar,
    initialParams.anchor,
    initialParams.fee,
    initialShort,
    initialUnderlying,
    true
  )
  const expUnderlyingToShort = quote(amount, expBuyRate)
  const expShortToUnderlying = quote(amount, expSellRate)
  const expSpotExchangeRate = getSpotExchangeRate(
    initialParams.scalar,
    initialParams.anchor,
    initialShort,
    initialUnderlying
  )
  const expSpotRate = getSpotRate(expSpotExchangeRate)
  // get the on-chain values
  const proportion = await pool.getProportion()
  const tradeProportion = initialParams.isSellingShort
    ? await pool.getShortProportionIn(amount)
    : await pool.getShortProportionOut(amount)
  const buyRate = await pool.getExchangeRateOut(amount)
  const sellRate = await pool.getExchangeRateIn(amount)
  const shortToUnderlying = await pool.getShortToUnderlyingQuote(amount)
  const underlyingToShort = await pool.getUnderlyingToShortQuote(amount)
  const fee = await pool.liquidityFee()
  const slippage = parseFloat(formatEther(underlyingToShort)) / parseFloat(formatEther(initialParams.tradeSize)) - 1
  const spotExchangeRate = await pool.getSpotExchangeRate()
  const spotRate = await pool.getSpotRate()
  // get post-trade values
  const postTradeShortCache = initialParams.isSellingShort ? initialShort.add(amount) : initialShort.sub(amount)
  const postTradeUnderlyingCache = initialParams.isSellingShort
    ? initialUnderlying.sub(parseEther(expShortToUnderlying.toString()))
    : initialUnderlying.add(parseEther(expUnderlyingToShort.toString()))
  const postTradeExchangeProportion = calculateTradeP(
    amount,
    postTradeShortCache,
    postTradeUnderlyingCache,
    initialParams.isSellingShort
  )

  // run the trade
  if (initialParams.isSellingShort) {
    // send short to pool to sell short
    await shortToken.mint(pool.address, amount)
    await pool.swapShortToUnderlying(amount, initialParams.to)
  } else {
    // send underlying to pool to buy short
    await underlyingToken.mint(pool.address, parseEther(expUnderlyingToShort.toString()))
    await pool.swapUnderlyingToShort(amount, initialParams.to)
  }
  const [cache0, cache1] = await pool.getCaches()
  const lpTokenBalance = await pool.balanceOf(initialParams.to)
  console.log(
    `
      lpTokenBalance: ${formatEther(lpTokenBalance)}
      poolSizeShort: ${formatEther(initialShort)}
      poolSizeUnder: ${formatEther(initialUnderlying)}
      tradeSize: ${initialParams.isSellingShort ? '-' : '+'} ${formatEther(initialParams.tradeSize)} short
      proportion: ${formatEther(proportion)}
      tradeProportion: ${formatEther(tradeProportion)}
      buyRate: ${formatUnits(buyRate, SCALE)}
      sellRate: ${formatUnits(sellRate, SCALE)}
      anchor: ${formatRate(initialParams.anchor)}
      fee: ${formatUnits(fee, SCALE)}
      shortToUnder: ${formatEther(shortToUnderlying)}
      underlyingToShort: ${formatEther(underlyingToShort)}
      slippage: ${slippage.toString()}
      postTradeShortCache: ${formatEther(cache0)}
      postTradeUnderlyingCache: ${formatEther(cache1)}
      postTradeP: ${postTradeExchangeProportion}
      spotPremium: ${formatRate(spotRate)}
      `
  )

  // validate the returned accounting
  expect(formatEther(proportion)).to.equal(expProportion)
  expect(formatEther(tradeProportion)).to.equal(expTradeP)
  expect(parseFloat(formatUnits(buyRate, SCALE))).to.be.closeTo(parseFloat(expBuyRate), ACCURACY)
  expect(parseFloat(formatUnits(sellRate, SCALE))).to.be.closeTo(parseFloat(expSellRate), ACCURACY)
  expect(formatUnits(fee, SCALE)).to.equal(initialParams.fee)
  expect(parseFloat(formatEther(underlyingToShort))).to.be.closeTo(parseFloat(expUnderlyingToShort), ACCURACY)
  expect(parseFloat(formatEther(shortToUnderlying))).to.be.closeTo(parseFloat(expShortToUnderlying), ACCURACY)
  expect(parseFloat(formatEther(cache0))).to.be.closeTo(parseFloat(formatEther(postTradeShortCache)), ACCURACY)
  expect(parseFloat(formatEther(cache1))).to.be.closeTo(parseFloat(formatEther(postTradeUnderlyingCache)), ACCURACY)
  expect(formatRate(spotRate)).to.be.closeTo(formatRate(expSpotRate), ACCURACY)
}

describe('PrimitiveAmm', function () {
  let signers, Alice

  before(async () => {
    signers = await ethers.getSigners()
    Alice = signers[0].address
  })
  it('getExchangeRate()', async function () {
    const shortCache = parseEther('100000')
    const underlyingCache = parseEther('100000')
    const size = parseEther('1000')
    const initialParams = Object.assign(DEFAULT_PARAMS, {
      shortCache: shortCache,
      underlyingCache: underlyingCache,
      tradeSize: size,
      isSellingShort: false,
      to: Alice,
    })

    await runTrade(initialParams)
  })

  it('10% trade', async function () {
    const shortCache = parseEther('100000')
    const underlyingCache = parseEther('100000')
    const size = parseEther('10000')
    const initialParams = Object.assign(DEFAULT_PARAMS, {
      shortCache: shortCache,
      underlyingCache: underlyingCache,
      tradeSize: size,
      isSellingShort: false,
      to: Alice,
    })

    await runTrade(initialParams)
  })

  it('swapShortToUnderlying() & swapUnderlyingToShort()', async function () {
    const shortCache = parseEther('100000')
    const underlyingCache = parseEther('100000')
    const shortToken = await getInstance('ERC20', [shortCache])
    const underlyingToken = await getInstance('ERC20', [underlyingCache])
    const short = shortToken.address
    const underlying = underlyingToken.address
    const size = parseEther('10000')
    const initialParams = Object.assign(DEFAULT_PARAMS, {
      shortCache: shortCache,
      underlyingCache: underlyingCache,
      tradeSize: size,
      isSellingShort: false,
      to: Alice,
    })
    const pool = await getInstance('PrimitiveAmm', [])
    await pool.deployed()
    await shortToken.transfer(pool.address, shortCache)
    await underlyingToken.transfer(pool.address, underlyingCache)
    await pool.initialize(short, underlying, initialParams.scalar, 1)
    await pool.mint(Alice)

    await runTrade(initialParams)
    await runTrade(Object.assign(initialParams, { isSellingShort: true }))
  })

  it('swapShortToUnderlying() & burn', async function () {
    const shortCache = parseEther('100000')
    const underlyingCache = parseEther('100000')
    const shortToken = await getInstance('ERC20', [shortCache])
    const underlyingToken = await getInstance('ERC20', [underlyingCache])
    const short = shortToken.address
    const underlying = underlyingToken.address
    const size = parseEther('10000')
    const initialParams = Object.assign(DEFAULT_PARAMS, {
      shortCache: shortCache,
      underlyingCache: underlyingCache,
      tradeSize: size,
      isSellingShort: false,
      to: Alice,
    })
    const pool = await getInstance('PrimitiveAmm', [])
    await pool.deployed()
    await shortToken.transfer(pool.address, shortCache)
    await underlyingToken.transfer(pool.address, underlyingCache)
    await pool.initialize(short, underlying, initialParams.scalar, 1)
    await pool.mint(Alice)

    await runTrade(initialParams)
    const lpBal = await logBalance(pool, Alice)
    const totalSupply = await pool.totalSupply()
    let [cache0, cache1] = await logCaches(pool)
    const expCache0 = cache0.sub(lpBal.mul(cache0).div(totalSupply))
    const expCache1 = cache1.sub(lpBal.mul(cache1).div(totalSupply))
    await pool.transfer(pool.address, await pool.balanceOf(Alice))
    await pool.burn(Alice)
    const bal = await logBalance(pool, Alice)
    ;[cache0, cache1] = await logCaches(pool)

    expect(parseFloat(formatEther(bal))).to.equal(0)
    expect(formatEther(cache0)).to.equal(formatEther(expCache0))
    expect(formatEther(cache1)).to.equal(formatEther(expCache1))
  })

  it('getSpotRate()', async function () {
    const shortCache = parseEther('100000')
    const underlyingCache = parseEther('90000')
    const shortToken = await getInstance('ERC20', [shortCache])
    const underlyingToken = await getInstance('ERC20', [underlyingCache])
    const short = shortToken.address
    const underlying = underlyingToken.address
    const size = parseEther('10000')
    const initialParams = Object.assign(DEFAULT_PARAMS, {
      anchor: 1e9,
      shortCache: shortCache,
      underlyingCache: underlyingCache,
      tradeSize: size,
      isSellingShort: false,
      to: Alice,
    })
    const pool = await getInstance('PrimitiveAmm', [])
    await shortToken.transfer(pool.address, shortCache)
    await underlyingToken.transfer(pool.address, underlyingCache)
    await pool.initialize(short, underlying, initialParams.scalar, initialParams.anchor)
    await pool.mint(Alice)

    const spotExchangeRate = await pool.getSpotExchangeRate()
    const spotRate = await pool.getSpotRate()
    console.log(spotRate.toString())
    console.log(`
      spotExRate: ${formatRate(spotExchangeRate)}
      spotRate: ${formatRate(spotRate)}
    `)

    await runTrade(initialParams)
  })
})
