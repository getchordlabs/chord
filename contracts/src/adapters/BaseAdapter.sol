// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title BaseAdapter
/// @notice Shared H1 hardening for every DEX adapter: the ENTRYPOINT GATE (`onlyRouter`).
/// @dev 2026-08-05 audit H1 — the systemic root cause. 15 adapters decoded a destination/pool
///      address out of caller-supplied `extraData` with ZERO validation, and NOT ONE restricted its
///      caller: every `swap()` was world-callable, i.e. a "send this adapter's balance to an address
///      I choose" primitive for anyone. The transient-storage callback gates (UniV3Generic, Algebra,
///      LfjPoe) were correctly written for the threat they target, but they authenticate *which
///      contract may call back*, not *that it is a real pool* — armed to the attacker's own address
///      they pass by construction. The gate below alone reduces the whole class to "the router can
///      be tricked"; per-adapter pool provenance (factory registry lookup / CREATE2 derivation)
///      closes the rest.
///
///      Adapters are IMMUTABLE (no proxy), so this CANNOT be upgraded in place: it ships as NEW
///      deployments + an AdapterRegistry swap — `addAdapter(new)` → mainnet swap verified BOTH
///      DIRECTIONS → `removeAdapter(old)`, one venue at a time, per the DEX rule in CLAUDE.md.
///
///      Naming: `NULL_ROUTER`, not `ROUTER` — half the adapters already use `ROUTER` for the VENUE's
///      router (Pancake/V3Deadline/Metric/Mento/LFJ/Balancer), and silently overloading that name is
///      exactly how a gate ends up pointed at the wrong contract.
abstract contract BaseAdapter {
    /// @notice The only contract allowed to call `swap()` — the NullRouter proxy, pinned at deploy.
    address public immutable NULL_ROUTER;

    /// @notice swap() was called by something other than NullRouter.
    error NotRouter();
    /// @notice Constructor guard — a zero router would leave the adapter permanently world-callable
    ///         by nobody (bricked) or, worse, mis-wired into an approved-but-ungated deployment.
    error ZeroRouter();

    constructor(address nullRouter_) {
        if (nullRouter_ == address(0)) revert ZeroRouter();
        NULL_ROUTER = nullRouter_;
    }

    /// @dev H1 entrypoint gate. NullRouter is the ONLY caller in production: it pushes tokenIn to
    ///      the adapter and immediately calls swap() in the same transaction, so nothing legitimate
    ///      ever calls an adapter directly. NOTE: `NullExecutor` (deployed but OUT of the swap path
    ///      since 2026-03-20) and `NullArbExecutor` (never deployed) call adapters directly and are
    ///      therefore cut off by this gate — intentionally; H6 recommends deleting the latter.
    modifier onlyRouter() {
        if (msg.sender != NULL_ROUTER) revert NotRouter();
        _;
    }
}

/// @title AllowlistAdapter
/// @notice BaseAdapter + an IMMUTABLE pool/market allowlist fixed at construction.
/// @dev For venues that expose NO on-chain registry lookup to validate an `extraData` pool against
///      (Kuru, Hanji, Metric OMM, LFJ POE — all of them discovered off-chain via the venue's API or
///      a verified seed list, with no `getPool`/`getPair` view we could pin). The allowlist is
///      written ONLY in the constructor and has no setter and no owner, so it is immutable in
///      substance even though it lives in storage (a `mapping` cannot be `immutable`).
///
///      Trade-off, stated plainly: adding a market now requires a NEW adapter deployment + registry
///      swap. That is the same cost as any other adapter change (they are immutable anyway) and it
///      is the honest price of refusing caller-supplied destinations. Kuru is the one that hurts —
///      its ~10 markets are discovered dynamically from api.kuru.io.
abstract contract AllowlistAdapter is BaseAdapter {
    /// @notice Pools/markets this adapter will route through. Constructor-only writes; no setter.
    mapping(address => bool) public isAllowedPool;

    /// @notice extraData named a pool/market outside the construction-time allowlist.
    error PoolNotAllowed(address pool);
    /// @notice An empty allowlist would brick the adapter — always a deploy-script mistake.
    error EmptyAllowlist();
    /// @notice address(0) in the allowlist — always a deploy-script mistake.
    error ZeroPool();

    constructor(address nullRouter_, address[] memory pools_) BaseAdapter(nullRouter_) {
        if (pools_.length == 0) revert EmptyAllowlist();
        for (uint256 i = 0; i < pools_.length; i++) {
            if (pools_[i] == address(0)) revert ZeroPool();
            isAllowedPool[pools_[i]] = true;
        }
    }

    /// @dev H1 provenance for registry-less venues.
    function _requireAllowedPool(address pool) internal view {
        if (!isAllowedPool[pool]) revert PoolNotAllowed(pool);
    }
}

/// @title PoolProvenance
/// @notice CREATE2 pool-address derivation for V3-style forks.
/// @dev A caller-supplied pool that matches `CREATE2(factory, salt, INIT_CODE_HASH)` for a factory
///      pinned at construction IS the canonical pool for those parameters — forging a match would
///      require inverting keccak256 over the address space. This is the same check Uniswap's own
///      `CallbackValidation` performs; note the tokens/fee are read FROM the pool, which is safe
///      precisely because the derivation, not the pool's word, is what authenticates it.
library PoolProvenance {
    /// @param factory      Fork factory, pinned at construction.
    /// @param initCodeHash keccak256 of the fork's pool creation code — DIFFERENT per fork, which is
    ///                     why it is a constructor argument and never a hardcoded guess.
    /// @param salt         keccak256(abi.encode(token0, token1, fee)) for Uniswap-style forks;
    ///                     keccak256(abi.encode(token0, token1)) for dynamic-fee (Algebra) forks.
    function computeAddress(address factory, bytes32 initCodeHash, bytes32 salt)
        internal
        pure
        returns (address)
    {
        return address(
            uint160(uint256(keccak256(abi.encodePacked(hex"ff", factory, salt, initCodeHash))))
        );
    }
}
