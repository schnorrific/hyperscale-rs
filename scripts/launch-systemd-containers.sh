#!/usr/bin/env bash
#
# Launch hyperscale cluster using systemd-nspawn containers via systemd-run
# This works on NixOS 25.11 and creates proper isolated containers
#

set -e

# Configuration
NUM_SHARDS="${NUM_SHARDS:-1}"
VALIDATORS_PER_SHARD="${VALIDATORS_PER_SHARD:-8}"
BASE_RPC_PORT=28080
CLEAN=true
BUILD=true
ACCOUNTS_PER_SHARD=16000
INITIAL_BALANCE=1000000
LOG_LEVEL="info"
MONITORING=false

SCRIPT_PATH=$(realpath "$0")
SCRIPTS_DIR=$(dirname "$SCRIPT_PATH")
ROOT_DIR=$(dirname "$SCRIPTS_DIR")
DATA_DIR="${DATA_DIR:-$ROOT_DIR/.nix/cluster-data_systemd}"

# Parse args
while [[ $# -gt 0 ]]; do
    case $1 in
        --shards) NUM_SHARDS="$2"; shift 2 ;;
        --validators-per-shard) VALIDATORS_PER_SHARD="$2"; shift 2 ;;
        --clean) CLEAN=true; shift ;;
        --build) BUILD="$2"; shift 2 ;;
        --monitoring) MONITORING=true; shift ;;
        *) shift ;;
    esac
done

TOTAL_VALIDATORS=$((NUM_SHARDS * VALIDATORS_PER_SHARD))

echo "=== Hyperscale systemd-nspawn Cluster ==="
echo "Total validators: $TOTAL_VALIDATORS"

SPAM_BIN="$ROOT_DIR/target/release/hyperscale-spammer"
KEY_BIN="$ROOT_DIR/target/release/hyperscale-keygen"
VALIDATOR_BIN="$ROOT_DIR/target/release/hyperscale-validator"

# Build
if [ "$BUILD" = true ]; then
    echo "Building..."
    cd "$ROOT_DIR" && \
        cargo build \
            --release \
            --bin hyperscale-validator \
            --bin hyperscale-keygen \
            --bin hyperscale-spammer \
            2>&1 | tail -3
fi

# Cleanup
if [ "$CLEAN" = true ]; then
    echo "Cleaning..."
    # Stop all hyperscale units
    sudo systemctl stop 'hyperscale-*' 2>/dev/null || true
    # Reset failed units to clear any previous state
    sudo systemctl reset-failed 'hyperscale-*' 2>/dev/null || true
    # Wait for units to fully stop
    sleep 1
    sudo rm -rf "$DATA_DIR"
fi

mkdir -p "$DATA_DIR"

# Generate keys and create minimal container roots
echo "Generating keys..."
declare -a PUBLIC_KEYS PEER_IDS
for i in $(seq 0 $((TOTAL_VALIDATORS - 1))); do
    mkdir -p "$DATA_DIR/validator-$i/data"
    mkdir -p "$DATA_DIR/validator-$i/root"
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
    [ -n "$BOOTSTRAP_PEERS" ] && BOOTSTRAP_PEERS="$BOOTSTRAP_PEERS,"
    BOOTSTRAP_PEERS="$BOOTSTRAP_PEERS\"/ip4/127.0.0.1/udp/$((19000 + first))/quic-v1/p2p/${PEER_IDS[$first]}\""
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

# Generate genesis balances once per shard (OPTIMIZATION 1)
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

    cat > "$DATA_DIR/validator-$i/config.toml" <<EOF
[node]
validator_id = $i
shard = $((i / VALIDATORS_PER_SHARD))
num_shards = $NUM_SHARDS
key_path = "/data/signing.key"
data_dir = "/data/data"

[network]
listen_addr = "/ip4/0.0.0.0/udp/$((19000 + i))/quic-v1"
external_addr = "/ip4/127.0.0.1/udp/$((19000 + i))/quic-v1"
upnp_enabled = false
bootstrap_peers = [$BOOTSTRAP_PEERS]
version_interop_mode = "relaxed"
tcp_fallback_port_range = "$((19000 + i))-$((19000 + i))"

[consensus]
proposal_interval_ms = 300
view_change_timeout_ms = 3000

[metrics]
enabled = true
listen_addr = "0.0.0.0:$((BASE_RPC_PORT + i))"

$GENESIS
$BALANCES
EOF
done

# Start containers in parallel (OPTIMIZATION 2 & 3)
# Note: Using minimal container roots with --ephemeral (OPTIMIZATION 3b)
# This avoids the 4min overhead while maintaining isolation
echo "Starting containers in parallel..."
PIDS=()
for i in $(seq 0 $((TOTAL_VALIDATORS - 1))); do
    (
        sudo systemd-run \
            --unit="hyperscale-validator-$i" \
            --property="Restart=on-failure" \
            systemd-nspawn \
                --quiet \
                --directory="$DATA_DIR/validator-$i/root" \
                --ephemeral \
                --private-users=no \
                --bind-ro=/nix:/nix \
                --bind="$DATA_DIR/validator-$i:/data" \
                --bind-ro="$VALIDATOR_BIN:/bin/validator" \
                --setenv=RUST_LOG="warn,hyperscale=$LOG_LEVEL" \
                /bin/validator --config /data/config.toml 2>&1 | grep -q 'Running as unit'
    ) &
    PIDS+=($!)
done

