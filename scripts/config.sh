#!/bin/bash
#
# ========== CONFIG EXPLAINED ==========
#
# NODE_DOMAIN     — Detected automatically or set manually. All nodes are <shortname>.NODE_DOMAIN.
# NODE_NAMES      — Auto-discovered via OMF (or ARP fallback), or hardcoded if discovery fails.
#                   Space-separated short names (e.g. node1-1 node2-2). Labels: node1, node2, …
#
# DEFAULT_INTERFACE — Interface to reset on each node during Setup (e.g. wlan0).
#
# PLAN_FILE       — File that stores which nodes are turned *on* for Init / Setup / Check.
#                   Use the menu "Configure node plan" to turn nodes on/off; you don't edit this file.
#
# PACKAGES        — Packages to install on each node during Setup (space-separated).
#
# SETUP_EXTRA_COMMANDS — Optional. Uncomment and add commands to run on each node after packages.
#
# LOG_DIR         — Directory for logs.
#
# ======================================

# Repo root (so paths work from scripts/ or root)
COSMOS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLAN_FILE="$COSMOS_ROOT/.cosmos_plan"
NODES_CACHE="$COSMOS_ROOT/.cosmos_nodes"
FAILED_NODES_FILE="$COSMOS_ROOT/.cosmos_failed"
LOG_DIR="$COSMOS_ROOT/logs"

# Source lib.sh for discovery functions (if not already sourced)
if ! declare -f discover_nodes &>/dev/null; then
    source "$COSMOS_ROOT/scripts/lib.sh"
fi

# Default interface for all nodes
DEFAULT_INTERFACE="wlan0"

# Save nodes to cache file
save_nodes_cache() {
    cat > "$NODES_CACHE" <<EOF
SITE="$SITE"
NODE_DOMAIN="$NODE_DOMAIN"
DISCOVERY_METHOD="$DISCOVERY_METHOD"
NODE_NAMES="$NODE_NAMES"
EOF
}

# --- Load from cache or discover ---
# Skip if NODES is already populated (avoids re-discovery on re-source)
if [ -z "${NODES+x}" ] || [ ${#NODES[@]} -eq 0 ]; then
    if [ -f "$NODES_CACHE" ]; then
        # Load from cache
        source "$NODES_CACHE"
        DISCOVERY_METHOD="${DISCOVERY_METHOD:-cached}"
    else
        # Fresh discovery
        DISCOVERY_METHOD=""
        if detect_orbit_domain 2>/dev/null; then
            : # NODE_DOMAIN and SITE are set
        else
            # Fallback domain (change if you're on a different site)
            NODE_DOMAIN="outdoor.orbit-lab.org"
            SITE="outdoor"
        fi

        if discover_nodes 2>/dev/null && [ -n "$NODE_NAMES" ]; then
            : # NODE_NAMES is set by discover_nodes
        else
            # Fallback: hardcoded node list (outdoor)
            DISCOVERY_METHOD="hardcoded"
            NODE_NAMES="\
node1-1   node1-2   node1-3   \
node1-4   node1-5   node1-6   \
node1-7   node1-8   node1-9   \
node1-10  node1-11  node2-2   \
node2-4   node2-5   node2-6   \
node2-7   node2-8   node2-9   \
node2-10  node3-1   node4-1   \
node4-2   node4-3   node4-4   \
node4-5"
        fi
        # Save to cache for next time
        save_nodes_cache
    fi

    # Build NODES from NODE_NAMES (full hostname = <name>.<NODE_DOMAIN>). Labels: node1, node2, …
    # Use -g to make it global (otherwise it's local when sourced from a function)
    declare -gA NODES
    i=1
    for n in $NODE_NAMES; do
        [ -z "$n" ] && continue
        NODES["node$i"]="${n}.${NODE_DOMAIN}|${DEFAULT_INTERFACE:-wlan0}"
        ((i++)) || true
    done
fi

# Packages to install on each enabled node during Setup
PACKAGES="iperf3 tmux"

# Optional: extra commands per node after package install (uncomment to use)
# SETUP_EXTRA_COMMANDS=("timedatectl set-ntp true")
