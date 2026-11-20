#!/usr/bin/env bash
# Deploy SUBSECOND end-to-end: Base Sepolia origin side, then Reactive Lasna reactive side.
# Requires DEPLOYER_KEY (0x...) funded with Base Sepolia ETH (deploy + faucet) and, after the
# faucet step, lREACT on Lasna. Run: DEPLOYER_KEY=0x... ./scripts/deploy.sh
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.foundry/bin:$PATH"
: "${DEPLOYER_KEY:?export DEPLOYER_KEY=0x... first}"

BASE_RPC=https://sepolia.base.org
LASNA_RPC=https://lasna-rpc.rnk.dev/
BASE_FAUCET=0x2afaFD298b23b62760711756088F75B7409f5967   # send Sepolia ETH -> lREACT (1:100)

DEPLOYER=$(cast wallet address --private-key "$DEPLOYER_KEY")
mkdir -p deployments
echo "deployer: $DEPLOYER"

# 1) Mint lREACT by sending Base Sepolia ETH to the Lasna faucet (skip with SKIP_FAUCET=1).
if [[ "${SKIP_FAUCET:-0}" != "1" ]]; then
  echo "requesting lREACT from faucet..."
  cast send "$BASE_FAUCET" "request(address)" "$DEPLOYER" \
    --value 0.1ether --private-key "$DEPLOYER_KEY" --rpc-url "$BASE_RPC"
  sleep 5
fi

# 2) Predict the Lasna reactive address so the executor can bind it as callbackSender.
NONCE=$(cast nonce "$DEPLOYER" --rpc-url "$LASNA_RPC")
PREDICTED=$(cast compute-address "$DEPLOYER" --nonce "$NONCE" | awk '{print $NF}')
export PREDICTED_REACTIVE="$PREDICTED"
echo "predicted reactive (Lasna nonce $NONCE): $PREDICTED"

# 3) Origin side on Base Sepolia.
forge script script/DeployOrigin.s.sol --rpc-url "$BASE_RPC" --broadcast

# 4) Reactive side on Lasna (funded via payable constructor).
forge script script/DeployReactive.s.sol --rpc-url "$LASNA_RPC" --broadcast

# 5) Fund the executor with Base Sepolia ETH so it can pay the callback proxy.
EXECUTOR=$(python3 -c "import json;print(json.load(open('deployments/origin.json'))['executor'])")
cast send "$EXECUTOR" --value 0.05ether --private-key "$DEPLOYER_KEY" --rpc-url "$BASE_RPC"

echo "DONE. reactive=$PREDICTED executor=$EXECUTOR"
echo "addresses in deployments/origin.json and deployments/lasna.json"