# Wait for all systemd-run commands to complete
echo "  Waiting for systemd-run to complete..."
for pid in "${PIDS[@]}"; do
    wait "$pid" || true
done
echo "  All $TOTAL_VALIDATORS validators started"

echo ""
echo "Checking container status..."
FAILED_COUNT=0
for i in $(seq 0 $((TOTAL_VALIDATORS - 1))); do
    if ! sudo systemctl is-active --quiet "hyperscale-validator-$i"; then
        echo "  WARNING: validator-$i not active"
        echo "  Status:"
        sudo systemctl status "hyperscale-validator-$i" --no-pager -l || true
        echo "  Logs:"
        sudo journalctl -u "hyperscale-validator-$i" -n 20 --no-pager || true
        FAILED_COUNT=$((FAILED_COUNT + 1))
    fi
done

if [ $FAILED_COUNT -gt 0 ]; then
    echo ""
    echo "ERROR: $FAILED_COUNT validators failed to start"
    exit 1
fi

echo "Waiting for startup..."
sleep 8

# Build endpoints
ENDPOINTS=""
for i in $(seq 0 $((TOTAL_VALIDATORS - 1))); do
    [ -n "$ENDPOINTS" ] && ENDPOINTS="$ENDPOINTS,"
    ENDPOINTS="${ENDPOINTS}http://127.0.0.1:$((BASE_RPC_PORT + i))"
done

# Start monitoring stack
if [ "$MONITORING" = true ]; then
    echo ""
    echo "Starting monitoring stack..."

    # Generate Prometheus config
    PROM_CONFIG="$DATA_DIR/prometheus.yml"
    cat > "$PROM_CONFIG" <<EOF
global:
  scrape_interval: 5s

scrape_configs:
  - job_name: 'hyperscale'
    static_configs:
EOF
    for i in $(seq 0 $((TOTAL_VALIDATORS - 1))); do
        cat >> "$PROM_CONFIG" <<EOF
      - targets: ['127.0.0.1:$((BASE_RPC_PORT + i))']
        labels:
          shard: '$((i / VALIDATORS_PER_SHARD))'
          node: 'validator-$i'
EOF
    done

    mkdir -p "$DATA_DIR/prometheus-data" "$DATA_DIR/grafana-data"

    # Start Prometheus container
    if command -v prometheus >/dev/null 2>&1; then
        echo "  Starting Prometheus..."
        sudo systemd-run \
            --unit="hyperscale-prometheus" \
            --property="Restart=on-failure" \
            systemd-nspawn \
                --quiet \
                --ephemeral \
                --bind-ro=/nix:/nix \
                --bind="$PROM_CONFIG:/etc/prometheus/prometheus.yml:ro" \
                --bind="$DATA_DIR/prometheus-data:/prometheus" \
                --bind-ro="$(command -v prometheus):/bin/prometheus" \
                /bin/prometheus \
                    --config.file=/etc/prometheus/prometheus.yml \
                    --storage.tsdb.path=/prometheus \
                    --web.listen-address=0.0.0.0:9090
        echo "    Prometheus: http://localhost:9090"
    fi

    # Start Grafana container
    if command -v grafana-server >/dev/null 2>&1; then
        echo "  Starting Grafana..."

        # Generate Grafana config
        GRAFANA_CONFIG="$DATA_DIR/grafana.ini"
        cat > "$GRAFANA_CONFIG" <<EOF
[paths]
data = /var/lib/grafana
logs = /var/log/grafana

[server]
http_port = 3000

[security]
admin_user = admin
admin_password = admin

[auth.anonymous]
enabled = true
org_role = Admin
EOF

        sudo systemd-run \
            --unit="hyperscale-grafana" \
            --property="Restart=on-failure" \
            systemd-nspawn \
                --quiet \
                --ephemeral \
                --bind-ro=/nix:/nix \
                --bind="$GRAFANA_CONFIG:/etc/grafana/grafana.ini:ro" \
                --bind="$DATA_DIR/grafana-data:/var/lib/grafana" \
                --bind-ro="$(command -v grafana-server):/bin/grafana-server" \
                /bin/grafana-server \
                    --config=/etc/grafana/grafana.ini \
                    --homepath=/usr/share/grafana
        echo "    Grafana: http://localhost:3000"
    fi
fi

echo ""
echo "=== Cluster Started ==="
echo "Management:"
echo "  Status: sudo systemctl status hyperscale-validator-0"
echo "  Logs:   sudo journalctl -u hyperscale-validator-0 -f"
echo "  Stop:   sudo systemctl stop 'hyperscale-*'"
if [ "$MONITORING" = true ]; then
    echo "  Monitor Status: sudo systemctl status hyperscale-prometheus hyperscale-grafana"
fi
echo ""

# Smoke test
echo "Running smoke test..."
"$SPAM_BIN" smoke-test \
    --endpoints "$ENDPOINTS" \
    --num-shards "$NUM_SHARDS" \
    --validators-per-shard "$VALIDATORS_PER_SHARD" \
    --wait-ready \
    --timeout 60s

echo ""
echo "✓ Cluster ready!"
echo "  Endpoints:"
for i in $(seq 0 $((TOTAL_VALIDATORS - 1))); do
    echo "    http://127.0.0.1:$((BASE_RPC_PORT + i))"
done
if [ "$MONITORING" = true ]; then
    echo "  Prometheus: http://localhost:9090"
    echo "  Grafana: http://localhost:3000"
fi
