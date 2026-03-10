#!/usr/bin/env bash
#
# Launch hyperscale cluster using NixOS containers (declarative systemd-nspawn)
# This requires NixOS and uses the containers.nix module
#

set -e

# Configuration
NUM_SHARDS="${NUM_SHARDS:-1}"
VALIDATORS_PER_SHARD="${VALIDATORS_PER_SHARD:-8}"
BASE_P2P_PORT=9000
BASE_RPC_PORT=18080
CLEAN=true
BUILD=true
ACCOUNTS_PER_SHARD=16000
INITIAL_BALANCE=1000000
LOG_LEVEL="info"
MEMORY_LIMIT=""
CPU_QUOTA=""
LATENCY=0
LATENCY_NODES=1

# Subnet for the cluster
SUBNET="172.99.0.0/16"
GATEWAY="172.99.0.1"

SCRIPT_PATH=$(realpath "$0")
SCRIPTS_DIR=$(dirname "$SCRIPT_PATH")
ROOT_DIR=$(dirname "$SCRIPTS_DIR")
DATA_DIR="${DATA_DIR:-/var/lib/hyperscale/cluster-data}"
NIXOS_CONFIG_DIR="$ROOT_DIR/.nix/nixos-containers"

# Parse args
while [[ $# -gt 0 ]]; do
    case $1 in
        --shards) NUM_SHARDS="$2"; shift 2 ;;
        --validators-per-shard) VALIDATORS_PER_SHARD="$2"; shift 2 ;;
        --clean) CLEAN=true; shift ;;
        --build) BUILD="$2"; shift 2 ;;
        --memory) MEMORY_LIMIT="$2"; shift 2 ;;
        --cpus) CPU_QUOTA="$2"; shift 2 ;;
        --latency) LATENCY="$2"; shift 2 ;;
        --latency-nodes) LATENCY_NODES="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: $0 [options]"
            echo ""
            echo "Options:"
            echo "  --shards N               Number of shards (default: 1)"
            echo "  --validators-per-shard M Validators per shard (default: 8)"
            echo "  --clean                  Remove existing data directories"
            echo "  --build true|false       Build binaries (default: true)"
            echo ""
            echo "Resource Limits & Network Simulation:"
            echo "  --memory LIMIT           Memory limit per validator (e.g. 512M, 1G)"
            echo "  --cpus QUOTA             CPU quota percentage per validator (e.g. 50 = 0.5 cores)"
            echo "  --latency MS             Artificial network latency in ms (e.g. 100)"
            echo "  --latency-nodes N        Number of nodes to apply latency to, starting from 0 (default: 1)"
            echo ""
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

TOTAL_VALIDATORS=$((NUM_SHARDS * VALIDATORS_PER_SHARD))

# Validate minimum validators per shard
if [ "$VALIDATORS_PER_SHARD" -lt 4 ]; then
    echo "ERROR: Minimum 4 validators per shard required for BFT consensus."
    echo "       With 3 or less validators, the cluster will not work."
    echo "       Use --validators-per-shard 4 or higher."
    exit 1
fi

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "ERROR: This script must be run as root (NixOS container management requires root)"
    echo "       Run: sudo $0 $*"
    exit 1
fi

# Check if on NixOS
if [ ! -f /etc/NIXOS ]; then
    echo "ERROR: This script requires NixOS"
    echo "       Use launch-systemd-containers.sh or launch-docker-compose.sh instead"
    exit 1
fi

echo "=== Hyperscale NixOS Containers Cluster ==="
echo "Total validators: $TOTAL_VALIDATORS"

SPAM_BIN="$ROOT_DIR/target/release/hyperscale-spammer"
KEY_BIN="$ROOT_DIR/target/release/hyperscale-keygen"

# Build
if [ "$BUILD" = true ]; then
    echo "Building..."
    cd "$ROOT_DIR" && \
        nix build .#default && \
        cargo build \
            --release \
            --bin hyperscale-keygen \
            --bin hyperscale-spammer \
            2>&1 | tail -3
fi

# Cleanup
if [ "$CLEAN" = true ]; then
    echo "Cleaning..."
    # Stop all containers
    for i in $(seq 0 $((TOTAL_VALIDATORS - 1))); do
        nixos-container stop "hyperscale-validator-$i" 2>/dev/null || true
        nixos-container destroy "hyperscale-validator-$i" 2>/dev/null || true
    done
    rm -rf "$DATA_DIR"
fi

mkdir -p "$DATA_DIR"
mkdir -p "$NIXOS_CONFIG_DIR"

# Generate keys
echo "Generating keys..."
declare -a PUBLIC_KEYS PEER_IDS
for i in $(seq 0 $((TOTAL_VALIDATORS - 1))); do
    mkdir -p "$DATA_DIR/validator-$i/data"
    SEED_HEX=$(printf '%064x' $((12345 + i)))
    echo "$SEED_HEX" | xxd -r -p > "$DATA_DIR/validator-$i/signing.key"
    OUTPUT=$("$KEY_BIN" "$SEED_HEX")
    PUBLIC_KEYS[$i]=$(echo "$OUTPUT" | awk '{print $1}')
    PEER_IDS[$i]=$(echo "$OUTPUT" | awk '{print $2}')
