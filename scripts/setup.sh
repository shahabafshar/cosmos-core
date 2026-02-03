#!/bin/bash

# Exit on error (but we handle some errors ourselves)
set -e

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPTS_DIR/config.sh"
source "$SCRIPTS_DIR/lib.sh"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Use session log if available, otherwise create own
if [ -z "${LOG_FILE:-}" ]; then
    LOG_FILE=$(start_logging "setup")
    write_log_header "Setup"
fi
echo -e "\n════════════════════════════════════════════════" | tee -a >(sed 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE")
echo -e "  ${CYAN}SETUP${NC} — $(date '+%Y-%m-%d %H:%M:%S')" | tee -a >(sed 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE")
echo -e "════════════════════════════════════════════════\n" | tee -a >(sed 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE")

# Tee all output to log file (strip ANSI colors for log)
exec > >(tee >(sed 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE")) 2>&1

# Timeout for setup operations (seconds)
SETUP_TIMEOUT=300  # 5 minutes total

# Setup a single node (cleanup + packages + extras)
setup_single_node() {
    local hostname=$1
    local interface=$2
    local result_file=$3
    local status_file=$4
    
    echo "cleanup" > "$status_file"
    timeout 30 ssh $SSH_OPTS "root@$hostname" "pkill -f hostapd || true; \
        pkill -f wpa_supplicant || true; \
        pkill -f mdk3 || true; \
        pkill -f aireplay-ng || true; \
        ip link set $interface down 2>/dev/null || true; \
        ip addr flush dev $interface 2>/dev/null || true" 2>/dev/null || true
    
    echo "packages" > "$status_file"
    local success=false
    for i in {1..2}; do
        if timeout 180 ssh $SSH_OPTS "root@$hostname" "DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq $PACKAGES >/dev/null 2>&1" 2>/dev/null; then
            success=true
            break
        fi
        [ $i -lt 2 ] && sleep 3
    done
    
    if ! $success; then
        echo "fail" > "$result_file"
        echo "pkg_fail" > "$status_file"
        return 1
    fi
    
    if [ -n "${SETUP_EXTRA_COMMANDS+x}" ] && [ ${#SETUP_EXTRA_COMMANDS[@]} -gt 0 ]; then
        echo "extras" > "$status_file"
        for cmd in "${SETUP_EXTRA_COMMANDS[@]}"; do
            timeout 60 ssh $SSH_OPTS "root@$hostname" "$cmd" 2>/dev/null || true
        done
    fi
    
    echo "ok" > "$result_file"
    echo "done" > "$status_file"
    return 0
}

# Get nodes to setup (skip already-failed)
nodes_to_setup=()
node_keys=()
skipped_failed=0

while IFS= read -r node_name; do
    [ -z "$node_name" ] && continue
    if is_node_failed "$node_name"; then
        ((skipped_failed++)) || true
        continue
    fi
    IFS='|' read -r hostname interface <<< "${NODES[$node_name]}"
    nodes_to_setup+=("$hostname|$interface")
    node_keys+=("$node_name")
done < <(get_enabled_node_keys)

if [ ${#nodes_to_setup[@]} -eq 0 ]; then
    echo -e "${RED}No nodes to setup.${NC}"
    echo "Use 'Select nodes' to choose nodes, or refresh to clear failed status."
    exit 1
fi

num_nodes=${#nodes_to_setup[@]}
echo -e "${CYAN}Setting up ${num_nodes} nodes (timeout ${SETUP_TIMEOUT}s)${NC}"
[ $skipped_failed -gt 0 ] && echo -e "${YELLOW}(Skipping $skipped_failed previously failed)${NC}"

# Create temp directory
tmpdir=$(mktemp -d)
trap "rm -rf '$tmpdir'" EXIT

# Initialize status files
for i in "${!nodes_to_setup[@]}"; do
    echo "checking" > "$tmpdir/status_$i"
done

# Grid display settings
col_width=24
num_rows=$(( (num_nodes + 2) / 3 ))

# Function to draw the 3-column grid
draw_grid() {
    local elapsed=$1
    # Timer line
    printf "  \033[1;33m[%3ds]\033[0m\033[K\n" "$elapsed"
    # Grid
    for ((r=0; r<num_rows; r++)); do
        printf "  "
        for ((c=0; c<3; c++)); do
            idx=$((r * 3 + c))
            if [ $idx -lt $num_nodes ]; then
                IFS='|' read -r hostname _ <<< "${nodes_to_setup[idx]}"
                short_name="${hostname%%.*}"
                status=$(cat "$tmpdir/status_$idx" 2>/dev/null || echo "...")
                
                # Fixed-width: node name (10 chars) + ": " + status (10 chars) = 22 chars + padding
                # Truncate or pad node name to exactly 8 chars
                printf -v name_fixed "%-8.8s" "$short_name"
                
                # Status with color (all status texts padded to same visible length)
                # Use ASCII-only status (11 chars fixed) to avoid Unicode width issues
                case "$status" in
                    "checking")    printf "%s: \033[0;36m%-11s\033[0m" "$name_fixed" "checking" ;;
                    "ready")       printf "%s: \033[0;32m%-11s\033[0m" "$name_fixed" "ready" ;;
                    "unreachable") printf "%s: \033[0;31m%-11s\033[0m" "$name_fixed" "unreachable" ;;
                    "ssh_fail")    printf "%s: \033[0;31m%-11s\033[0m" "$name_fixed" "ssh fail" ;;
                    "cleanup")     printf "%s: \033[0;36m%-11s\033[0m" "$name_fixed" "cleanup" ;;
                    "packages")    printf "%s: \033[1;33m%-11s\033[0m" "$name_fixed" "packages" ;;
                    "extras")     printf "%s: \033[1;33m%-11s\033[0m" "$name_fixed" "extras" ;;
                    *done)         printf "%s: \033[0;32m%-11s\033[0m" "$name_fixed" "[done]" ;;
                    *fail)         printf "%s: \033[0;31m%-11s\033[0m" "$name_fixed" "[failed]" ;;
                    *timeout)      printf "%s: \033[0;31m%-11s\033[0m" "$name_fixed" "[timeout]" ;;
                    *)             printf "%s: \033[0;36m%-11s\033[0m" "$name_fixed" "$status" ;;
                esac
                printf "  "  # Column separator
            fi
        done
        printf "\033[K\n"  # Clear to end of line
    done
}

