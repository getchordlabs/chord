// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

/// @title INullRouter
/// @notice Entry point for all NullTerminal swaps
interface INullRouter {
    /// @notice Route step for split/multi-hop execution
    struct RouteStep {
        address adapter; // Whitelisted adapter address
        address tokenIn;
        address tokenOut;
        uint256 amountIn; // 0 = use full balance (for multi-hop intermediate)
        bytes extraData; // DEX-specific params
    }

    /// @notice Execute a single-route swap
    /// @param tokenIn Input token address (address(0) for native MON)
    /// @param tokenOut Output token address
    /// @param amountIn Input amount in wei
    /// @param minAmountOut Minimum output (slippage protection)
    /// @param deadline Transaction deadline (block.timestamp)
    /// @param route Single route step
    /// @param referrer Referral address (address(0) if none)
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        uint256 deadline,
        RouteStep calldata route,
        address referrer
    ) external payable returns (uint256 amountOut);

    /// @notice Execute a split swap across multiple DEXs
    /// @param tokenIn Input token address
    /// @param tokenOut Output token address
    /// @param amountIn Total input amount
    /// @param minAmountOut Minimum total output
    /// @param deadline Transaction deadline
    /// @param routes Array of route steps (amounts must sum to amountIn)
    /// @param referrer Referral address
    function splitSwap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        uint256 deadline,
        RouteStep[] calldata routes,
        address referrer
    ) external payable returns (uint256 amountOut);

    /// @notice Execute a multi-hop swap (A → B → C)
    /// @param amountIn Input amount
    /// @param minAmountOut Minimum final output
    /// @param deadline Transaction deadline
    /// @param routes Ordered route steps for each hop
    /// @param referrer Referral address
    function multiHopSwap(
        uint256 amountIn,
        uint256 minAmountOut,
        uint256 deadline,
        RouteStep[] calldata routes,
        address referrer
    ) external payable returns (uint256 amountOut);

    /// @notice One independent execution path of a multi-path swap: a linear hop chain
    ///         consuming its own share of the total input. All paths of one swap share the
    ///         same entry token (hops[0].tokenIn) and exit token (last hop's tokenOut).
    struct Path {
        uint256 amountIn; // this path's share of the total input; hops[0].amountIn must equal it
        RouteStep[] hops; // >=1 hop; later hops chain the prior hop's output (amountIn = 0)
    }

    /// @notice Execute a multi-PATH swap: the input is split across 2+ independent paths that run
    ///         in sequence within one tx (e.g. 60% direct pool + 40% via a 3-hop detour), outputs
    ///         are summed, and fee + minAmountOut are enforced ONCE on the total.
    /// @param amountIn Total input (must equal the sum of paths[i].amountIn)
    /// @param minAmountOut Minimum TOTAL output after fee (slippage guard across all paths)
    /// @param deadline Transaction deadline
    /// @param paths Independent hop chains, each consuming its own input share
    /// @param referrer Referral address
    function multiPathSwap(
        uint256 amountIn,
        uint256 minAmountOut,
        uint256 deadline,
        Path[] calldata paths,
        address referrer
    ) external payable returns (uint256 amountOut);

    /// @notice Emitted on every successful swap
    event Swap(
        address indexed sender,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 feeAmount,
        address referrer
    );
}
