#!/usr/bin/env bash
# One-command NullRouter UUPS upgrade (dff96f8 + 90f6ddf fund-safety fixes).
# forge script flakes on Monad, so this drives the reliable path: forge create the
# new impl, then cast send upgradeToAndCall on the proxy — and verifies the result.
#
# The OWNER runs this (it signs with DEPLOYER_PRIVATE_KEY from .env). Run:
#   bash upgrade-router.sh
set -euo pipefail

cd "$(dirname "$0")"
[ -f .env ] && set -a && . ./.env && set +a
: "${DEPLOYER_PRIVATE_KEY:?DEPLOYER_PRIVATE_KEY not set in packages/contracts/.env}"

PROXY=0x1B1Fee89A381E595Fe6536b99Ba91F3E16e9601a
IMPL_SLOT=0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc
RPC=https://rpc.monad.xyz

norm() { echo "0x${1: -40}" | tr 'A-F' 'a-f'; }

DEPLOYER=$(cast wallet address --private-key "$DEPLOYER_PRIVATE_KEY")
OWNER=$(cast call "$PROXY" "owner()(address)" --rpc-url "$RPC")
OLD_IMPL=$(norm "$(cast storage "$PROXY" "$IMPL_SLOT" --rpc-url "$RPC")")
echo "deployer : $DEPLOYER"
echo "owner    : $OWNER"
echo "old impl : $OLD_IMPL   (rollback target — write this down)"

if [ "$(echo "$DEPLOYER" | tr 'A-F' 'a-f')" != "$(echo "$OWNER" | tr 'A-F' 'a-f')" ]; then
  echo "✗ deployer != owner — this key can't authorize the upgrade. Aborting."; exit 1
fi

echo "→ [1/2] deploying new NullRouter implementation…"
CREATE_OUT=$(forge create src/NullRouter.sol:NullRouter \
  --rpc-url "$RPC" --private-key "$DEPLOYER_PRIVATE_KEY" --legacy --broadcast 2>&1)
echo "$CREATE_OUT"
NEW_IMPL=$(echo "$CREATE_OUT" | grep -ioE "Deployed to: 0x[0-9a-fA-F]{40}" | grep -oE "0x[0-9a-fA-F]{40}" | head -1)
[ -z "$NEW_IMPL" ] && { echo "✗ could not parse new impl address from forge create output"; exit 1; }
echo "new impl : $NEW_IMPL"

echo "→ [2/2] upgradeToAndCall on the proxy…"
cast send "$PROXY" "upgradeToAndCall(address,bytes)" "$NEW_IMPL" 0x \
  --rpc-url "$RPC" --private-key "$DEPLOYER_PRIVATE_KEY" --legacy --gas-limit 4000000

sleep 3
CUR_IMPL=$(norm "$(cast storage "$PROXY" "$IMPL_SLOT" --rpc-url "$RPC")")
echo "----------------------------------------------"
if [ "$CUR_IMPL" = "$(echo "$NEW_IMPL" | tr 'A-F' 'a-f')" ]; then
  echo "✅ UPGRADE OK — impl slot now $CUR_IMPL"
  echo "   rollback: cast send $PROXY 'upgradeToAndCall(address,bytes)' $OLD_IMPL 0x --rpc-url $RPC --private-key \$DEPLOYER_PRIVATE_KEY --legacy --gas-limit 4000000"
else
  echo "⚠️ impl slot is $CUR_IMPL (expected $NEW_IMPL) — upgrade did NOT take. Check the cast send output above."
  exit 1
fi
