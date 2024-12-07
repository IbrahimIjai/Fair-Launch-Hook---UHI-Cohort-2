// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {GasPriceFeesHook} from "../src/GasPriceFeesHook.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {console} from "forge-std/console.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";

contract TestFairLaunchHook is Test, Deployers {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    GasPriceFeesHook hook;

    function setUp() public {
        // Deploy v4-core
        deployFreshManagerAndRouters();

        // Deploy, mint tokens, and approve all periphery contracts for two tokens
        deployMintAndApprove2Currencies();

        address currency0Address = Currency.unwrap(currency0);
        address currency1Address = Currency.unwrap(currency1);

        MockERC20 token0 = MockERC20(address(currency0Address));

        uint256 amountToMint0 = 100_000 * 10 ** token0.decimals();

        // Deploy our hook with the proper flags
        address hookAddress = address(
            uint160(
                Hooks.BEFORE_INITIALIZE_FLAG |
                    Hooks.BEFORE_SWAP_FLAG |
                    Hooks.AFTER_ADD_LIQUIDITY_FLAG |
                    Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
            )
        );
        // Set gas price = 10 gwei and deploy our hook
        vm.txGasPrice(10 gwei);

        token0.mint(hookAddress, amountToMint0);

        deployCodeTo(
            "GasPriceFeesHook.sol",
            abi.encode(manager, address(currency0Address)),
            hookAddress
        );

        hook = GasPriceFeesHook(hookAddress);

        // Initialize a pool
        (key, ) = initPool(
            currency0,
            currency1,
            hook,
            LPFeeLibrary.DYNAMIC_FEE_FLAG, // Set the `DYNAMIC_FEE_FLAG` in place of specifying a fixed fee
            SQRT_PRICE_1_1
        );
    }

    function test_addLiquidityAndSwap() public {
        // Set user address in hook data
        // bytes memory hookData = abi.encode(address(this));
        bytes memory hookData = abi.encode(address(this));
        hook.protocolFeePayment{value: 0.013 ether}();

        uint256 ethToAdd = 0.1 ether;

        BalanceDelta callerDelta = modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 0.1 ether,
                salt: bytes32(0)
            }),
            hookData
        );

        uint256 amount0 = uint256(int256(-callerDelta.amount0()));
        uint256 amount1 = uint256(int256(-callerDelta.amount1()));

        assertEq(
            hook.userPower(address(this)),
            0.1 ether,
            "User power mismatch"
        );

        BalanceDelta callerDelta2 = modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 0.3 ether,
                salt: bytes32(0)
            }),
            hookData
        );

        uint256 amount00 = uint256(int256(-callerDelta.amount0()));
        uint256 amount11 = uint256(int256(-callerDelta.amount1()));

        console.log(
            "Test: Minimum trade liuidity: %s",
            hook.MINIMUM_LIQUIDITY_TO_OPEN_TRADE()
        );
        console.log("Test: user power: %s", hook.userPower(address(this)));
        console.log("Test: total liuidity provided: %s", hook.totalLiquidity());

        assertEq(
            hook.userPower(address(this)),
            0.4 ether,
            "User power mismatch"
        );
    }

    // function test_claimRewards_MultipleClaimsPrevented() public {
    //     // Prepare hook data
    //     bytes memory hookData = abi.encode(liquidityProvider);

    // }
}
