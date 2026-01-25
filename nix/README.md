# NixOS systemd-nspawn Containers for Hyperscale

This directory contains NixOS modules for running Hyperscale validators in `systemd-nspawn` containers as an alternative to Docker.

## Overview

The NixOS container configuration provides:

- **Lightweight containers**: Using systemd-nspawn instead of Docker
- **Declarative configuration**: NixOS modules for reproducible deployments
- **Resource management**: CPU and memory limits via systemd cgroups
- **Network isolation**: Custom bridge networking with static IPs
- **Monitoring stack**: Optional Prometheus, Grafana, and Jaeger containers

## Components

### Modules

1. **`containers.nix`** - Main module for validator containers
   - Creates systemd-nspawn containers for each validator
   - Configures networking with custom subnet (172.99.0.0/16)
   - Manages bind mounts for configs and data
   - Applies resource limits and network conditions

2. **`validator-service.nix`** - Standalone validator service
   - Can run validators directly on host (no containers)
   - Useful for bare-metal deployments
   - Includes systemd service with healthchecks

3. **`monitoring.nix`** - Monitoring stack containers
   - Prometheus for metrics collection
   - Grafana for dashboards and visualization
   - Jaeger for distributed tracing (optional)

### Scripts

- **`scripts/launch-nix-containers.sh`** - Launch cluster with systemd-nspawn
- **`scripts/stop-nix-containers.sh`** - Stop and optionally remove containers

## Requirements

- **NixOS** or Linux system with systemd container support
- **systemd-nspawn** and **machinectl** commands available
- **Root/sudo access** for container management
- **Rust toolchain** (via Nix flake or system)

## Quick Start

### Using the Scripts (Simple)

```bash
# Build and launch cluster (each validator in its own systemd-nspawn container)
nix develop --command launch-nix-cluster

# With monitoring stack (Prometheus + Grafana also in containers)
nix develop --command bash ./scripts/launch-systemd-containers.sh --monitoring

# With custom configuration
nix develop --command bash ./scripts/launch-systemd-containers.sh \
    --shards 2 \
    --validators-per-shard 4 \
    --monitoring

# Stop all containers
nix develop --command stop-nix-cluster
# Or: sudo systemctl stop 'hyperscale-*'

# Check status
sudo systemctl status hyperscale-validator-0
sudo journalctl -u hyperscale-validator-0 -f
```

**Implementation**: Each validator and monitoring component runs in its own **systemd-nspawn container** managed by systemd via `systemd-run`. Containers use bind mounts for configs/data and are isolated with their own namespaces. This provides full container isolation while being lightweight and manageable with standard systemd tools (`systemctl`, `journalctl`).

### Using NixOS Configuration (Advanced)

For full integration with NixOS system configuration:

```nix
# /etc/nixos/configuration.nix
{
  imports = [
    /path/to/hyperscale-rs/nix/containers.nix
    /path/to/hyperscale-rs/nix/monitoring.nix
  ];

  services.hyperscale-containers = {
    enable = true;
    numShards = 2;
    validatorsPerShard = 4;
    dataDir = "/var/lib/hyperscale/cluster-data";
    logLevel = "info";

    # Optional resource limits
    memoryLimit = "1G";
    cpuQuota = 100;  # 100% = 1 core
  };

  services.hyperscale-monitoring = {
    enable = true;
    prometheusEnable = true;
    grafanaEnable = true;
    jaegerEnable = false;

    # Auto-discover validator targets
    validatorTargets = map (i: "172.99.0.${toString (10 + i)}:8080")
                          (lib.range 0 7);
  };
}
```

Then rebuild:

```bash
sudo nixos-rebuild switch
```

## Architecture

### Network Layout

```
Host System (172.99.0.1)
    │
    ├─ br-hyperscale (bridge)
    │   │
    │   ├─ validator-0 (172.99.0.10:9000, :18080)
    │   ├─ validator-1 (172.99.0.11:9001, :18081)
    │   ├─ ...
    │   ├─ validator-N (172.99.0.X:900X, :1808X)
    │   │
    │   ├─ prometheus (172.99.0.5:9090)
    │   ├─ grafana (172.99.0.6:3000)
    │   └─ jaeger (172.99.0.7:16686, :4317)
```

### Container Structure

Each validator container has:

- **Bind mounts**:
  - `/home/hyperscalers/config.toml` → Host config file
  - `/home/hyperscalers/data` → Host data directory
  - `/home/hyperscalers/signing.key` → Host key file