done

# Bootstrap peers
BOOTSTRAP_PEERS=""
for shard in $(seq 0 $((NUM_SHARDS - 1))); do
    first=$((shard * VALIDATORS_PER_SHARD))
    IP="172.99.0.$((10 + first))"
    PEER_ID="${PEER_IDS[$first]}"
    [ -n "$BOOTSTRAP_PEERS" ] && BOOTSTRAP_PEERS="$BOOTSTRAP_PEERS,"
    BOOTSTRAP_PEERS="$BOOTSTRAP_PEERS\"/ip4/$IP/udp/9000/quic-v1/p2p/$PEER_ID\",\"/ip4/$IP/tcp/9000\""
done

# Genesis
GENESIS="[genesis]"
for j in $(seq 0 $((TOTAL_VALIDATORS - 1))); do
    GENESIS="$GENESIS
[[genesis.validators]]
id = $j
shard = $((j / VALIDATORS_PER_SHARD))
public_key = \"${PUBLIC_KEYS[$j]}\"
voting_power = 1"
done

# Generate genesis balances once per shard
echo "Generating genesis balances..."
declare -a SHARD_BALANCES
for shard in $(seq 0 $((NUM_SHARDS - 1))); do
    SHARD_BALANCES[$shard]=$("$SPAM_BIN" genesis \
        --num-shards "$NUM_SHARDS" \
        --accounts-per-shard "$ACCOUNTS_PER_SHARD" \
        --balance "$INITIAL_BALANCE" \
        --shard $shard)
done

# Configs
echo "Generating configs..."
for i in $(seq 0 $((TOTAL_VALIDATORS - 1))); do
    SHARD=$((i / VALIDATORS_PER_SHARD))
    BALANCES="${SHARD_BALANCES[$SHARD]}"
    IP="172.99.0.$((10 + i))"

    cat > "$DATA_DIR/validator-$i/config.toml" <<EOF
[node]
validator_id = $i
shard = $SHARD
num_shards = $NUM_SHARDS
key_path = "/home/hyperscalers/signing.key"
data_dir = "/home/hyperscalers/data"

[network]
listen_addr = "/ip4/0.0.0.0/udp/9000/quic-v1"
external_addr = "/ip4/$IP/udp/9000/quic-v1"
upnp_enabled = false
bootstrap_peers = [$BOOTSTRAP_PEERS]
version_interop_mode = "relaxed"
tcp_fallback_port_range = "9000-9000"

[consensus]
proposal_interval_ms = 300
view_change_timeout_ms = 3000

[metrics]
enabled = true
listen_addr = "0.0.0.0:8080"

$GENESIS
$BALANCES
EOF
done

# Generate NixOS configuration for containers
echo "Generating NixOS container configuration..."
MEMORY_OPTS=""
CPU_OPTS=""
if [ -n "$MEMORY_LIMIT" ]; then
    MEMORY_OPTS="memoryLimit = \"$MEMORY_LIMIT\";"
fi
if [ -n "$CPU_QUOTA" ]; then
    CPU_OPTS="cpuQuota = $CPU_QUOTA;"
fi

cat > "$NIXOS_CONFIG_DIR/containers.nix" <<EOF
# Auto-generated NixOS container configuration
{ config, pkgs, ... }:

{
  imports = [
    $ROOT_DIR/nix/containers.nix
  ];

  services.hyperscale-containers = {
    enable = true;
    numShards = $NUM_SHARDS;
    validatorsPerShard = $VALIDATORS_PER_SHARD;
    bridgeName = "br-hyperscale";
    subnet = "$SUBNET";
    gateway = "$GATEWAY";
    baseP2PPort = $BASE_P2P_PORT;
    baseRPCPort = $BASE_RPC_PORT;
    dataDir = "$DATA_DIR";
    logLevel = "$LOG_LEVEL";
    $MEMORY_OPTS
    $CPU_OPTS
    latency = $LATENCY;
    latencyNodes = $LATENCY_NODES;
  };
}
EOF

