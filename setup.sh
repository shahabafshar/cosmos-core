#!/bin/bash

# Exit on error
set -e

# Source configuration
source config.sh
source lib.sh

# Function to install basic packages on a node
install_packages() {
    local hostname=$1
    echo "Installing packages on $hostname..."
    check_node "$hostname" || return 1
    for i in {1..3}; do
        if run_ssh_command "$hostname" "DEBIAN_FRONTEND=noninteractive apt-get update -y && apt-get install -y $PACKAGES"; then
            return 0
        fi
        echo "Attempt $i failed, retrying in 5 seconds..."
        sleep 5
    done
    echo "Error: Failed to install packages on $hostname after 3 attempts"
    return 1
}

# Function to cleanup node (kill stale processes, reset interface)
cleanup_node() {
    local hostname=$1
    local interface=$2
    echo "Cleaning up $hostname..."
    run_ssh_command "$hostname" "pkill -f hostapd || true; \
                   pkill -f wpa_supplicant || true; \
                   pkill -f mdk3 || true; \
                   pkill -f aireplay-ng || true; \
                   ip link set $interface down || true; \
                   ip addr flush dev $interface || true" || echo "Warning: Cleanup had errors on $hostname"
}

# Function to run optional extra setup commands on a node
run_extra_commands() {
    local hostname=$1
    if [ -n "${SETUP_EXTRA_COMMANDS+x}" ] && [ ${#SETUP_EXTRA_COMMANDS[@]} -gt 0 ]; then
        for cmd in "${SETUP_EXTRA_COMMANDS[@]}"; do
            echo "Running on $hostname: $cmd"
            run_ssh_command "$hostname" "$cmd" || echo "Warning: Command failed: $cmd"
        done
    fi
}

# Ensure every enabled node has a clean state and basic packages.
enabled_count=0
main() {
    local keys
    keys=($(get_enabled_node_keys))
    if [ ${#keys[@]} -eq 0 ]; then
        echo "No nodes enabled in the plan. Use 'Configure node plan' in the menu to enable nodes."
        exit 1
    fi
    while IFS= read -r node_name; do
        [ -z "$node_name" ] && continue
        IFS='|' read -r hostname interface <<< "${NODES[$node_name]}"
        echo "Processing node: $node_name ($hostname)"
        cleanup_node "$hostname" "$interface"
        install_packages "$hostname" || { echo "Error: Package installation failed on $hostname"; exit 1; }
        run_extra_commands "$hostname"
        ((enabled_count++)) || true
    done < <(get_enabled_node_keys)
    echo "Setup completed successfully!"
}

setup_start_time=$(date +%s)
main
setup_end_time=$(date +%s)
total_elapsed=$((setup_end_time - setup_start_time))
minutes=$((total_elapsed / 60))
seconds=$((total_elapsed % 60))

echo "====================setup======================="
echo "Setup completed successfully"
echo "Total setup time: ${minutes}m ${seconds}s"
echo "Nodes configured: $enabled_count"
echo "================================================"
