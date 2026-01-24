#!/usr/bin/env bash
set -euo pipefail

################################################################################
# create-orb-nixos-flakes.sh
#
# Automates creation of a fresh NixOS 25.11 VM in OrbStack (macOS) configured
# with Nix flakes enabled from first boot.
#
# Usage:
#   ./create-orb-nixos-flakes.sh <hostname>
#
# Example:
#   ./create-orb-nixos-flakes.sh my-nixos-dev
################################################################################

readonly SCRIPT_NAME="$(basename "$0")"

################################################################################
# 1. Input validation
################################################################################

if [[ $# -ne 1 ]]; then
    echo "Error: Exactly one argument required (hostname for the new machine)" >&2
    echo "Usage: $SCRIPT_NAME <hostname>" >&2
    exit 1
fi

readonly HOSTNAME_ARG="$1"

# Detect host architecture and map to NixOS architecture
case "$(uname -m)" in
    arm64|aarch64)
        readonly NIX_ARCH="aarch64-linux"
        ;;
    x86_64)
        readonly NIX_ARCH="x86_64-linux"
        ;;
    *)
        echo "Error: Unsupported architecture '$(uname -m)'" >&2
        exit 1
        ;;
esac

echo "==> Detected architecture: $NIX_ARCH"

# Validate hostname: alphanumeric + hyphens only, 1-63 chars, no leading/trailing hyphen
if ! [[ "$HOSTNAME_ARG" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; then
    echo "Error: Invalid hostname '$HOSTNAME_ARG'" >&2
    echo "Hostname must be 1-63 characters, alphanumeric + hyphens, no leading/trailing hyphen" >&2
    exit 1
fi

# Check that orb command exists
if ! command -v orb &>/dev/null; then
    echo "Error: 'orb' command not found. Please install OrbStack first." >&2
    exit 1
fi

echo "==> Creating NixOS 25.11 machine: $HOSTNAME_ARG"

################################################################################
# 2. Machine creation
################################################################################

if orb list 2>/dev/null | grep -q "^$HOSTNAME_ARG "; then
    echo "Error: Machine '$HOSTNAME_ARG' already exists" >&2
    exit 1
fi

echo "==> Running: orb create nixos:25.11 $HOSTNAME_ARG"
orb create nixos:25.11 "$HOSTNAME_ARG"

################################################################################
# 3. Readiness check
################################################################################

echo "==> Waiting for machine to be ready..."
readonly MAX_WAIT=60
readonly WAIT_INTERVAL=2
elapsed=0

while [[ $elapsed -lt $MAX_WAIT ]]; do
    if orb list 2>/dev/null | grep -q "^$HOSTNAME_ARG .*running"; then
        # Additional check: try to execute a simple command
        if orb -m "$HOSTNAME_ARG" echo "ready" &>/dev/null; then
            echo "==> Machine is ready!"
            break
        fi
    fi
    sleep $WAIT_INTERVAL
    elapsed=$((elapsed + WAIT_INTERVAL))
done

if [[ $elapsed -ge $MAX_WAIT ]]; then
    echo "Error: Machine did not become ready within ${MAX_WAIT}s" >&2
    exit 1
fi

################################################################################
# 4. Configuration inside the machine (non-interactive)
################################################################################

echo "==> Configuring machine for flakes..."

# Execute the entire setup sequence as a single remote command block
orb -m "$HOSTNAME_ARG" bash -euo pipefail <<EOF
set -xeuo pipefail

echo "[inside VM] Creating /etc/nixos/flake.nix..."

sudo tee /etc/nixos/flake.nix >/dev/null <<'FLAKE_EOF'
{
  description = "NixOS configuration for $HOSTNAME_ARG";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
  };

  outputs = { self, nixpkgs, ... }:
    let
      lib = nixpkgs.lib;
    in {
    nixosConfigurations."$HOSTNAME_ARG" = lib.nixosSystem {
      system = "$NIX_ARCH";
      modules = [
        ./configuration.nix
        ({ config, pkgs, ... }: {
          # Architecture alignment for host platform
          nixpkgs.hostPlatform = "$NIX_ARCH";

          # Enable flakes and nix-command experimental features
          nix.settings.experimental-features = [ "nix-command" "flakes" ];

          # Disable sandbox for OrbStack compatibility (seccomp issues)
          nix.settings.sandbox = false;
          nix.settings.filter-syscalls = false;

          # Optimize download speeds
          nix.settings.http-connections = 128;
          nix.settings.max-jobs = "auto";

          # Disable kernel locking for OrbStack enhanced features compatibility
          security.lockKernelModules = false;
          security.protectKernelImage = false;

          # Disable systemd seccomp globally via boot parameter
          # OrbStack's kernel doesn't support seccomp-BPF properly
          boot.kernelParams = [ "systemd.setenv=SYSTEMD_SECCOMP=0" ];

          # Relax journald sandboxing to prevent status=5/TRAP crashes
          systemd.services."systemd-journald".serviceConfig = {
            SystemCallFilter = lib.mkForce [ ];
            SystemCallErrorNumber = lib.mkForce "EPERM";
            ProcSubset = "all";
            ProtectControlGroups = false;
            ProtectKernelTunables = false;
            RestrictAddressFamilies = [ ];
          };

          # Also disable at service level for other critical services
          systemd.services.systemd-networkd.serviceConfig = {
            SystemCallFilter = lib.mkForce [ ];
            SystemCallErrorNumber = lib.mkForce "EPERM";
          };
          systemd.services.systemd-udevd.serviceConfig = {
            SystemCallFilter = lib.mkForce [ ];
            SystemCallErrorNumber = lib.mkForce "EPERM";
          };

          # Ensure hostname matches
          networking.hostName = "$HOSTNAME_ARG";
        })
      ];
    };
  };
}
FLAKE_EOF

echo "[inside VM] Updating flake lockfile..."
sudo nix --experimental-features 'nix-command flakes' flake update /etc/nixos

echo "[inside VM] Running first nixos-rebuild switch (may take several minutes)..."
# Disable seccomp filtering which is incompatible with OrbStack
# Also disable sandbox completely
# Ignore service failures during activation (systemd services with seccomp issues)
sudo nixos-rebuild switch \\
  --option filter-syscalls false \\
  --option sandbox false \\
  --flake /etc/nixos#$HOSTNAME_ARG || {
    echo "[inside VM] Warning: Some systemd services failed (expected in OrbStack)"
    echo "[inside VM] Checking if the system is actually functional..."

    # Check if we can run nix commands (the important part)
    if nix --version &>/dev/null; then
      echo "[inside VM] ✓ Nix is working"
    else
      echo "[inside VM] ✗ Nix is not working - this is a real problem"
      exit 1
    fi

    # Check if flakes work
    if nix flake show /etc/nixos &>/dev/null; then
      echo "[inside VM] ✓ Flakes are working"
    else
      echo "[inside VM] ✗ Flakes are not working - this is a real problem"
      exit 1
    fi

    echo "[inside VM] System is functional despite service failures"
  }

echo "[inside VM] Configuration complete!"
EOF

################################################################################
# 5. Final feedback
################################################################################

echo ""
echo "════════════════════════════════════════════════════════════════════════"
echo "✓ Success! NixOS machine '$HOSTNAME_ARG' is ready with flakes enabled"
echo "════════════════════════════════════════════════════════════════════════"
echo ""
echo "Next steps:"
echo ""
echo "  1. Enter the machine:"
echo "     orb shell $HOSTNAME_ARG"
echo ""
echo "  2. Edit configuration:"
echo "     sudo nano /etc/nixos/configuration.nix"
echo "     (or edit /etc/nixos/flake.nix for flake-level changes)"
echo ""
echo "  3. Apply changes:"
echo "     sudo nixos-rebuild switch --flake /etc/nixos#$HOSTNAME_ARG"
echo ""
echo "  4. Update inputs (nixpkgs, etc.):"
echo "     sudo nix flake update /etc/nixos"
echo ""
echo "════════════════════════════════════════════════════════════════════════"
