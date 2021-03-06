// SPDX-License-Identifier: Unlicense
pragma solidity 0.7.6;

// OZ
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

// UNI
import "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3MintCallback.sol";
import "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3SwapCallback.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import "@uniswap/v3-core/contracts/libraries/SqrtPriceMath.sol";
import "@uniswap/v3-periphery/contracts/libraries/LiquidityAmounts.sol";
import "@uniswap/v3-periphery/contracts/libraries/PositionKey.sol";

// Yearn
import "./interfaces/YearnVaultAPI.sol";

// Our Own
import "./utils/Governable.sol";

// Code borrowed and modified from https://github.com/charmfinance/alpha-vaults-contracts/blob/main/contracts/AlphaVault.sol

/**
 * @title   Sigma Vault
 * @notice  A vault which provides liquidity on Uniswap V3 and deposits rest on yearn
 */

contract SigmaVault is
    IUniswapV3MintCallback,
    IUniswapV3SwapCallback,
    ERC20,
    ReentrancyGuard,
    Governable,
    Pausable
{
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    event Deposit(
        address indexed sender,
        address indexed to,
        uint256 shares,
        uint256 amount0,
        uint256 amount1,
        uint256 totalSupply
    );

    event Withdraw(
        address indexed sender,
        address indexed to,
        uint256 shares,
        uint256 amount0,
        uint256 amount1,
        uint256 totalSupply
    );

    event Rebalance(
        int24 tick_lower,
        int24 tick_upper,
        uint256 uniswapDeposit0,
        uint256 uniswapDeposit1,
        uint256 lvDeposit0,
        uint256 lvDeposit1,
        uint256 accruedProtocolFees0,
        uint256 accruedProtocolFees1
    );

    IUniswapV3Pool public immutable pool;
    IERC20 public immutable token0;
    IERC20 public immutable token1;
    int24 public immutable tickSpacing;

    struct lv {
        uint256 yShares0;
        uint256 yShares1;
        uint256 deposited0;
        uint256 deposited1;
    }

    VaultAPI public lendVault0;
    VaultAPI public lendVault1;
    uint256 public lvTotalDeposited0;
    uint256 public lvTotalDeposited1;

    uint256 public protocolFee;
    uint256 public swapExcessIgnore;
    uint256 public maxTotalSupply;
    address public strategy;

    uint256 public lv0Decimals; // Have not made 8 intentially as Yearn stores it in 256
    uint256 public lv1Decimals;
    uint256 public accruedProtocolFees0;
    uint256 public accruedProtocolFees1;
    int24 public tick_lower;
    int24 public tick_upper;
    uint64 public thresholdForLV0Deposit;
    uint64 public thresholdForLV1Deposit;
    uint8 public buffer;

    /**
     * @dev After deploying, strategy needs to be set via `setStrategy()`
     * @param _pool Underlying Uniswap V3 pool
     * @param _lendVault0 address of lending vault 0
     * @param _lendVault1 address of lending vault 1
     * @param _protocolFee Protocol fee expressed as multiple of 1e-6
     * @param _swapExcessIgnore, percentage excess ignored, in terms of /1e-6, so if its 5000, it will be 0.5%
     * @param _maxTotalSupply Cap on total supply
     * @param _thresholdForLV0Deposit, Deposit into lendingVault0, only if assetsRemain0 > _thresholdForLV0Deposit
     * @param _thresholdForLV1Deposit, Deposit into lendingVault1, only if assetsRemain1 > _thresholdForLV1Deposit
     * @param _buffer, amount to be added, while calculating shares to withdraw from lending vaults
     */
    constructor(
        address _pool,
        address _lendVault0,
        address _lendVault1,
        uint256 _protocolFee,
        uint256 _swapExcessIgnore,
        uint256 _maxTotalSupply,
        uint64 _thresholdForLV0Deposit,
        uint64 _thresholdForLV1Deposit,
        uint8 _buffer
    ) ERC20("Sigma Vault", "SV") {
        require(_protocolFee < 1e6, "protocolFee");

        pool = IUniswapV3Pool(_pool);
        token0 = IERC20(IUniswapV3Pool(_pool).token0());
        token1 = IERC20(IUniswapV3Pool(_pool).token1());
        tickSpacing = IUniswapV3Pool(_pool).tickSpacing();

        lendVault0 = VaultAPI(_lendVault0);
        lendVault1 = VaultAPI(_lendVault1);
        lv0Decimals = lendVault0.decimals();
        lv1Decimals = lendVault1.decimals();
        thresholdForLV0Deposit = _thresholdForLV0Deposit;
        thresholdForLV1Deposit = _thresholdForLV1Deposit;
        buffer = _buffer;
        protocolFee = _protocolFee;
        swapExcessIgnore = _swapExcessIgnore;
        maxTotalSupply = _maxTotalSupply;
    }

    /**
     * @notice Deposits tokens in proportion to the vault's current holdings.
     * @dev These tokens sit in the vault and are not used for liquidity on
     * Uniswap or deposited in yearn until the next rebalance.
     * @param amount0Desired Max amount of token0 to deposit
     * @param amount1Desired Max amount of token1 to deposit
     * @param amount0Min Revert if resulting `amount0` is less than this
     * @param amount1Min Revert if resulting `amount1` is less than this
     * @param to Recipient of shares
     * @return shares Number of shares minted
     * @return amount0 Amount of token0 deposited
     * @return amount1 Amount of token1 deposited
     */
    function deposit(
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min,
        address to
    )
        external
        nonReentrant
        whenNotPaused
        returns (
            uint256 shares,
            uint256 amount0,
            uint256 amount1
        )
    {
        require(
            amount0Desired > 0 || amount1Desired > 0,
            "amount0Desired or amount1Desired"
        );
        require(to != address(0) && to != address(this), "to");

        // Poke positions so vault's current holdings are up-to-date
        _poke(tick_lower, tick_upper);

        // Calculate amounts proportional to vault's holdings
        (shares, amount0, amount1) = _calcSharesAndAmounts(
            amount0Desired,
            amount1Desired
        );

        require(shares > 0, "shares");
        require(amount0 >= amount0Min, "amount0Min");
        require(amount1 >= amount1Min, "amount1Min");
        require(
            (totalSupply()).add(shares) <= maxTotalSupply,
            "maxTotalSupply"
        );

        // Pull in tokens from sender
        if (amount0 > 0)
            token0.safeTransferFrom(msg.sender, address(this), amount0);
        if (amount1 > 0)
            token1.safeTransferFrom(msg.sender, address(this), amount1);

        // Mint shares to recipient
        _mint(to, shares);
        emit Deposit(msg.sender, to, shares, amount0, amount1, totalSupply());
    }

    /// @dev Do zero-burns to poke a position on Uniswap so earned fees are
    /// updated. Should be called if total amounts needs to include up-to-date
    /// fees.
    function _poke(int24 tickLower, int24 tickUpper) internal {
        (uint128 liquidity, , , , ) = _position(tickLower, tickUpper);
        if (liquidity > 0) {
            pool.burn(tickLower, tickUpper, 0);
        }
    }

    /// @dev Calculates the largest possible `amount0` and `amount1` such that
    /// they're in the same proportion as total amounts, but not greater than
    /// `amount0Desired` and `amount1Desired` respectively.
    function _calcSharesAndAmounts(
        uint256 amount0Desired,
        uint256 amount1Desired
    )
        internal
        returns (
            uint256 shares,
            uint256 amount0,
            uint256 amount1
        )
    {
        (uint256 total0, uint256 total1) = getTotalAmounts();

        uint256 _totalSupply = totalSupply();
        // If total supply > 0, vault can't be empty
        assert(_totalSupply == 0 || total0 > 0 || total1 > 0);

        if (_totalSupply == 0) {
            // For first deposit, restrict to 50-50

            // had to do external call as there is no space left in this contract, to store twap duration and function for twap
            // As this is going to be called only once in lifetime of contract, imo its fair tradeoff

            (bool success, bytes memory data) = strategy.call(
                abi.encodeWithSignature("getTwap()")
            );
            require(success, "External call for twap failed");
            int24 twapTick = abi.decode(data, (int24));
            uint160 sqrtPriceX96 = TickMath.getSqrtRatioAtTick(twapTick);
            uint256 priceX96 = FullMath.mulDiv(
                sqrtPriceX96,
                sqrtPriceX96,
                FixedPoint96.Q96
            );
            uint256 amount0DesiredValueIn1 = FullMath.mulDiv(
                amount0Desired,
                priceX96,
                FixedPoint96.Q96
            );

            if (amount0DesiredValueIn1 > amount1Desired) {
                // token0 is in excess
                amount0 = FullMath.mulDiv(
                    amount1Desired,
                    FixedPoint96.Q96,
                    priceX96
                );
                amount1 = amount1Desired;
            } else if (amount0DesiredValueIn1 < amount1Desired) {
                //token1 is in excess
                amount0 = amount0Desired;
                amount1 = FullMath.mulDiv(
                    amount0Desired,
                    priceX96,
                    FixedPoint96.Q96
                );
            } else {
                amount0 = amount0Desired;
                amount1 = amount1Desired;
            }
            shares = Math.max(amount0, amount1);
        } else if (total0 == 0) {
            amount1 = amount1Desired;
            shares = (amount1.mul(_totalSupply)).div(total1);
        } else if (total1 == 0) {
            amount0 = amount0Desired;
            shares = (amount0.mul(_totalSupply)).div(total0);
        } else {
            uint256 cross = Math.min(
                amount0Desired.mul(total1),
                amount1Desired.mul(total0)
            );
            require(cross > 0, "cross");

            // Round up amounts
            amount0 = ((cross.sub(1)).div(total1)).add(1);
            amount1 = ((cross.sub(1)).div(total0)).add(1);
            shares = ((cross.mul(_totalSupply)).div(total0)).div(total1);
        }
    }

    /**
     * @notice Updates vault's positions. Can only be called by the strategy.
     */
    function rebalance(uint8 uniswapShare)
        external
        whenNotPaused
        nonReentrant
        onlyStrategy
    {
        uint256 totalAssets0;
        uint256 totalAssets1;

        uint256 virtualAmount0; // Withdrawable from lending vault0
        uint256 virtualAmount1; // Withdrawable from lending vault1

        // Step 1 : Calculate Total Assets
        // Withdraw Everything from uni
        // Withdraw only on need basis from lending vaults

        {
            // Uniswap
            (uint128 totalLiquidity, , , , ) = _position(
                tick_lower,
                tick_upper
            );
            (, , uint256 uniGain0, uint256 uniGain1) = _uniBurnAndCollect(
                totalLiquidity
            );
            _accureFees(uniGain0, uniGain1);

            // Lending Vaults
            (
                ,
                ,
                uint256 virtualFeeProtocol0,
                uint256 virtualFeeProtocol1,
                uint256 _totalVirtualAmount0,
                uint256 _totalVirtualAmount1
            ) = _getLvAmounts();

            virtualAmount0 = _totalVirtualAmount0;
            virtualAmount1 = _totalVirtualAmount1;

            accruedProtocolFees0 = accruedProtocolFees0.add(
                virtualFeeProtocol0
            );
            accruedProtocolFees1 = accruedProtocolFees1.add(
                virtualFeeProtocol1
            );

            // Withdraw from lending vaults if current balance is not sufficient to cover pfees earned on gain from lending vaults
            virtualAmount0 = _WithdrawIfNecessLV0(
                virtualFeeProtocol0,
                virtualAmount0
            );
            virtualAmount1 = _WithdrawIfNecessLV1(
                virtualFeeProtocol1,
                virtualAmount1
            );

            totalAssets0 = getBalance0().add(virtualAmount0);
            totalAssets1 = getBalance1().add(virtualAmount1);
        }

        // Step 2 : Swap Excess
        (virtualAmount0, virtualAmount1) = _swapExcess(
            totalAssets0,
            totalAssets1,
            virtualAmount0,
            virtualAmount1
        );

        // Step 3 : Mint Liq

        totalAssets0 = getBalance0().add(virtualAmount0);
        totalAssets1 = getBalance1().add(virtualAmount1);

        (uint160 sqrtPriceCurrent, int24 tick, , , , , ) = pool.slot0();

        uint160 infinity = uint160(uint256(1 << 160) - 1);

        uint128 liq0 = LiquidityAmounts.getLiquidityForAmount0(
            sqrtPriceCurrent,
            infinity,
            totalAssets0
        );
        uint128 liq1 = LiquidityAmounts.getLiquidityForAmount1(
            0,
            sqrtPriceCurrent,
            totalAssets1
        );

        uint128 liq = liq0 > liq1 ? liq1 : liq0;

        uint256 uniswapDeposit0 = (totalAssets0.mul(uniswapShare)).div(100);
        uint256 uniswapDeposit1 = (totalAssets1.mul(uniswapShare)).div(100);

        uint160 sqrtPriceLower = SqrtPriceMath
            .getNextSqrtPriceFromAmount1RoundingDown(
                sqrtPriceCurrent,
                liq,
                uniswapDeposit1,
                false
            );

        uint160 sqrtPriceUpper = SqrtPriceMath
            .getNextSqrtPriceFromAmount0RoundingUp(
                sqrtPriceCurrent,
                liq,
                uniswapDeposit0,
                false
            );

        tick_lower = _adjustTick(TickMath.getTickAtSqrtRatio(sqrtPriceLower));
        tick_upper = _adjustTick(TickMath.getTickAtSqrtRatio(sqrtPriceUpper));

        _checkRange(tick_lower, tick_upper);

        // If +, - possible
        // And to check price is not too close to min/max allowed by Uniswap. Price
        // shouldn't be this extreme unless something was wrong with the pool.

        require(
            tick > TickMath.MIN_TICK + tick_upper - tick + tickSpacing,
            "tick too low"
        );
        require(
            tick < TickMath.MAX_TICK - (tick_lower - tick) - tickSpacing,
            "tick too high"
        );

        (uint256 amount0Req, uint256 amount1Req) = _amountsForLiquidity(
            tick_lower,
            tick_upper,
            liq
        );
        virtualAmount0 = _WithdrawIfNecessLV0(amount0Req, virtualAmount0);
        virtualAmount1 = _WithdrawIfNecessLV1(amount1Req, virtualAmount1);

        _mintLiquidity(tick_lower, tick_upper, liq);

        lvTotalDeposited0 = virtualAmount0;
        lvTotalDeposited1 = virtualAmount1;

        // Step 4 : If anything is remaining deposit that on yearn
        {
            uint256 totalAssets0Remain = getBalance0();
            if (totalAssets0Remain > thresholdForLV0Deposit) {
                lvTotalDeposited0 = lvTotalDeposited0.add(totalAssets0Remain);
                token0.safeApprove(address(lendVault0), totalAssets0Remain);
                lendVault0.deposit(totalAssets0Remain);
            }

            uint256 totalAssets1Remain = getBalance1();
            if (totalAssets1Remain > thresholdForLV1Deposit) {
                lvTotalDeposited1 = lvTotalDeposited1.add(totalAssets1Remain);
                token1.safeApprove(address(lendVault1), totalAssets1Remain);
                lendVault1.deposit(totalAssets1Remain);
            }
        }
        emit Rebalance(
            tick_lower,
            tick_upper,
            amount0Req,
            amount1Req,
            lvTotalDeposited0,
            lvTotalDeposited1,
            accruedProtocolFees0,
            accruedProtocolFees1
        );
    }

    function _swapExcess(
        uint256 totalAssets0,
        uint256 totalAssets1,
        uint256 virtualAmount0,
        uint256 virtualAmount1
    ) internal returns (uint256, uint256) {
        // Swap Excess
        (uint160 sqrtPriceCurrent, , , , , , ) = pool.slot0();
        uint256 priceX96 = FullMath.mulDiv(
            sqrtPriceCurrent,
            sqrtPriceCurrent,
            FixedPoint96.Q96
        );
        uint256 total0ValueIn1 = FullMath.mulDiv(
            totalAssets0,
            priceX96,
            FixedPoint96.Q96
        );
        uint256 total1ValueIn0 = FullMath.mulDiv(
            totalAssets1,
            FixedPoint96.Q96,
            priceX96
        );

        if (total0ValueIn1 > totalAssets1) {
            //token0 is in excess
            //Swap excess token0 into token1
            virtualAmount0 = _swap0to1(
                total0ValueIn1,
                totalAssets0,
                totalAssets1,
                priceX96,
                sqrtPriceCurrent,
                virtualAmount0
            );
        } else if (total1ValueIn0 > totalAssets0) {
            //token1 is in excess
            //Swap excess token1 into token0
            virtualAmount1 = _swap1to0(
                total1ValueIn0,
                totalAssets1,
                totalAssets0,
                priceX96,
                sqrtPriceCurrent,
                virtualAmount1
            );
        }

        return (virtualAmount0, virtualAmount1);
    }

    function _swap0to1(
        uint256 total0ValueIn1,
        uint256 totalAssets0,
        uint256 totalAssets1,
        uint256 priceX96,
        uint256 sqrtPriceX96,
        uint256 virtualAmount0
    ) internal returns (uint256) {
        uint24 fee = pool.fee();
        //totalExcess0InTermsOf1= total0ValueIn1.sub(totalAssets1)
        uint256 totalExcess0 = FullMath.mulDiv(
            total0ValueIn1.sub(totalAssets1),
            FixedPoint96.Q96,
            priceX96
        );
        uint256 excess0Ignore = FullMath.mulDiv(
            totalAssets0,
            swapExcessIgnore,
            1e6
        );

        if (totalExcess0 > excess0Ignore) {
            uint256 swapAmount = FullMath.mulDiv(
                totalExcess0,
                1e6,
                2 * (1e6 - fee)
            );
            virtualAmount0 = _WithdrawIfNecessLV0(swapAmount, virtualAmount0);
            pool.swap(
                address(this),
                true,
                int256(swapAmount),
                uint160(((uint256(sqrtPriceX96)).mul(90)).div(100)),
                ""
            );
        }

        return virtualAmount0;
    }

    function _swap1to0(
        uint256 total1ValueIn0,
        uint256 totalAssets1,
        uint256 totalAssets0,
        uint256 priceX96,
        uint256 sqrtPriceX96,
        uint256 virtualAmount1
    ) internal returns (uint256) {
        uint24 fee = pool.fee();
        // totalExcess1InTermsOf0 = total1ValueIn0.sub(totalAssets0)
        uint256 totalExcess1 = FullMath.mulDiv(
            total1ValueIn0.sub(totalAssets0),
            priceX96,
            FixedPoint96.Q96
        );
        uint256 excess1Ignore = FullMath.mulDiv(
            totalAssets1,
            swapExcessIgnore,
            1e6
        );

        if (totalExcess1 > excess1Ignore) {
            uint256 swapAmount = FullMath.mulDiv(
                totalExcess1,
                1e6,
                2 * (1e6 - fee)
            );
            virtualAmount1 = _WithdrawIfNecessLV1(swapAmount, virtualAmount1);
            pool.swap(
                address(this),
                false,
                int256(swapAmount),
                uint160(((uint256(sqrtPriceX96)).mul(110)).div(100)),
                ""
            );
        }

        return virtualAmount1;
    }

    function _WithdrawIfNecessLV0(uint256 amount, uint256 virtualAmount0)
        internal
        returns (uint256)
    {
        uint256 balance = getBalance0();
        if (amount > balance) {
            uint256 toWithdraw = amount.sub(balance).add(buffer);
            virtualAmount0 = virtualAmount0.sub(toWithdraw);
            uint256 sharesToWithdraw = FullMath.mulDiv(
                toWithdraw,
                10**lv0Decimals,
                lendVault0.pricePerShare()
            );
            lendVault0.withdraw(sharesToWithdraw);
        }
        return virtualAmount0;
    }

    function _WithdrawIfNecessLV1(uint256 amount, uint256 virtualAmount1)
        internal
        returns (uint256)
    {
        uint256 balance = getBalance1();
        if (amount > balance) {
            uint256 toWithdraw = amount.sub(balance).add(buffer);
            virtualAmount1 = virtualAmount1.sub(toWithdraw);
            uint256 sharesToWithdraw = FullMath.mulDiv(
                toWithdraw,
                10**lv1Decimals,
                lendVault1.pricePerShare()
            );
            lendVault1.withdraw(sharesToWithdraw);
        }
        return virtualAmount1;
    }

    /// @dev adjust tick such that its closest to initilized ones
    /// floorDown ---- actual ---- floorUp
    /// pick from down or up, depending upon which is closer
    function _adjustTick(int24 actualTick)
        internal
        view
        returns (int24 adjusedTick)
    {
        int24 floorDown;
        int24 floorUp;

        if (actualTick > 0) {
            floorDown = (actualTick / tickSpacing) * tickSpacing;
            floorUp = floorDown + tickSpacing;
        } else {
            floorUp = (actualTick / tickSpacing) * tickSpacing;
            floorDown = floorUp - tickSpacing;
        }

        if (actualTick - floorDown > floorUp - actualTick) {
            adjusedTick = floorUp;
        } else {
            adjusedTick = floorDown;
        }
    }

    function _checkRange(int24 tickLower, int24 tickUpper) internal view {
        int24 _tickSpacing = tickSpacing;
        require(tickLower < tickUpper, "tickLower < tickUpper");
        require(tickLower >= TickMath.MIN_TICK, "tickLower too low");
        require(tickUpper <= TickMath.MAX_TICK, "tickUpper too high");
        require(tickLower % _tickSpacing == 0, "tickLower % tickSpacing");
        require(tickUpper % _tickSpacing == 0, "tickUpper % tickSpacing");
    }

    /**
     * @notice Withdraws tokens in proportion to the vault's holdings.
     * @param shares Shares burned by sender
     * @param amount0Min Revert if resulting `amount0` is smaller than this
     * @param amount1Min Revert if resulting `amount1` is smaller than this
     * @param to Recipient of tokens
     * @return amount0 Amount of token0 sent to recipient
     * @return amount1 Amount of token1 sent to recipient
     */
    function withdraw(
        uint256 shares,
        uint256 amount0Min,
        uint256 amount1Min,
        address to
    ) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        require(shares > 0, "shares == 0");
        require(to != address(0) && to != address(this), "invalid recepient");
        uint256 _totalSupply = totalSupply();

        // Burn shares
        _burn(msg.sender, shares);

        // Calculate token amounts proportional to unused balances
        {
            uint256 unusedAmount0 = getBalance0().mul(shares).div(_totalSupply);
            uint256 unusedAmount1 = getBalance1().mul(shares).div(_totalSupply);
            amount0 = amount0.add(unusedAmount0);
            amount1 = amount1.add(unusedAmount1);
        }

        // Withdraw proportion of liquidity from Uniswap pool and from yearn
        {
            (uint128 totalLiquidity, , , , ) = _position(
                tick_lower,
                tick_upper
            );
            uint256 liquidity = (
                (uint256(totalLiquidity).mul(shares)).div(_totalSupply)
            );

            uint256 yTotalShares0 = lendVault0.balanceOf(address(this));
            uint256 yTotalShares1 = lendVault1.balanceOf(address(this));

            lv memory _lv;
            _lv.yShares0 = (yTotalShares0.mul(shares)).div(_totalSupply);
            _lv.yShares1 = (yTotalShares1.mul(shares)).div(_totalSupply);
            _lv.deposited0 = (lvTotalDeposited0.mul(shares)).div(_totalSupply);
            _lv.deposited1 = (lvTotalDeposited1.mul(shares)).div(_totalSupply);

            (
                uint256 _amountWithdrawn0,
                uint256 _amountWithdrawn1
            ) = _executeWithdraw(_toUint128(liquidity), _lv);

            amount0 = amount0.add(_amountWithdrawn0);
            amount1 = amount1.add(_amountWithdrawn1);
        }

        require(amount0 >= amount0Min, "amount0Min");
        require(amount1 >= amount1Min, "amount1Min");

        // Push tokens to recipient
        if (amount0 > 0) token0.safeTransfer(to, amount0);
        if (amount1 > 0) token1.safeTransfer(to, amount1);

        emit Withdraw(msg.sender, to, shares, amount0, amount1, totalSupply());
    }

    function _executeWithdraw(uint128 liquidity, lv memory _lv)
        internal
        returns (uint256 amount0, uint256 amount1)
    {
        //Step 1
        (
            uint256 uni0Withdrawn,
            uint256 uni1Withdrawn,
            uint256 uniGain0,
            uint256 uniGain1
        ) = _uniBurnAndCollect(_toUint128(liquidity));

        //Step 2 : Yearn
        uint256 lvWithdraw0;
        uint256 lvWithdraw1;
        uint256 lvGain0;
        uint256 lvGain1;

        if (_lv.yShares0 > 0) lvWithdraw0 = lendVault0.withdraw(_lv.yShares0); // max loss  # 0.01%
        if (_lv.yShares1 > 0) lvWithdraw1 = lendVault1.withdraw(_lv.yShares1);
        lvGain0 = lvWithdraw0 > _lv.deposited0
            ? lvWithdraw0 - _lv.deposited0
            : 0;
        lvGain1 = lvWithdraw1 > _lv.deposited1
            ? lvWithdraw1 - _lv.deposited1
            : 0;

        // Step 3 : Subtract Protocol Fees
        (uint256 gain0, uint256 gain1) = _accureFees(
            uniGain0.add(lvGain0),
            uniGain1.add(lvGain1)
        );

        amount0 = uni0Withdrawn.add(lvWithdraw0.sub(lvGain0)).add(gain0);
        amount1 = uni1Withdrawn.add(lvWithdraw1.sub(lvGain1)).add(gain1);
    }

    /// @dev Withdraws liquidity from uniswap with fees
    /// uni0withdrawn is differnt from uniGain0
    function _uniBurnAndCollect(uint128 liquidity)
        internal
        returns (
            uint256 uni0Withdrwn,
            uint256 uni1Withdrwn,
            uint256 uniGain0,
            uint256 uniGain1
        )
    {
        // Uniswap Withdraw
        if (liquidity > 0) {
            (uni0Withdrwn, uni1Withdrwn) = pool.burn(
                tick_lower,
                tick_upper,
                liquidity
            );
        }

        (uint256 collect0, uint256 collect1) = pool.collect(
            address(this),
            tick_lower,
            tick_upper,
            type(uint128).max,
            type(uint128).max
        );

        uniGain0 = collect0.sub(uni0Withdrwn);
        uniGain1 = collect1.sub(uni1Withdrwn);
    }

    function _accureFees(uint256 totalGain0, uint256 totalGain1)
        internal
        returns (uint256 gain0, uint256 gain1)
    {
        uint256 feesToProtocol0;
        uint256 feesToProtocol1;
        if (protocolFee > 0) {
            feesToProtocol0 = (totalGain0.mul(protocolFee)).div(1e6);
            feesToProtocol1 = (totalGain1.mul(protocolFee)).div(1e6);
            accruedProtocolFees0 = accruedProtocolFees0.add(feesToProtocol0);
            accruedProtocolFees1 = accruedProtocolFees1.add(feesToProtocol1);
            gain0 = totalGain0.sub(feesToProtocol0);
            gain1 = totalGain1.sub(feesToProtocol1);
        }
    }

    /// @dev Deposits liquidity in a range on the Uniswap pool.
    function _mintLiquidity(
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    ) internal {
        if (liquidity > 0) {
            pool.mint(address(this), tickLower, tickUpper, liquidity, "");
        }
    }

    function getBalance0() public view returns (uint256) {
        return token0.balanceOf(address(this)).sub(accruedProtocolFees0);
    }

    function getBalance1() public view returns (uint256) {
        return token1.balanceOf(address(this)).sub(accruedProtocolFees1);
    }

    /**
     * @notice Calculates the vault's total holdings of token0 and token1 - in
     * other words, how much of each token the vault would hold if it withdrew
     * all its liquidity from Uniswap and withdrew all shares from yearn.
     */
    function getTotalAmounts()
        public
        view
        returns (uint256 total0, uint256 total1)
    {
        (uint256 uniAmount0, uint256 uniAmount1) = _getPositionAmounts();
        (uint256 lvAmount0, uint256 lvAmount1, , , , ) = _getLvAmounts();
        total0 = getBalance0().add(uniAmount0).add(lvAmount0);
        total1 = getBalance1().add(uniAmount1).add(lvAmount1);
    }

    /**
     * @notice Amounts of token0 and token1 held in vault's position. Includes
     * owed fees but excludes the proportion of fees that will be paid to the
     * protocol. Doesn't include fees accrued since last poke.
     */
    function _getPositionAmounts()
        internal
        view
        returns (uint256 amount0, uint256 amount1)
    {
        (
            uint128 liquidity,
            ,
            ,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        ) = _position(tick_lower, tick_upper);
        (amount0, amount1) = _amountsForLiquidity(
            tick_lower,
            tick_upper,
            liquidity
        );
        // Subtract protocol fees
        uint256 oneMinusFee = uint256(1e6).sub(protocolFee);
        amount0 = amount0.add((uint256(tokensOwed0).mul(oneMinusFee)).div(1e6));
        amount1 = amount1.add((uint256(tokensOwed1).mul(oneMinusFee)).div(1e6));
    }

    /**
     * @notice Present value of lending vault holdings
     * excludes the proportion of fees that will be paid to the protocol.
     */
    function _getLvAmounts()
        internal
        view
        returns (
            uint256 amount0,
            uint256 amount1,
            uint256 feeProtocol0,
            uint256 feeProtocol1,
            uint256 total0,
            uint256 total1
        )
    {
        amount0 = FullMath.mulDiv(
            lendVault0.balanceOf(address(this)),
            lendVault0.pricePerShare(),
            10**lv0Decimals
        );
        amount1 = FullMath.mulDiv(
            lendVault1.balanceOf(address(this)),
            lendVault1.pricePerShare(),
            10**lv1Decimals
        );

        total0 = amount0;
        total1 = amount1;

        // Subtract protocol fees
        if (amount0 > lvTotalDeposited0) {
            feeProtocol0 = FullMath.mulDiv(
                amount0.sub(lvTotalDeposited0),
                protocolFee,
                1e6
            );
            amount0 = amount0.sub(feeProtocol0);
        }
        if (amount1 > lvTotalDeposited1) {
            feeProtocol1 = FullMath.mulDiv(
                amount1.sub(lvTotalDeposited1),
                protocolFee,
                1e6
            );
            amount1 = amount1.sub(feeProtocol1);
        }
    }

    /// @dev Wrapper around `IUniswapV3Pool.positions()`.
    function _position(int24 tickLower, int24 tickUpper)
        internal
        view
        returns (
            uint128,
            uint256,
            uint256,
            uint128,
            uint128
        )
    {
        bytes32 positionKey = PositionKey.compute(
            address(this),
            tickLower,
            tickUpper
        );
        return pool.positions(positionKey);
    }

    /// @dev Wrapper around `LiquidityAmounts.getAmountsForLiquidity()`.
    function _amountsForLiquidity(
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    ) internal view returns (uint256, uint256) {
        (uint160 sqrtRatioX96, , , , , , ) = pool.slot0();
        return
            LiquidityAmounts.getAmountsForLiquidity(
                sqrtRatioX96,
                TickMath.getSqrtRatioAtTick(tickLower),
                TickMath.getSqrtRatioAtTick(tickUpper),
                liquidity
            );
    }

    /// @dev Casts uint256 to uint128 with overflow check.
    function _toUint128(uint256 x) internal pure returns (uint128) {
        assert(x <= type(uint128).max);
        return uint128(x);
    }

    /// @dev Callback for Uniswap V3 pool.
    function uniswapV3MintCallback(
        uint256 amount0,
        uint256 amount1,
        bytes calldata data
    ) external override {
        require(msg.sender == address(pool));
        if (amount0 > 0) token0.safeTransfer(msg.sender, amount0);
        if (amount1 > 0) token1.safeTransfer(msg.sender, amount1);
    }

    /// @dev Callback for Uniswap V3 pool.
    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external override {
        require(msg.sender == address(pool));
        if (amount0Delta > 0)
            token0.safeTransfer(msg.sender, uint256(amount0Delta));
        if (amount1Delta > 0)
            token1.safeTransfer(msg.sender, uint256(amount1Delta));
    }

    /**
     * @notice Used to collect accumulated protocol fees.
     */
    function collectFees(address _feeCollector) external onlyStrategy {
        uint256 _accruedProtocolFees0 = accruedProtocolFees0;
        uint256 _accruedProtocolFees1 = accruedProtocolFees1;
        accruedProtocolFees0 = 0;
        accruedProtocolFees1 = 0;
        if (_accruedProtocolFees0 > 0)
            token0.safeTransfer(_feeCollector, _accruedProtocolFees0);
        if (_accruedProtocolFees1 > 0)
            token1.safeTransfer(_feeCollector, _accruedProtocolFees1);
    }

    /**
     * @notice Removes other tokens accidentally sent to this vault.
     */
    function sweep(
        IERC20 token,
        uint256 amount,
        address to
    ) external onlyGovernanceOrTeamMultisig {
        require(token != token0 && token != token1, "vault tokens");
        token.safeTransfer(to, amount);
    }

    /**
     * @notice Used to set the strategy contract that determines the uniswapShare
     * and calls rebalance(). Must be called after this vault is
     * deployed.
     */
    function setStrategy(address _strategy)
        external
        onlyGovernanceOrTeamMultisig
    {
        strategy = _strategy;
    }

    /**
     * @notice Used to set swapExcessIgnore
     * percentage excess ignored, in terms of /1e-6, so if its 5000, it will be 0.5%
     * if its 0.5%, then asset0 can stay in 49.5-50.5
     */
    function setSwapExcessIgnore(uint256 _swapExcessIgnore)
        external
        onlyGovernanceOrTeamMultisig
    {
        require(_swapExcessIgnore < 1e6, "swapExcessIgnore excceding 1e6");
        swapExcessIgnore = _swapExcessIgnore;
    }

    /**
     * @notice Used to change the protocol fee charged on pool fees earned from
     * uniswap and gain earned from yearn, expressed as multiple of 1e-6.
     */
    function setProtocolFee(uint256 _protocolFee) external onlyGovernance {
        require(_protocolFee < 1e6, "protocolFee excceding 1e6");
        protocolFee = _protocolFee;
    }

    /**
     * @notice Used to change deposit cap for a guarded launch or to ensure
     * vault doesn't grow too large relative to the pool. Cap is on total
     * supply rather than amounts of token0 and token1 as those amounts
     * fluctuate naturally over time.
     */
    function setMaxTotalSupply(uint256 _maxTotalSupply)
        external
        onlyGovernanceOrTeamMultisig
    {
        maxTotalSupply = _maxTotalSupply;
    }

    /**
     * @notice Used to change
     * @param _thresholdForLV0Deposit, Deposit into lendingVault0, only if assetsRemain0 > _thresholdForLV0Deposit
     * @param _thresholdForLV1Deposit, Deposit into lendingVault1, only if assetsRemain1 > _thresholdForLV1Deposit
     * @param _buffer, amount to be added, while calculating shares to withdraw from lending vaults
     */
    function setThresholdAndBuffer(
        uint64 _thresholdForLV0Deposit,
        uint64 _thresholdForLV1Deposit,
        uint8 _buffer
    ) external onlyGovernanceOrTeamMultisig {
        thresholdForLV0Deposit = _thresholdForLV0Deposit;
        thresholdForLV1Deposit = _thresholdForLV1Deposit;
        buffer = _buffer;
    }

    /**
     * @notice Removes liquidity or withdraws shares in case of emergency.
     */
    function emergencyWithdraw(uint8 _case)
        external
        onlyGovernanceOrTeamMultisig
    {
        if (_case == 0) {
            (uint128 totalLiquidity, , , , ) = _position(
                tick_lower,
                tick_upper
            );
            pool.burn(tick_lower, tick_upper, totalLiquidity);
            pool.collect(
                address(this),
                tick_lower,
                tick_upper,
                type(uint128).max,
                type(uint128).max
            );
        } else if (_case == 1) lendVault0.withdraw();
        else if (_case == 2) lendVault1.withdraw();
    }

    /**
     * @notice Allow governance to pause deposit and rebalance, so graceful withdraw can happen in case of any attack
     */
    function pause() external onlyGovernanceOrTeamMultisig {
        Pausable._pause();
    }

    function unpause() external onlyGovernanceOrTeamMultisig {
        Pausable._unpause();
    }

    modifier onlyStrategy() {
        require(msg.sender == strategy, "not a strategy");
        _;
    }
}