# Create individual container configurations
echo "Creating containers..."
for i in $(seq 0 $((TOTAL_VALIDATORS - 1))); do
    SHARD=$((i / VALIDATORS_PER_SHARD))
    IP="172.99.0.$((10 + i))"

    nixos-container create "hyperscale-validator-$i" \
        --config-file <(cat <<EOF
{ config, pkgs, ... }:

{
  system.stateVersion = "24.05";

  networking.useHostResolvConf = false;

  environment.systemPackages = with pkgs; [
    (import $ROOT_DIR { }).packages.\${pkgs.system}.default
  ];

  # Create hyperscalers user
  users.users.hyperscalers = {
    isNormalUser = true;
    uid = 1001;
    group = "hyperscalers";
    home = "/home/hyperscalers";
  };
  users.groups.hyperscalers.gid = 1001;

  # Bind mounts
  boot.isContainer = true;

  systemd.services.hyperscale-validator = {
    description = "Hyperscale Validator $i (Shard $SHARD)";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    serviceConfig = {
      Type = "simple";
      User = "hyperscalers";
      Group = "hyperscalers";
      WorkingDirectory = "/home/hyperscalers";
      ExecStart = "${pkgs.hyperscale-validator or "$ROOT_DIR/result/bin/hyperscale-validator"} --config /home/hyperscalers/config.toml";
      Restart = "unless-stopped";
      RestartSec = "5s";
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ReadWritePaths = [ "/home/hyperscalers/data" ];
    };

    environment = {
      RUST_LOG = "warn,hyperscale=$LOG_LEVEL,libp2p_gossipsub=error";
    };
  };

  networking.firewall.allowedTCPPorts = [ 8080 9000 ];
  networking.firewall.allowedUDPPorts = [ 9000 ];
}
EOF
)

    # Set up bind mounts
    nixos-container update "hyperscale-validator-$i" \
        --bind-ro="$DATA_DIR/validator-$i/config.toml:/home/hyperscalers/config.toml" \
        --bind-ro="$DATA_DIR/validator-$i/signing.key:/home/hyperscalers/signing.key" \
        --bind="$DATA_DIR/validator-$i/data:/home/hyperscalers/data" 2>/dev/null || true
done

# Start containers
echo "Starting containers..."
for i in $(seq 0 $((TOTAL_VALIDATORS - 1))); do
    nixos-container start "hyperscale-validator-$i"
done

# Wait for containers to be ready
echo "Waiting for containers to start..."
sleep 10

# Check container status
echo "Checking container status..."
FAILED_COUNT=0
for i in $(seq 0 $((TOTAL_VALIDATORS - 1))); do
    if ! nixos-container status "hyperscale-validator-$i" | grep -q "up"; then
        echo "  WARNING: validator-$i not running"
        FAILED_COUNT=$((FAILED_COUNT + 1))
    fi
done

if [ $FAILED_COUNT -gt 0 ]; then
    echo ""
    echo "ERROR: $FAILED_COUNT validators failed to start"
    echo "Check logs with: nixos-container run hyperscale-validator-0 -- journalctl -u hyperscale-validator"
    exit 1
fi

# Build endpoints
ENDPOINTS=""
for i in $(seq 0 $((TOTAL_VALIDATORS - 1))); do
    [ -n "$ENDPOINTS" ] && ENDPOINTS="$ENDPOINTS,"
    ENDPOINTS="${ENDPOINTS}http://172.99.0.$((10 + i)):8080"
done

echo ""
echo "=== Cluster Started ==="
echo "Management:"
echo "  Status:  nixos-container status hyperscale-validator-0"
echo "  Logs:    nixos-container run hyperscale-validator-0 -- journalctl -u hyperscale-validator -f"
echo "  Shell:   nixos-container root-login hyperscale-validator-0"
echo "  Stop:    for i in {0..$((TOTAL_VALIDATORS - 1))}; do nixos-container stop hyperscale-validator-\$i; done"
echo "  Destroy: for i in {0..$((TOTAL_VALIDATORS - 1))}; do nixos-container destroy hyperscale-validator-\$i; done"
echo ""

# Smoke test
echo "Running smoke test..."
if sudo -u "$SUDO_USER" "$SPAM_BIN" smoke-test \
    --endpoints "$ENDPOINTS" \
    --num-shards "$NUM_SHARDS" \
    --validators-per-shard "$VALIDATORS_PER_SHARD" \
    --wait-ready \
    --timeout 60s; then

    echo "------------------------------------------------------------------"
    echo "Success! Cluster is reaching consensus and producing blocks."
    echo ""
    echo "Endpoints:"
    for i in $(seq 0 $((TOTAL_VALIDATORS - 1))); do
        echo "  http://172.99.0.$((10 + i)):8080"
    done
    echo ""
    echo "To run the spammer manually:"
    echo "./target/release/hyperscale-spammer run \\"
    echo "    --endpoints \"$ENDPOINTS\" \\"
    echo "    --num-shards \"$NUM_SHARDS\" \\"
    echo "    --validators-per-shard \"$VALIDATORS_PER_SHARD\" \\"
    echo "    --tps 150 \\"
    echo "    --duration 60s --cross-shard-ratio 0 --measure-latency"
    echo "------------------------------------------------------------------"
else
    echo "------------------------------------------------------------------"
    echo "ERROR: Smoke test failed. Cluster left running for inspection."
    echo "Check logs: nixos-container run hyperscale-validator-0 -- journalctl -u hyperscale-validator -f"
    echo "------------------------------------------------------------------"
    exit 1
fi
