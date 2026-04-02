#!/bin/bash

# Shared library for Cosmos Core
# Sourced by init.sh, setup.sh, cosmos.sh

# SSH options for reliable connections (BatchMode=yes prevents password prompts)
SSH_OPTS="-o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o LogLevel=ERROR"

# Colors for warnings (may be overridden by cosmos.sh)
_WARN_COLOR='\033[1;33m'
_NC='\033[0m'

# --- Logging ---

# Start logging to a file. Call at the beginning of a script.
# Usage: start_logging "init" -> sets LOG_FILE and starts tee
# Returns the log file path
start_logging() {
    local operation="${1:-unknown}"
    local user timestamp logfile
    
    # Ensure LOG_DIR is set (from config.sh)
    [ -z "${LOG_DIR:-}" ] && LOG_DIR="${COSMOS_ROOT:-$(pwd)}/logs"
    
    # Create log directory if needed
    mkdir -p "$LOG_DIR" 2>/dev/null || true
    
    # Generate filename: operation_user_YYYY-MM-DD_HH-MM-SS.log
    user=$(whoami 2>/dev/null || echo "unknown")
    timestamp=$(date '+%Y-%m-%d_%H-%M-%S')
    logfile="${LOG_DIR}/${operation}_${user}_${timestamp}.log"
    
    LOG_FILE="$logfile"
    echo "$logfile"
}

# Write header to log file
write_log_header() {
    local operation="$1"
    [ -z "${LOG_FILE:-}" ] && return
    {
        echo "========================================"
        echo "Cosmos Core - ${operation^} Log"
        echo "========================================"
        echo "Date:     $(date '+%Y-%m-%d %H:%M:%S')"
        echo "User:     $(whoami 2>/dev/null || echo 'unknown')"
        echo "Host:     $(hostname -f 2>/dev/null || hostname)"
        echo "Site:     ${SITE:-unknown}"
        echo "========================================"
        echo ""
    } >> "$LOG_FILE"
}

# Log a message (appends to LOG_FILE if set)
log_msg() {
    local msg="$1"
    [ -n "${LOG_FILE:-}" ] && echo "$msg" >> "$LOG_FILE"
}

# Detect ORBIT/COSMOS domain from console hostname (e.g. outdoor, sb1, bed)
# Sets NODE_DOMAIN and SITE variables
# Handles both orbit-lab.org and cosmos-lab.org consoles.
detect_orbit_domain() {
    local fqdn site domain
    fqdn=$(hostname -f 2>/dev/null) || fqdn=$(hostname 2>/dev/null)
    # Extract site: e.g. console.outdoor.orbit-lab.org -> outdoor
    # Reservable ORBIT:  grid, intersection, outdoor, sb1-sb9
    # Reservable COSMOS: bed, sb1, sb2, weeks, license
    site=$(echo "$fqdn" | grep -oE '\.(grid|intersection|outdoor|sb[0-9]+|bed|weeks|license)\.' | tr -d '.')
    if [ -z "$site" ]; then
        # Fallback: try from domain
        site=$(hostname -d 2>/dev/null | cut -d. -f1)
    fi
    if [ -n "$site" ]; then
        SITE="$site"
        # Determine parent domain from FQDN (orbit-lab.org vs cosmos-lab.org)
        if echo "$fqdn" | grep -q 'cosmos-lab\.org'; then
            domain="cosmos-lab.org"
        else
            domain="orbit-lab.org"
        fi
        NODE_DOMAIN="${site}.${domain}"
        return 0
    fi
    return 1
}

# Discover nodes via OMF (primary method)
# Finds all imageable nodes (node*, mob*, sdr*, srv*) while excluding
# RF devices (rfdev*) which have no CPU/disk and can't be imaged.
# Output: space-separated short node names
discover_nodes_omf() {
    local nodes
    if ! command -v omf &>/dev/null; then
        return 1
    fi
    # omf stat outputs lines like "node1-1.sb4.orbit-lab.org  State: POWERON"
    # Extract the short hostname (everything before the first dot), then filter:
    #   Include: node*, mob*, sdr*, srv*
    #   Exclude: rfdev* (RF-only devices, not imageable)
    nodes=$(omf stat -t all 2>/dev/null \
        | grep -oE '(node|mob|sdr|srv)[a-zA-Z0-9_-]+' \
        | grep -v '^rfdev' \
        | sort -V | uniq | tr '\n' ' ')
    if [ -z "$nodes" ]; then
        return 1
    fi
    echo "$nodes"
    return 0
}

