#!/bin/bash
# Swap 2 MON → USDC via MetricAdapter → Metric OMM shared SwapRouter (zeroForOne on WMON/USDC pool)
# Native-in: tokenIn=WMON + --value 2ether (router wraps).
# extraData = abi.encode(address pool) ONLY — direction is derived on-chain via getImmutables().
# NOTE: execution can revert WrappedError(FeedStalled) if the pool's PriceProvider push is >4s
# stale — just retry.
ADAPTER="${ADAPTER_METRIC:?set ADAPTER_METRIC to the deployed MetricAdapter address}"
POOL=0xFA32f9ec28787d1F9C5BA5c39e54e59984FEF3f0  # Metric OMM WMON/USDC pool
WMON=0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A
USDC=0x754704Bc059F8C67012fEd69BC8A327a5aafb603
AMOUNT=2000000000000000000  # 2 MON

EXTRA=$(cast abi-encode "f(address)" $POOL)

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
