#!/bin/bash
# Swap 2 MON → USDC via HanjiAdapter → Hanji MON/USDC FastQuoterProxy (SELL base, IOC ask)
# Native-in: tokenIn=WMON + --value 2ether (router wraps). Hanji MON/USDC has 1-whole-MON share
# granularity (scalingFactorTokenX=1e18), so use an INTEGER MON amount >= 2 — sub-share dust is
# refunded via the router dust-sweep.
# extraData = abi.encode(address proxy) ONLY — market config is read on-chain via getConfig().
ADAPTER="${ADAPTER_HANJI:?set ADAPTER_HANJI to the deployed HanjiAdapter address}"
PROXY=0x1aed222dda944a87703c918745b11be13f8eef10  # MON/USDC FastQuoterProxy
WMON=0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A
USDC=0x754704Bc059F8C67012fEd69BC8A327a5aafb603
AMOUNT=2000000000000000000  # 2 MON

EXTRA=$(cast abi-encode "f(address)" $PROXY)

cast send 0x1B1Fee89A381E595Fe6536b99Ba91F3E16e9601a \
  --value 2ether \
  --legacy \
  --gas-limit 2000000 \
  --rpc-url "${MONAD_RPC_URL:?set MONAD_RPC_URL}" \
  --private-key $DEPLOYER_PRIVATE_KEY \
  "swap(address,address,uint256,uint256,uint256,(address,address,address,uint256,bytes),address)" \
  $WMON \
  $USDC \
  $AMOUNT \
  0 \
  99999999999 \
  "($ADAPTER,$WMON,$USDC,$AMOUNT,$EXTRA)" \
  0x0000000000000000000000000000000000000000