# Discover nodes via ARP table (fallback method)
# Output: space-separated short node names
discover_nodes_arp() {
    local nodes domain_pattern
    domain_pattern="${NODE_DOMAIN:-orbit-lab.org}"
    # Parse ARP table for hostnames, matching imageable node types
    nodes=$(arp -a 2>/dev/null \
        | grep -oE "(node|mob|sdr|srv)[a-zA-Z0-9_-]+\.${domain_pattern//./\\.}" \
        | sed 's/\..*//' \
        | grep -v '^rfdev' \
        | sort -V | uniq | tr '\n' ' ')
    if [ -z "$nodes" ]; then
        return 1
    fi
    echo "$nodes"
    return 0
}

# Main discovery function: tries OMF first, then ARP fallback
# Sets NODE_NAMES variable and DISCOVERY_METHOD
# Returns 0 on success, 1 if no nodes found
discover_nodes() {
    local nodes
    DISCOVERY_METHOD=""
    
    # Try OMF first
    nodes=$(discover_nodes_omf)
    if [ -n "$nodes" ]; then
        NODE_NAMES="$nodes"
        DISCOVERY_METHOD="omf"
        return 0
    fi
    
    # Fallback to ARP with warning
    nodes=$(discover_nodes_arp)
    if [ -n "$nodes" ]; then
        NODE_NAMES="$nodes"
        DISCOVERY_METHOD="arp"
        echo -e "${_WARN_COLOR}Warning: OMF query failed, using ARP table (may be incomplete).${_NC}" >&2
        return 0
    fi
    
    return 1
}

# Ensure ~/.ssh/config has sensible defaults for testbed nodes.
# Nodes get new host keys after every imaging, so StrictHostKeyChecking must be off.
# Idempotent: updates existing values if wrong, adds block if missing.
ensure_ssh_config() {
    local ssh_dir="$HOME/.ssh"
    local ssh_conf="$ssh_dir/config"
    mkdir -p "$ssh_dir"
    chmod 700 "$ssh_dir"

    # If no config file, just create the block
    if [ ! -f "$ssh_conf" ]; then
        cat >> "$ssh_conf" <<'EOF'

# Cosmos Core — testbed nodes get new keys after imaging
Host node* mob* sdr* srv*
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    LogLevel ERROR
EOF
        chmod 600 "$ssh_conf"
        return 0
    fi

    # Check if a Host block already covers node*
    if grep -qE '^\s*Host\s+.*node\*' "$ssh_conf"; then
        # Check if anything actually needs fixing before editing
        local needs_fix=0
        if grep -A5 -E '^\s*Host\s+.*node\*' "$ssh_conf" | grep -qiE '^\s*StrictHostKeyChecking\s+(yes|ask)'; then
            needs_fix=1
        fi
        if grep -A5 -E '^\s*Host\s+.*node\*' "$ssh_conf" | grep -qiE '^\s*UserKnownHostsFile\s' \
           && ! grep -A5 -E '^\s*Host\s+.*node\*' "$ssh_conf" | grep -q '/dev/null'; then
            needs_fix=1
        fi

        if [ "$needs_fix" -eq 1 ]; then
            # Backup before editing — find a unique backup name
            local backup="${ssh_conf}.bak"
            if [ -f "$backup" ]; then
                local n=1
                while [ -f "${ssh_conf}.bak.${n}" ]; do
                    ((n++)) || true
                done
                backup="${ssh_conf}.bak.${n}"
            fi
            cp "$ssh_conf" "$backup"

            # Fix individual settings in the node* block
            local in_block=0
            local tmpfile
            tmpfile=$(mktemp)
            while IFS= read -r line; do
                if echo "$line" | grep -qE '^\s*Host\s+.*node\*'; then
                    in_block=1
                    echo "$line" >> "$tmpfile"
                    continue
                fi
                # Detect next Host block — stop editing
                if [ "$in_block" -eq 1 ] && echo "$line" | grep -qE '^\s*Host\s'; then
                    in_block=0
                fi
                if [ "$in_block" -eq 1 ]; then
                    if echo "$line" | grep -qiE '^\s*StrictHostKeyChecking\s+(yes|ask)'; then
                        line=$(echo "$line" | sed -E 's/(StrictHostKeyChecking\s+)(yes|ask)/\1no/i')
                    fi
                    if echo "$line" | grep -qiE '^\s*UserKnownHostsFile\s' && ! echo "$line" | grep -q '/dev/null'; then
                        line=$(echo "$line" | sed -E 's|(UserKnownHostsFile\s+).*|\1/dev/null|')
                    fi
                fi
                echo "$line" >> "$tmpfile"
            done < "$ssh_conf"
            mv "$tmpfile" "$ssh_conf"
            chmod 600 "$ssh_conf"
        fi
    else
        # No matching block — append one
        cat >> "$ssh_conf" <<'EOF'

# Cosmos Core — testbed nodes get new keys after imaging
Host node* mob* sdr* srv*
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    LogLevel ERROR
EOF
        chmod 600 "$ssh_conf"
    fi

    # Clean stale entries from known_hosts for testbed nodes.
    # Existing entries cause "HOST IDENTIFICATION HAS CHANGED" even with
    # StrictHostKeyChecking=no in config, because SSH matches cached keys first.
    local known_hosts="$ssh_dir/known_hosts"
    if [ -f "$known_hosts" ]; then
        # Check if any testbed node entries exist before modifying
        if grep -qE '^(node|mob|sdr|srv)[a-zA-Z0-9_-]' "$known_hosts" 2>/dev/null; then
            # Backup known_hosts (unique name)
            local kh_backup="${known_hosts}.bak"
            if [ -f "$kh_backup" ]; then
                local n=1
                while [ -f "${known_hosts}.bak.${n}" ]; do ((n++)) || true; done
                kh_backup="${known_hosts}.bak.${n}"
            fi
            cp "$known_hosts" "$kh_backup"
            # Remove entries matching testbed node hostnames
            local tmpfile
            tmpfile=$(mktemp)
            grep -vE '^(node|mob|sdr|srv)[a-zA-Z0-9_-]' "$known_hosts" > "$tmpfile" 2>/dev/null || true
            mv "$tmpfile" "$known_hosts"
            chmod 600 "$known_hosts"
        fi
    fi
}

