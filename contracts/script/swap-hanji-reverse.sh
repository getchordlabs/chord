#!/bin/bash
# Swap ~0.1 USDC → MON via HanjiAdapter → Hanji MON/USDC FastQuoterProxy (BUY base)
# Exact-in quote via placeMarketOrderWithTargetValue — taker fee comes out of the input.
# Venue pays native MON to the adapter; the adapter re-wraps to WMON before forwarding.
# extraData = abi.encode(address proxy) ONLY — market config is read on-chain via getConfig().
ADAPTER="${ADAPTER_HANJI:?set ADAPTER_HANJI to the deployed HanjiAdapter address}"
PROXY=0x1aed222dda944a87703c918745b11be13f8eef10  # MON/USDC FastQuoterProxy
WMON=0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A
USDC=0x754704Bc059F8C67012fEd69BC8A327a5aafb603
USDC_AMOUNT=100000  # 0.1 USDC (6 decimals)

EXTRA=$(cast abi-encode "f(address)" $PROXY)

# Step 1: Approve USDC to the router
cast send $USDC \
  "approve(address,uint256)" \
  0x1B1Fee89A381E595Fe6536b99Ba91F3E16e9601a \
  $USDC_AMOUNT \
  --legacy \
  --rpc-url "${MONAD_RPC_URL:?set MONAD_RPC_URL}" \
  --private-key $DEPLOYER_PRIVATE_KEY

echo "=== Approved. Swapping... ==="

# Step 2: Swap USDC → MON (out as WMON from the adapter)
cast send 0x1B1Fee89A381E595Fe6536b99Ba91F3E16e9601a \
  --legacy \
  --gas-limit 2000000 \
  --rpc-url "${MONAD_RPC_URL:?set MONAD_RPC_URL}" \
  --private-key $DEPLOYER_PRIVATE_KEY \
  "swap(address,address,uint256,uint256,uint256,(address,address,address,uint256,bytes),address)" \
  $USDC \
  $WMON \
  $USDC_AMOUNT \
  0 \
  99999999999 \
  "($ADAPTER,$USDC,$WMON,$USDC_AMOUNT,$EXTRA)" \
  0x0000000000000000000000000000000000000000