- **Network**: Virtual ethernet pair connected to host bridge

- **Systemd service**: Runs `hyperscale-validator` with auto-restart

- **Resource limits** (optional):
  - `MemoryMax` - systemd memory limit
  - `CPUQuota` - CPU percentage limit

## Management

### Container Operations

```bash
# List running containers
sudo machinectl list

# Check container status
sudo machinectl status validator-0

# View container logs
sudo journalctl -M validator-0 -u hyperscale-validator

# Get shell in container
sudo machinectl shell validator-0

# Stop a specific container
sudo machinectl stop validator-0

# Remove container
sudo machinectl remove validator-0
```

### Network Management

```bash
# View bridge status
ip addr show br-hyperscale

# List bridge interfaces
bridge link

# Delete bridge (after stopping all containers)
sudo ip link delete br-hyperscale
```

## Comparison with Docker

| Feature | Docker | systemd-nspawn |
|---------|--------|----------------|
| **Startup time** | ~1-2s per container | ~500ms per container |
| **Memory overhead** | ~100MB per container | ~10MB per container |
| **Image management** | Docker images/layers | NixOS closures |
| **Networking** | Docker bridge/macvlan | systemd-networkd |
| **Resource limits** | docker-compose deploy | systemd cgroups |
| **Isolation** | Full container isolation | Namespace isolation |
| **Root required** | Docker daemon (root) | Yes (machinectl) |

### Advantages of systemd-nspawn

- **Lighter weight**: Less overhead than Docker
- **Native systemd**: Better integration with system services
- **Faster startup**: Containers boot in milliseconds
- **Simpler networking**: Direct integration with systemd-networkd
- **NixOS integration**: Declarative container configs

### When to Use Docker Instead

- **Cross-platform**: Docker works on macOS/Windows
- **Ecosystem**: More tools and pre-built images
- **Distribution**: Easier to share container images
- **Development**: Docker Desktop provides better UX

## Troubleshooting

### Containers won't start

```bash
# Check systemd-nspawn is available
systemd-nspawn --version

# Check if bridge exists
ip link show br-hyperscale

# Check kernel modules
sudo modprobe bridge
sudo modprobe br_netfilter

# Enable IP forwarding
sudo sysctl -w net.ipv4.ip_forward=1
```

### Network connectivity issues

```bash
# Verify bridge is up
sudo ip link set br-hyperscale up

# Check container can reach host
sudo machinectl shell validator-0 -- ping 172.99.0.1

# Verify NAT rules (if needed for internet access)
sudo iptables -t nat -L POSTROUTING -v
```

### Permission errors

```bash
# Ensure data directory has correct permissions
chmod -R 755 /path/to/cluster-data

# Check if running as root/sudo
sudo -v
```

## Advanced Configuration

### Custom Network Simulation

Apply artificial latency and packet loss:

```bash
./scripts/launch-nix-containers.sh \
    --latency 100 \
    --latency-nodes 2  # Apply to first 2 validators
```

This uses Linux `tc` (traffic control) to simulate network conditions.

### Resource Constraints

Test under resource pressure:

```bash
./scripts/launch-nix-containers.sh \
    --memory 512M \
    --cpus 0.5  # 50% of one core
```

### Multiple Clusters

Run multiple clusters by changing the data directory:

```bash
# Cluster 1
DATA_DIR=/var/lib/hyperscale/cluster-1 \
    ./scripts/launch-nix-containers.sh

# Cluster 2 (different subnet needed)
DATA_DIR=/var/lib/hyperscale/cluster-2 \
    SUBNET=172.100.0.0/16 \
    ./scripts/launch-nix-containers.sh
```

## Development

### Testing Changes

```bash
# Check flake syntax
nix flake check

# Build package
nix build

# Enter dev shell
nix develop

# Test container module
nixos-rebuild build-vm -I nixos-config=./nix/test-vm.nix
```

### Contributing

When modifying the NixOS modules:

1. Test with `nixos-rebuild build-vm` first
2. Verify containers start and network correctly
3. Check validator logs for errors
4. Run smoke tests to verify consensus
5. Update this README with any new features

## References

- [systemd-nspawn documentation](https://www.freedesktop.org/software/systemd/man/systemd-nspawn.html)
- [NixOS Containers](https://nixos.org/manual/nixos/stable/#ch-containers)
- [systemd.resource-control](https://www.freedesktop.org/software/systemd/man/systemd.resource-control.html)
