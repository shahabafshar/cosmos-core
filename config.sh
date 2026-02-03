#!/bin/bash

# Node configurations
declare -A NODES=(
    # Format: [node_name]="hostname|ip|role|interface|network"
    ["ap"]="node1-3.outdoor.orbit-lab.org|10.1.0.17|ap|wlan0|main_network"
    ["client"]="node1-1.outdoor.orbit-lab.org|10.1.0.15|client|wlan0|main_network"
    ["saturator"]="node1-2.outdoor.orbit-lab.org|10.1.0.16|saturator|wlan0|main_network"
    ["jammer"]="node1-4.outdoor.orbit-lab.org|10.1.0.18|jammer|wlan0|"
    ["control"]="node1-9.outdoor.orbit-lab.org|10.1.0.19|control|wlan0|main_network"
)

# Network configurations (optional; for reference or future use)
declare -A NETWORKS=(
    # Format: [network_name]="ssid|password|channel|hw_mode|auth_algs|wpa|wpa_key_mgmt|wpa_pairwise|rsn_pairwise"
    ["main_network"]="orbit_test_ap|orbit1234|1|g|1|2|WPA-PSK|TKIP|CCMP"
)

# Basic packages installed on all nodes during setup (space-separated)
PACKAGES="iperf3 tmux"

# Optional: extra commands run on each node after package install (array)
# SETUP_EXTRA_COMMANDS=("timedatectl set-ntp true")

LOG_DIR="logs"
