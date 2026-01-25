#!/usr/bin/env bash
#
# Stop all hyperscale systemd-nspawn containers
#

set -e

echo "=== Stopping Hyperscale Cluster ==="

# Stop all hyperscale systemd units
echo "Stopping all hyperscale-* systemd units..."
sudo systemctl stop 'hyperscale-*' 2>/dev/null || true

# Wait for units to stop
sleep 2

# Check status
RUNNING=$(systemctl list-units --all 'hyperscale-*' --no-legend 2>/dev/null | wc -l)

if [ "$RUNNING" -eq 0 ]; then
    echo "✓ All containers stopped"
else
    echo "Remaining units:"
    systemctl list-units --all 'hyperscale-*' --no-legend
fi

echo ""
echo "To remove data: rm -rf ./cluster-data"
