#!/bin/bash
# Balancer V3 BOOSTED (the prize): USDC -> USDT0 via boosted stable pool (0x2daa146dfb7eaef0038f9f15b2ec1e4de003f72b).
# APPROVE USDC to NullRouter first. Requires ADAPTER_BALANCER_BOOSTED.
set -e
: "${ADAPTER_BALANCER_BOOSTED:?set ADAPTER_BALANCER_BOOSTED}"
AMT=${USDC_AMOUNT:-1000000}  # 1 USDC
# extraData = abi.encode(SwapPathStep[]) : [wrap USDC->wnUSDC, swap wnUSDC->wnUSDT0, unwrap wnUSDT0->USDT0]
EXTRA=$(cast abi-encode "x((address,address,bool)[])" "[(0x8d5c2df3eef09088fcccf3376d8ecd0dd505f642,0x8d5c2df3eef09088fcccf3376d8ecd0dd505f642,true),(0x2daa146dfb7eaef0038f9f15b2ec1e4de003f72b,0x4e8aaecce10ad9394e96fe5f2bd4e587a7b04298,false),(0x4e8aaecce10ad9394e96fe5f2bd4e587a7b04298,0xe7cd86e13AC4309349F30B3435a9d337750fC82D,true)]")
cast send 0x1B1Fee89A381E595Fe6536b99Ba91F3E16e9601a --legacy --gas-limit 1500000 \
  --rpc-url "${MONAD_RPC_URL:?}" --private-key $DEPLOYER_PRIVATE_KEY \
  "swap(address,address,uint256,uint256,uint256,(address,address,address,uint256,bytes),address)" \
  0x754704Bc059F8C67012fEd69BC8A327a5aafb603 0xe7cd86e13AC4309349F30B3435a9d337750fC82D $AMT 0 99999999999 \
  "($ADAPTER_BALANCER_BOOSTED,0x754704Bc059F8C67012fEd69BC8A327a5aafb603,0xe7cd86e13AC4309349F30B3435a9d337750fC82D,$AMT,$EXTRA)" \
  0x0000000000000000000000000000000000000000
