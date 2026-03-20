// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {INullRouter} from "../src/interfaces/INullRouter.sol";
import {PoolKey} from "../src/adapters/UniswapV4Adapter.sol";

/// @notice Test swap: MON → USDC via NullRouter → UniswapV4Adapter → PoolManager
contract TestSwapScript is Script {
    address constant NULL_ROUTER = 0x1B1Fee89A381E595Fe6536b99Ba91F3E16e9601a;
    address constant WMON = 0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A;
    address constant USDC = 0x754704Bc059F8C67012fEd69BC8A327a5aafb603;

    address ADAPTER; // set via env

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        ADAPTER = vm.envAddress("ADAPTER");

        uint256 amountIn = 10 ether; // 10 MON

        console2.log("=== NullTerminal Test Swap ===");
        console2.log("Swapper:", deployer);
        console2.log("Adapter:", ADAPTER);
        console2.log("Swap: 10 MON -> USDC");

        uint256 usdcBefore = IERC20(USDC).balanceOf(deployer);
        console2.log("USDC before:", usdcBefore);

        vm.startBroadcast(deployerPrivateKey);

        // extraData = abi.encode(PoolKey) — that's all Approach A needs
        bytes memory extraData = abi.encode(
            PoolKey({
                currency0: address(0),  // native MON
                currency1: USDC,
                fee: 3000,
                tickSpacing: int24(60),
                hooks: address(0)
            })
        );

        INullRouter.RouteStep memory route = INullRouter.RouteStep({
            adapter: ADAPTER,
            tokenIn: WMON,
            tokenOut: USDC,
            amountIn: amountIn,
            extraData: extraData
        });

        uint256 amountOut = INullRouter(payable(NULL_ROUTER)).swap{value: amountIn}(
            WMON,
            USDC,
            amountIn,
            0, // minAmountOut = 0 for test ONLY
            block.timestamp + 300,
            route,
            address(0)
        );

        vm.stopBroadcast();

        uint256 usdcAfter = IERC20(USDC).balanceOf(deployer);
        console2.log("");
        console2.log("=== RESULT ===");
        console2.log("USDC received:", usdcAfter - usdcBefore);
        console2.log("amountOut:", amountOut);
    }
}