# Print initial grid
echo ""
draw_grid 0
start_time=$(date +%s)

# Phase 1: Reachability + SSH check (parallel)
pids=()
for i in "${!nodes_to_setup[@]}"; do
    IFS='|' read -r hostname _ <<< "${nodes_to_setup[i]}"
    (
        if ! ping -c 1 -W 2 "$hostname" >/dev/null 2>&1; then
            echo "unreachable" > "$tmpdir/status_$i"
            echo "unreachable" > "$tmpdir/result_$i"
        elif ! ssh $SSH_OPTS "root@$hostname" "echo ok" >/dev/null 2>&1; then
            echo "ssh_fail" > "$tmpdir/status_$i"
            echo "ssh_fail" > "$tmpdir/result_$i"
        else
            echo "ready" > "$tmpdir/status_$i"
            echo "ready" > "$tmpdir/result_$i"
        fi
    ) &
    pids+=($!)
done

# Wait for reachability checks with progress
while true; do
    all_done=true
    for pid in "${pids[@]}"; do
        kill -0 "$pid" 2>/dev/null && all_done=false && break
    done
    $all_done && break
    
    elapsed=$(($(date +%s) - start_time))
    echo -ne "\033[$((num_rows + 1))A"
    draw_grid $elapsed
    sleep 1
done
wait "${pids[@]}" 2>/dev/null || true

# Collect reachable nodes
reachable_indices=()
ssh_fail_count=0
unreachable_count=0

for i in "${!nodes_to_setup[@]}"; do
    result=$(cat "$tmpdir/result_$i" 2>/dev/null || echo "unreachable")
    if [ "$result" = "ready" ]; then
        reachable_indices+=("$i")
    elif [ "$result" = "ssh_fail" ]; then
        ((ssh_fail_count++)) || true
        mark_node_failed "${node_keys[i]}"
    else
        ((unreachable_count++)) || true
        mark_node_failed "${node_keys[i]}"
    fi
done

# Update display
elapsed=$(($(date +%s) - start_time))
echo -ne "\033[$((num_rows + 1))A"
draw_grid $elapsed

if [ ${#reachable_indices[@]} -eq 0 ]; then
    echo -e "\n${RED}No reachable nodes. Aborting.${NC}"
    [ $ssh_fail_count -gt 0 ] && echo -e "${YELLOW}SSH failures: Check keys or re-image with Init.${NC}"
    exit 1
fi

# Phase 2: Setup reachable nodes (parallel)
pids=()
for i in "${reachable_indices[@]}"; do
    IFS='|' read -r hostname interface <<< "${nodes_to_setup[i]}"
    setup_single_node "$hostname" "$interface" "$tmpdir/setup_result_$i" "$tmpdir/status_$i" &
    pids+=($!)
done

# Progress monitoring
while true; do
    all_done=true
    for pid in "${pids[@]}"; do
        kill -0 "$pid" 2>/dev/null && all_done=false && break
    done
    $all_done && break
    
    elapsed=$(($(date +%s) - start_time))
    if [ $elapsed -ge $SETUP_TIMEOUT ]; then
        for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done
        for i in "${reachable_indices[@]}"; do
            status=$(cat "$tmpdir/status_$i" 2>/dev/null || echo "")
            [[ "$status" != "done" && "$status" != *"fail"* && "$status" != *"timeout"* ]] && echo "timeout" > "$tmpdir/status_$i"
        done
        break
    fi
    
    echo -ne "\033[$((num_rows + 1))A"
    draw_grid $elapsed
    sleep 2
done
wait "${pids[@]}" 2>/dev/null || true

# Final display
elapsed=$(($(date +%s) - start_time))
echo -ne "\033[$((num_rows + 1))A"
draw_grid $elapsed
echo ""

# Collect results
success_nodes=()
fail_nodes=()

for i in "${!nodes_to_setup[@]}"; do
    IFS='|' read -r hostname _ <<< "${nodes_to_setup[i]}"
    status=$(cat "$tmpdir/status_$i" 2>/dev/null || echo "fail")
    if [[ "$status" == "done" ]]; then
        success_nodes+=("$hostname")
    else
        fail_nodes+=("$hostname")
        mark_node_failed "${node_keys[i]}"
    fi
done

# Summary
minutes=$((elapsed / 60))
seconds=$((elapsed % 60))

echo -e "${CYAN}════════════════════════════════════════════════${NC}"
echo -e "  ${GREEN}✓ Success: ${#success_nodes[@]}${NC}    ${RED}✗ Failed: ${#fail_nodes[@]}${NC}    Time: ${minutes}m ${seconds}s"
echo -e "${CYAN}════════════════════════════════════════════════${NC}"

# Update plan
remove_failed_from_plan

if [ ${#success_nodes[@]} -eq 0 ]; then
    echo -e "\n${RED}No nodes setup successfully.${NC}"
    exit 1
fi

echo -e "\n${GREEN}Setup complete.${NC}"
