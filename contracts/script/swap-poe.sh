#!/bin/bash
# Swap 2 MON → USDC via LfjPoeAdapter → LFJ POE OraclePool (swapXtoY, callback settlement)
# Native-in: tokenIn=WMON + --value 2ether (router wraps). NO venue router — the adapter swaps
# directly on the pool and settles in swapCallback.
# extraData = abi.encode(address pool) ONLY — direction is derived on-chain via getTokens().
ADAPTER="${ADAPTER_LFJ_POE:?set ADAPTER_LFJ_POE to the deployed LfjPoeAdapter address}"
POOL=0x02A8A16613a421EabaD6861fF6d8159f6D5EDB8f  # LFJ POE WMON/USDC OraclePool
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
