#!/bin/bash
#
# ========== CONFIG EXPLAINED ==========
#
# NODE_HOSTNAMES  — List of node hostnames (space-separated). These are the nodes Cosmos knows about.
#                   Labels in the menu become node1, node2, … in order. Add or remove hostnames here.
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

PLAN_FILE=".cosmos_plan"

# All nodes (hostnames). Which ones are used is chosen in the menu: Configure node plan.
# ORBIT outdoor fixed nodes (12): https://www.orbit-lab.org/wiki/Hardware/bDomains/bOutdoor
NODE_HOSTNAMES="\
node1-1.outdoor.orbit-lab.org node1-2.outdoor.orbit-lab.org node1-3.outdoor.orbit-lab.org node1-4.outdoor.orbit-lab.org \
node1-5.outdoor.orbit-lab.org node1-6.outdoor.orbit-lab.org node1-7.outdoor.orbit-lab.org node1-8.outdoor.orbit-lab.org \
node1-9.outdoor.orbit-lab.org node1-10.outdoor.orbit-lab.org node4-2.outdoor.orbit-lab.org node4-3.outdoor.orbit-lab.org"
DEFAULT_INTERFACE="wlan0"

# Build NODES from NODE_HOSTNAMES (labels: node1, node2, …). Must use declare -A so keys stay node1, node2, …
declare -A NODES
i=1
for h in $NODE_HOSTNAMES; do
    [ -z "$h" ] && continue
    NODES["node$i"]="$h|${DEFAULT_INTERFACE:-wlan0}"
    ((i++)) || true
done

# Packages to install on each enabled node during Setup
PACKAGES="iperf3 tmux"

# Optional: extra commands per node after package install (uncomment to use)
# SETUP_EXTRA_COMMANDS=("timedatectl set-ntp true")

LOG_DIR="logs"
