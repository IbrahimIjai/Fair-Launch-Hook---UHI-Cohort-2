// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Currency} from "v4-core/types/Currency.sol";
import "forge-std/console.sol";

contract FairLaunchHook is BaseHook {
    using LPFeeLibrary for uint24;

    IERC20 public tokenX;

    struct CallbackData {
        uint256 amountEach;
        Currency currency0;
        Currency currency1;
        address sender;
    }

    // Keeping track of the moving average gas price
    uint128 public movingAverageGasPrice;

    uint104 public movingAverageGasPriceCount;

    uint256 public poolInitializationTime;
    uint256 constant SELL_COOLDOWN_PERIOD = 7 days;
    uint256 constant GUARDIAN_LIQUIDITY_PROVIDER_LOCK_PERIOD = 7 days;
    uint256 public constant MINIMUM_LIQUIDITY_TO_OPEN_TRADE = 0.2 ether;
    // The default base fees we will charge
    uint24 public constant BASE_FEE = 5000; // denominated in pips (one-hundredth bps) 0.5%

    uint24 constant BUY_FEE = 1000; // 0.1%
    uint24 constant SELL_FEE = 10000; // 1%

    mapping(address => uint256) public userPower;
    mapping(address => uint256) public userLpLock;
    mapping(address => uint256) public userTokenBalance;
    uint256 public totalLiquidity;
    mapping(address => uint256) public lpProvoderLastClaim;

    bool poolActivated;

    error MustUseDynamicFee();
    error MustWithdrawLpAfterLockTTime();
    error PoolNotActivated();

    // Initialize BaseHook parent contract in the constructor
    constructor(
        IPoolManager _poolManager,
        address _tokenX
    ) BaseHook(_poolManager) {
        tokenX = IERC20(_tokenX);
    }

    // Required override function for BaseHook to let the PoolManager know which hooks are implemented
    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: true,
                afterInitialize: false,
                beforeAddLiquidity: false,
                beforeRemoveLiquidity: true,
                afterAddLiquidity: true,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: false,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    function beforeInitialize(
        address,
        PoolKey calldata key,
        uint160
    ) external pure override returns (bytes4) {
        // `.isDynamicFee()` function comes from using
        // the `SwapFeeLibrary` for `uint24`
        if (!key.fee.isDynamicFee()) revert MustUseDynamicFee();
        return this.beforeInitialize.selector;
    }

    function beforeSwap(
        address swapper,
        PoolKey calldata,
        IPoolManager.SwapParams calldata params,
        bytes calldata
    )
        external
        override
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        uint24 fee;
        require(
            totalLiquidity >= MINIMUM_LIQUIDITY_TO_OPEN_TRADE,
            "Sell has not began"
        );

        // Absolute value of amount specified
        uint256 absAmount = params.amountSpecified < 0
            ? uint256(-params.amountSpecified)
            : uint256(params.amountSpecified);

        // Selling (currency 0)
        if (params.zeroForOne) {
            // Ensure enough balance before subtracting
            require(
                userTokenBalance[swapper] >= absAmount,
                "Insufficient balance"
            );
            unchecked {
                userTokenBalance[swapper] -= absAmount;
            }
            fee = SELL_FEE;
        } else {
            // Buying (currency 1)
            unchecked {
                userTokenBalance[swapper] += absAmount;
            }
            fee = BUY_FEE;
        }
        return (
            this.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            fee
        );
    }

    

    function afterAddLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata hookData
    ) external virtual override returns (bytes4, BalanceDelta) {
        if (!poolActivated) revert PoolNotActivated();

        int256 liquidityDelta = params.liquidityDelta;

        console.log("Hook: liquidityDelta: %s", liquidityDelta);

        uint256 amount0 = uint256(int256(-delta.amount0()));
        uint256 amount1 = uint256(int256(-delta.amount1()));

        // console.log("Hook: amount0: %s", amount0);
        // console.log("Hook: amount1: %s", amount1);

        address lp_provider = _extractUser(hookData);

        if (totalLiquidity <= MINIMUM_LIQUIDITY_TO_OPEN_TRADE) {
            userPower[lp_provider] += uint256(liquidityDelta);
            userLpLock[lp_provider] = (block.timestamp + SELL_COOLDOWN_PERIOD);

            totalLiquidity += uint256(liquidityDelta);
        } else {
            console.log("Hook: Not updating user power due to cooldown period");
        }
        return (this.afterAddLiquidity.selector, delta);
    }

    function beforeRemoveLiquidity(
        address lp_provider,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external virtual override returns (bytes4) {
        if (userPower[lp_provider] > 0) {
            if (userLpLock[lp_provider] > block.timestamp) {
                revert MustWithdrawLpAfterLockTTime();
            }
        }
        return this.beforeAddLiquidity.selector;
    }

    function protocolFeePayment() external payable {
        require(msg.value == 0.013 ether, "Fee must be 0.013 ETH");
        require(!poolActivated, "hook activated already");
        poolActivated = true;

        poolInitializationTime = block.timestamp;
    }

    function claimRewards() public {
        require(
            userPower[msg.sender] > 0,
            "You are not a guardian liuidity provider"
        );
        uint256 lockDuration = GUARDIAN_LIQUIDITY_PROVIDER_LOCK_PERIOD +
            poolInitializationTime;
        require(block.timestamp >= lockDuration, "Rewards not yet claimable");

        uint256 lastTimeClaim = lpProvoderLastClaim[msg.sender] > 0
            ? lpProvoderLastClaim[msg.sender]
            : poolInitializationTime;

        uint256 timeWeightDelta = block.timestamp - lastTimeClaim;

        // More precise and clear reward calculation
        uint256 userTotalLiquidity = userPower[msg.sender];
        uint256 rewardRate = (100_000 * 10 ** 18) /
            GUARDIAN_LIQUIDITY_PROVIDER_LOCK_PERIOD;
        uint256 rewardsToClaim = (userTotalLiquidity *
            timeWeightDelta *
            rewardRate) / totalLiquidity;

        lpProvoderLastClaim[msg.sender] = block.timestamp;

        require(
            IERC20(tokenX).transfer(msg.sender, rewardsToClaim),
            "Token transfer failed"
        );
    }

    function _extractUser(
        bytes calldata hookData
    ) internal pure returns (address) {
        if (hookData.length == 0) return address(0);
        return abi.decode(hookData, (address));
    }
}
