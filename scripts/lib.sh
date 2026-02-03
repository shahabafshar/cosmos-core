#!/bin/bash

# Shared library for Cosmos Core
# Sourced by init.sh, setup.sh, cosmos.sh

# SSH options for reliable connections
SSH_OPTS="-o ConnectTimeout=30 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

# Function to run SSH commands with proper options
# Usage: run_ssh_command <hostname> <command> [timeout_seconds]
run_ssh_command() {
    local hostname=$1
    local command=$2
    local timeout_secs=${3:-0}
    if [ "$timeout_secs" -gt 0 ] 2>/dev/null; then
        timeout "$timeout_secs" ssh $SSH_OPTS root@"$hostname" "$command"
    else
        ssh $SSH_OPTS root@"$hostname" "$command"
    fi
}

# Function to copy files via SCP with proper options
run_scp_command() {
    local source=$1
    local hostname=$2
    local destination=$3
    scp $SSH_OPTS "$source" "root@$hostname:$destination"
}

# Function to check if a node is reachable via ping
check_node() {
    local hostname=$1
    echo "Checking if $hostname is reachable..."
    if ! ping -c 1 "$hostname" > /dev/null 2>&1; then
        echo "Error: Cannot reach $hostname"
        return 1
    fi
    return 0
}

# Function to start a background process on a remote host via SSH
# Returns the remote PID
start_background_process() {
    local hostname=$1
    local command=$2
    local output_file=${3:-/dev/null}
    run_ssh_command "$hostname" "nohup $command > $output_file 2>&1 & echo \$!"
}

# Function to stop a background process on a remote host
stop_background_process() {
    local hostname=$1
    local pid=$2
    run_ssh_command "$hostname" "kill $pid 2>/dev/null || true"
}

# Output enabled node keys (one per line). Requires NODES and optionally PLAN_FILE from config.
# If PLAN_FILE exists and is non-empty, only those keys are output; else all keys, sorted.
get_enabled_node_keys() {
    local k
    local all_keys
    all_keys=$(printf '%s\n' "${!NODES[@]}" | sort -V)
    if [ -n "${PLAN_FILE:-}" ] && [ -f "$PLAN_FILE" ]; then
        if [ -s "$PLAN_FILE" ]; then
            while IFS= read -r k; do
                k="${k%%[[:space:]]*}"
                [ -z "$k" ] && continue
                [ -n "${NODES[$k]+x}" ] && echo "$k"
            done < "$PLAN_FILE"
        fi
    else
        echo "$all_keys"
    fi
}
