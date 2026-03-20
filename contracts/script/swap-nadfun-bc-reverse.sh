#!/bin/bash
# Swap ZigZag → MON via NadFunBCAdapter (sell on bonding curve)
# extraData = abi.encode(token, isBuy=false)
ADAPTER=0xc9F93c048Eb48cE9611C915C62b925f9dDf305F5
TOKEN=0x8d23ed562f9ba8d4d5dfecf601bbf7be8fd27777
AMOUNT=1158963227604141954654  # all ZigZag

# Approve ZigZag to NullRouter
cast send $TOKEN "approve(address,uint256)" 0x1B1Fee89A381E595Fe6536b99Ba91F3E16e9601a $AMOUNT \
  --legacy --rpc-url https://monad-mainnet.g.alchemy.com/v2/REDACTED \
  --private-key $DEPLOYER_PRIVATE_KEY

echo "=== Approved. Selling ZigZag → MON ==="

# Swap ZigZag → WMON
cast send 0x1B1Fee89A381E595Fe6536b99Ba91F3E16e9601a \
  --legacy \
  --gas-limit 2000000 \
  --rpc-url https://monad-mainnet.g.alchemy.com/v2/REDACTED \
  --private-key $DEPLOYER_PRIVATE_KEY \
  "swap(address,address,uint256,uint256,uint256,(address,address,address,uint256,bytes),address)" \
  $TOKEN \
  0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A \
  $AMOUNT \
  0 \
  99999999999 \
  "($ADAPTER,$TOKEN,0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A,$AMOUNT,0x0000000000000000000000008d23ed562f9ba8d4d5dfecf601bbf7be8fd277770000000000000000000000000000000000000000000000000000000000000000)" \
  0x0000000000000000000000000000000000000000