# Function to run SSH commands with proper options
# Usage: run_ssh_command <hostname> <command> [timeout_seconds]
run_ssh_command() {
    local hostname=$1
    local command=$2
    local timeout_secs=${3:-0}
    local ssh_user="${SSH_USER:-root}"
    if [ "$timeout_secs" -gt 0 ] 2>/dev/null; then
        timeout "$timeout_secs" ssh $SSH_OPTS "$ssh_user@$hostname" "$command"
    else
        ssh $SSH_OPTS "$ssh_user@$hostname" "$command"
    fi
}

# Function to copy files via SCP with proper options
run_scp_command() {
    local source=$1
    local hostname=$2
    local destination=$3
    local ssh_user="${SSH_USER:-root}"
    scp $SSH_OPTS "$source" "$ssh_user@$hostname:$destination"
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

# --- Failed nodes management ---

# Check if a node key is in the failed list
is_node_failed() {
    local key="$1"
    [ -z "${FAILED_NODES_FILE:-}" ] && return 1
    [ ! -f "$FAILED_NODES_FILE" ] && return 1
    grep -qx "$key" "$FAILED_NODES_FILE" 2>/dev/null
}

# Mark a node as failed (by key like "node1")
mark_node_failed() {
    local key="$1"
    [ -z "${FAILED_NODES_FILE:-}" ] && return
    if ! is_node_failed "$key"; then
        echo "$key" >> "$FAILED_NODES_FILE"
    fi
}

# Clear a single node's failed status
clear_node_failed() {
    local key="$1"
    [ -z "${FAILED_NODES_FILE:-}" ] && return
    [ ! -f "$FAILED_NODES_FILE" ] && return
    local tmpfile
    tmpfile=$(mktemp)
    grep -vx "$key" "$FAILED_NODES_FILE" > "$tmpfile" 2>/dev/null || true
    mv "$tmpfile" "$FAILED_NODES_FILE"
}

# Mark a node as failed by hostname (e.g., node1-4.outdoor.orbit-lab.org)
mark_node_failed_by_hostname() {
    local hostname="$1"
    local k h
    for k in "${!NODES[@]}"; do
        IFS='|' read -r h _ <<< "${NODES[$k]}"
        if [ "$h" = "$hostname" ]; then
            mark_node_failed "$k"
            return 0
        fi
    done
    return 1
}

# Clear all failed nodes
clear_failed_nodes() {
    [ -n "${FAILED_NODES_FILE:-}" ] && rm -f "$FAILED_NODES_FILE"
}

# Get list of failed node keys
get_failed_node_keys() {
    [ -z "${FAILED_NODES_FILE:-}" ] && return
    [ -f "$FAILED_NODES_FILE" ] && cat "$FAILED_NODES_FILE"
}

# Remove failed nodes from selection (update PLAN_FILE)
remove_failed_from_plan() {
    [ -z "${PLAN_FILE:-}" ] || [ ! -f "$PLAN_FILE" ] && return
    [ -z "${FAILED_NODES_FILE:-}" ] || [ ! -f "$FAILED_NODES_FILE" ] && return
    local tmpfile
    tmpfile=$(mktemp)
    while IFS= read -r k; do
        is_node_failed "$k" || echo "$k"
    done < "$PLAN_FILE" > "$tmpfile"
    mv "$tmpfile" "$PLAN_FILE"
}
