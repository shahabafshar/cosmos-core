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
    LOG_FILE=$(start_logging "init")
    write_log_header "Initialize"
fi
echo -e "\n════════════════════════════════════════════════" | tee -a >(sed 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE")
echo -e "  ${CYAN}INITIALIZE${NC} — $(date '+%Y-%m-%d %H:%M:%S')" | tee -a >(sed 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE")
echo -e "════════════════════════════════════════════════\n" | tee -a >(sed 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE")

# Tee all output to log file (strip ANSI colors for log)
exec > >(tee >(sed 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE")) 2>&1

# Get list of required nodes (only those enabled in the plan, excluding already-failed)
required_nodes=()
node_keys=()
while IFS= read -r node_name; do
    [ -z "$node_name" ] && continue
    if is_node_failed "$node_name"; then
        IFS='|' read -r hostname _ <<< "${NODES[$node_name]}"
        echo -e "${YELLOW}Skipping${NC} $hostname (previously failed)"
        continue
    fi
    IFS='|' read -r hostname _ <<< "${NODES[$node_name]}"
    required_nodes+=("$hostname")
    node_keys+=("$node_name")
done < <(get_enabled_node_keys)

if [ ${#required_nodes[@]} -eq 0 ]; then
    echo -e "${RED}No nodes to initialize.${NC}"
    echo "Use 'Select nodes' in the menu to choose nodes, or refresh to clear failed status."
    exit 1
fi

echo -e "\n${CYAN}Selected nodes (${#required_nodes[@]}):${NC}"
for h in "${required_nodes[@]}"; do
    echo "  • $h"
done

# Record start time
init_start_time=$(date +%s)

# Create temp directory for output files
tmpdir=$(mktemp -d)
trap "rm -rf '$tmpdir'" EXIT

# --- Main initialization ---
echo -e "\n${CYAN}Turning off all nodes...${NC}"
omf tell -a offh -t all 2>&1 | grep -v "^/.*warning:" || true
sleep 5

echo -e "\n${CYAN}Resetting attenuation matrix...${NC}"
response=$(wget -q -O- "http://internal2dmz.orbit-lab.org:5054/instr/setAll?att=0" 2>/dev/null || echo "failed")
if echo "$response" | grep -q "status='OK'"; then
    echo -e "  ${GREEN}✓${NC} Attenuation matrix reset"
else
    echo -e "  ${YELLOW}⚠${NC} Attenuation matrix reset (response unclear)"
fi
sleep 3

# Create comma-separated list of nodes
node_list=$(IFS=,; echo "${required_nodes[*]}")

# --- Load image (capture output to parse for failures) ---
echo -e "\n${CYAN}Loading image on ${#required_nodes[@]} nodes...${NC}"
echo -e "  This typically takes 8-12 minutes. Watching for failures..."
echo ""

# Start elapsed timer in background
imaging_start=$(date +%s)
timer_pid=""
(
    while true; do
        now=$(date +%s)
        elapsed=$((now - imaging_start))
        mins=$((elapsed / 60))
        secs=$((elapsed % 60))
        # Move cursor to beginning of line, print timer, clear rest of line
        printf "\r  ${YELLOW}[Elapsed: %d:%02d]${NC} - approx 10 min total   \033[K" "$mins" "$secs"
        sleep 1
    done
) &
timer_pid=$!

# Ensure timer is killed on script exit (success or failure)
cleanup_timer() {
    [ -n "$timer_pid" ] && kill $timer_pid 2>/dev/null || true
    wait $timer_pid 2>/dev/null || true
    printf "\r\033[K"
}
trap cleanup_timer EXIT

# Run omf-5.4 load and capture output
omf_output_file="$tmpdir/omf_output.txt"
set +e  # Don't exit on error here
omf-5.4 load -i wifi-experiment.ndz -t "$node_list" 2>&1 | tee "$omf_output_file" | while IFS= read -r line; do
    # Filter out Ruby warnings
    echo "$line" | grep -q "^/.*warning:" && continue
    # Clear timer line before printing output
    printf "\r\033[K"
    # Highlight important messages
    if echo "$line" | grep -q "Giving up on node"; then
        failed_host=$(echo "$line" | grep -oP "node[0-9]+-[0-9]+\.[a-z0-9.-]+")
        echo -e "  ${RED}✗${NC} $line"
    elif echo "$line" | grep -q "successfully imaged"; then
        echo -e "  ${GREEN}✓${NC} $line"
    elif echo "$line" | grep -q "failed to check in"; then
        echo -e "  ${RED}✗${NC} $line"
    elif echo "$line" | grep -qi "error\|fail"; then
        echo -e "  ${YELLOW}⚠${NC} $line"
    else
        echo "  $line"
    fi
done
omf_exit=$?
set -e

# Stop the timer (also handled by trap, but do it here explicitly)
cleanup_timer
timer_pid=""  # Prevent double-kill in trap

# Show imaging duration
imaging_end=$(date +%s)
imaging_elapsed=$((imaging_end - imaging_start))
imaging_mins=$((imaging_elapsed / 60))
imaging_secs=$((imaging_elapsed % 60))
echo -e "  ${GREEN}Imaging phase completed in ${imaging_mins}m ${imaging_secs}s${NC}"

# Check for mixed disk error and handle it
if grep -q "mixed disk names were found" "$omf_output_file" 2>/dev/null; then
    echo -e "\n${YELLOW}Mixed disk types detected!${NC}"
    echo -e "  ORBIT cannot image nodes with different disk types in one batch."
    echo -e "  Attempting to detect disk types and retry in groups...\n"
    
    # Power on nodes temporarily to check disk types
    echo -e "${CYAN}Powering on nodes to detect disk types...${NC}"
    omf tell -a on -t "$node_list" 2>&1 | grep -v "^/.*warning:" || true
    sleep 30  # Wait for nodes to boot
    
    # Detect disk type for each node via SSH - dynamic grouping
    declare -A node_disk_type      # node_disk_type[hostname]="/dev/sda"
    declare -A node_key_map        # node_key_map[hostname]="node1-4"
    declare -a all_disk_types=()   # unique list of disk types found
    declare -A disk_type_nodes     # disk_type_nodes["/dev/sda"]="host1,host2"
    declare -A disk_type_keys      # disk_type_keys["/dev/sda"]="key1,key2"
    unknown_nodes=()
    unknown_keys=()
    
    for i in "${!required_nodes[@]}"; do
        hostname="${required_nodes[i]}"
        key="${node_keys[i]}"
        node_key_map["$hostname"]="$key"
        printf "  Checking %s... " "$hostname"
        
        # Try to detect primary disk device via SSH
        # Check common disk devices in order of preference
        disk_dev=$(ssh $SSH_OPTS root@"$hostname" '
            for dev in /dev/sda /dev/nvme0n1 /dev/vda /dev/hda /dev/xvda /dev/sdb /dev/nvme1n1; do
                if [ -b "$dev" ]; then
                    echo "$dev"
                    exit 0
                fi
            done
            echo "unknown"
        ' 2>/dev/null || echo "unreachable")
        
        if [ "$disk_dev" = "unknown" ] || [ "$disk_dev" = "unreachable" ]; then
            echo -e "${RED}$disk_dev${NC}"
            unknown_nodes+=("$hostname")
            unknown_keys+=("$key")
            mark_node_failed "$key"
        else
            echo -e "${GREEN}$disk_dev${NC}"
            node_disk_type["$hostname"]="$disk_dev"
            
            # Add to disk type group
            if [ -z "${disk_type_nodes[$disk_dev]:-}" ]; then
                all_disk_types+=("$disk_dev")
                disk_type_nodes["$disk_dev"]="$hostname"
                disk_type_keys["$disk_dev"]="$key"
            else
                disk_type_nodes["$disk_dev"]="${disk_type_nodes[$disk_dev]},$hostname"
                disk_type_keys["$disk_dev"]="${disk_type_keys[$disk_dev]},$key"
            fi
        fi
    done
    
    # Summary
    echo ""
    echo -e "  ${CYAN}Disk types found:${NC}"
    for dtype in "${all_disk_types[@]}"; do
        # Count nodes in this group
        IFS=',' read -ra nodes_arr <<< "${disk_type_nodes[$dtype]}"
        echo -e "    $dtype: ${#nodes_arr[@]} node(s)"
    done
    if [ ${#unknown_nodes[@]} -gt 0 ]; then
        echo -e "    ${RED}unknown/unreachable: ${#unknown_nodes[@]} node(s)${NC}"
    fi
    
    # Now image each disk type group separately
    imaging_successful=()
    imaging_successful_keys=()
    
    for dtype in "${all_disk_types[@]}"; do
        IFS=',' read -ra group_nodes <<< "${disk_type_nodes[$dtype]}"
        IFS=',' read -ra group_keys <<< "${disk_type_keys[$dtype]}"
        
        echo -e "\n${CYAN}Imaging ${#group_nodes[@]} node(s) with $dtype...${NC}"
        group_list=$(IFS=,; echo "${group_nodes[*]}")
        
        # Power off and image this group
        omf tell -a offh -t "$group_list" 2>&1 | grep -v "^/.*warning:" || true
        sleep 5
        
        group_omf_output="$tmpdir/omf_group_${dtype//\//_}.txt"
        if omf-5.4 load -i wifi-experiment.ndz -t "$group_list" 2>&1 | grep -v "^/.*warning:" | tee "$group_omf_output"; then
            # Check for failures in this group
            for j in "${!group_nodes[@]}"; do
                gh="${group_nodes[j]}"
                gk="${group_keys[j]}"
                if grep -q "Giving up on node.*$gh" "$group_omf_output" 2>/dev/null; then
                    echo -e "  ${RED}✗${NC} $gh failed during imaging"
                    mark_node_failed "$gk"
                else
                    imaging_successful+=("$gh")
                    imaging_successful_keys+=("$gk")
                fi
            done
        else
            echo -e "  ${YELLOW}Imaging command returned error for $dtype group${NC}"
            # Try to salvage any that might have worked
            for j in "${!group_nodes[@]}"; do
                gh="${group_nodes[j]}"
                gk="${group_keys[j]}"
                if ! grep -q "Giving up on node.*$gh\|failed.*$gh" "$group_omf_output" 2>/dev/null; then
                    imaging_successful+=("$gh")
                    imaging_successful_keys+=("$gk")
                else
                    mark_node_failed "$gk"
                fi
            done
        fi
    done
    
    # Update required_nodes to only successfully imaged ones
    required_nodes=("${imaging_successful[@]}")
    node_keys=("${imaging_successful_keys[@]}")
    
    if [ ${#required_nodes[@]} -eq 0 ]; then
        echo -e "\n${RED}No nodes successfully imaged after disk type grouping.${NC}"
        exit 1
    fi
    
    echo -e "\n${GREEN}Successfully imaged ${#required_nodes[@]} node(s) across disk type groups${NC}"
fi

# Parse OMF output for failures
echo -e "\n${CYAN}Analyzing imaging results...${NC}"
imaging_failed=()
imaging_failed_keys=()

# Look for "Giving up on node X" messages
while IFS= read -r line; do
    if echo "$line" | grep -q "Giving up on node"; then
        failed_host=$(echo "$line" | grep -oP "node[0-9]+-[0-9]+\.[a-z0-9.-]+" || true)
        if [ -n "$failed_host" ]; then
            imaging_failed+=("$failed_host")
            # Find the key for this hostname
            for i in "${!required_nodes[@]}"; do
                if [ "${required_nodes[i]}" = "$failed_host" ]; then
                    imaging_failed_keys+=("${node_keys[i]}")
                    break
                fi
            done
        fi
    fi
done < "$omf_output_file"

# Mark imaging failures
for key in "${imaging_failed_keys[@]}"; do
    mark_node_failed "$key"
done

sleep 5

# --- Turn on nodes ---
# Only turn on nodes that weren't marked as failed during imaging
successful_nodes=()
successful_keys=()
for i in "${!required_nodes[@]}"; do
    hostname="${required_nodes[i]}"
    key="${node_keys[i]}"
    if ! is_node_failed "$key"; then
        successful_nodes+=("$hostname")
        successful_keys+=("$key")
    fi
done

if [ ${#successful_nodes[@]} -eq 0 ]; then
    echo -e "${RED}All nodes failed during imaging. Nothing to power on.${NC}"
    exit 1
fi

node_list=$(IFS=,; echo "${successful_nodes[*]}")
echo -e "\n${CYAN}Turning on ${#successful_nodes[@]} successfully imaged nodes...${NC}"
omf tell -a on -t "$node_list" 2>&1 | grep -v "^/.*warning:" || true
sleep 10

# --- Final reachability check - parallel ---
echo -e "\n${CYAN}Verifying nodes are up [timeout: 5 min]...${NC}"
timeout=300  # 5 minutes
start_time=$(date +%s)
final_ok=()
final_fail=()

while true; do
    # Show elapsed time
    current_time=$(date +%s)
    elapsed=$((current_time - start_time))
    mins=$((elapsed / 60))
    secs=$((elapsed % 60))
    
    pids=()
    for i in "${!successful_nodes[@]}"; do
        hostname="${successful_nodes[i]}"
        (
            if ping -c 1 -W 2 "$hostname" >/dev/null 2>&1; then
                echo "ok" > "$tmpdir/final_$i"
            else
                echo "fail" > "$tmpdir/final_$i"
            fi
        ) &
        pids+=($!)
    done
    wait "${pids[@]}" 2>/dev/null || true
    
    # Count how many are up
    up_count=0
    all_up=true
    for i in "${!successful_nodes[@]}"; do
        status=$(cat "$tmpdir/final_$i" 2>/dev/null || echo "fail")
        if [ "$status" = "ok" ]; then
            ((up_count++)) || true
        else
            all_up=false
        fi
    done
    
    # Show progress on same line
    printf "\r  [Elapsed: %d:%02d] %d/%d nodes responding\033[K" "$mins" "$secs" "$up_count" "${#successful_nodes[@]}"
    
    if $all_up; then
        printf "\n"
        echo -e "  ${GREEN}All nodes responding${NC}"
        break
    fi
    
    if [ $elapsed -ge $timeout ]; then
        printf "\n"
        echo -e "  ${YELLOW}Timeout — some nodes did not respond${NC}"
        break
    fi
    
    sleep 10
done

# Final status check
for i in "${!successful_nodes[@]}"; do
    hostname="${successful_nodes[i]}"
    key="${successful_keys[i]}"
    status=$(cat "$tmpdir/final_$i" 2>/dev/null || echo "fail")
    if [ "$status" = "ok" ]; then
        final_ok+=("$hostname")
    else
        final_fail+=("$hostname")
        mark_node_failed "$key"
    fi
done

# --- Summary ---
init_end_time=$(date +%s)
total_elapsed=$((init_end_time - init_start_time))
minutes=$((total_elapsed / 60))
seconds=$((total_elapsed % 60))

echo ""
echo -e "${CYAN}════════════════════════════════════════════════${NC}"
echo -e "${CYAN}             INITIALIZATION SUMMARY${NC}"
echo -e "${CYAN}════════════════════════════════════════════════${NC}"
echo -e "  Time: ${minutes}m ${seconds}s"
echo ""

if [ ${#final_ok[@]} -gt 0 ]; then
    echo -e "  ${GREEN}✓ Success (${#final_ok[@]}):${NC}"
    for h in "${final_ok[@]}"; do
        echo -e "    • $h"
    done
fi

total_failed=$((${#imaging_failed[@]} + ${#final_fail[@]}))
if [ $total_failed -gt 0 ]; then
    echo -e "\n  ${RED}✗ Failed ($total_failed):${NC}"
    for h in "${imaging_failed[@]}"; do
        echo -e "    • $h ${YELLOW}(imaging)${NC}"
    done
    for h in "${final_fail[@]}"; do
        echo -e "    • $h ${YELLOW}(post-boot)${NC}"
    done
    echo -e "\n  ${YELLOW}Failed nodes have been marked and will be skipped.${NC}"
    echo -e "  ${YELLOW}Use 'r' in Select nodes to clear and retry.${NC}"
fi

echo -e "${CYAN}════════════════════════════════════════════════${NC}"

# Update plan to remove failed nodes
remove_failed_from_plan

if [ ${#final_ok[@]} -eq 0 ]; then
    echo -e "\n${RED}No nodes initialized successfully.${NC}"
    exit 1
fi

echo -e "\n${GREEN}Ready for Setup (${#final_ok[@]} nodes).${NC}"
