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

# --- Pre-check: parallel ping to catch obviously dead nodes ---
echo -e "\n${CYAN}Pre-check: testing node reachability...${NC}"
tmpdir=$(mktemp -d)
trap "rm -rf '$tmpdir'" EXIT

declare -A precheck_status
pids=()
for i in "${!required_nodes[@]}"; do
    hostname="${required_nodes[i]}"
    (
        # Try ping first (fast), then SSH check
        if ping -c 1 -W 2 "$hostname" >/dev/null 2>&1; then
            echo "ok" > "$tmpdir/$i"
        else
            echo "fail" > "$tmpdir/$i"
        fi
    ) &
    pids+=($!)
done
wait "${pids[@]}" 2>/dev/null || true

# Collect pre-check results
precheck_ok=()
precheck_ok_keys=()
precheck_fail=()
precheck_fail_keys=()
for i in "${!required_nodes[@]}"; do
    hostname="${required_nodes[i]}"
    key="${node_keys[i]}"
    status=$(cat "$tmpdir/$i" 2>/dev/null || echo "fail")
    if [ "$status" = "ok" ]; then
        echo -e "  ${GREEN}✓${NC} $hostname"
        precheck_ok+=("$hostname")
        precheck_ok_keys+=("$key")
    else
        echo -e "  ${RED}✗${NC} $hostname ${YELLOW}(unreachable)${NC}"
        precheck_fail+=("$hostname")
        precheck_fail_keys+=("$key")
    fi
done

# Handle pre-check failures
if [ ${#precheck_fail[@]} -gt 0 ]; then
    echo -e "\n${YELLOW}Warning:${NC} ${#precheck_fail[@]} node(s) unreachable in pre-check."
    
    if [ ${#precheck_ok[@]} -eq 0 ]; then
        echo -e "${RED}No reachable nodes. Aborting.${NC}"
        # Mark all as failed
        for key in "${precheck_fail_keys[@]}"; do
            mark_node_failed "$key"
        done
        exit 1
    fi
    
    echo -e "Continue with ${#precheck_ok[@]} reachable node(s)? [Y/n/a]"
    echo -e "  ${CYAN}Y${NC} = yes, skip unreachable    ${CYAN}n${NC} = abort    ${CYAN}a${NC} = try all anyway"
    read -r choice
    case "$choice" in
        n|N)
            echo "Aborted."
            exit 1
            ;;
        a|A)
            echo "Proceeding with all nodes (including unreachable)..."
            # Don't mark as failed yet, let OMF try
            ;;
        *)
            echo "Proceeding with reachable nodes only..."
            # Mark unreachable as failed
            for key in "${precheck_fail_keys[@]}"; do
                mark_node_failed "$key"
            done
            required_nodes=("${precheck_ok[@]}")
            node_keys=("${precheck_ok_keys[@]}")
            ;;
    esac
fi

if [ ${#required_nodes[@]} -eq 0 ]; then
    echo -e "${RED}No nodes remaining to initialize.${NC}"
    exit 1
fi

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
        printf "\r  ${YELLOW}[Elapsed: %d:%02d]${NC} (~10 min total)   \033[K" "$mins" "$secs"
        sleep 1
    done
) &
timer_pid=$!

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

# Stop the timer
[ -n "$timer_pid" ] && kill $timer_pid 2>/dev/null || true
wait $timer_pid 2>/dev/null || true
printf "\r\033[K"  # Clear timer line

# Show imaging duration
imaging_end=$(date +%s)
imaging_elapsed=$((imaging_end - imaging_start))
imaging_mins=$((imaging_elapsed / 60))
imaging_secs=$((imaging_elapsed % 60))
echo -e "  ${GREEN}Imaging completed in ${imaging_mins}m ${imaging_secs}s${NC}"

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

# --- Final reachability check (parallel) ---
echo -e "\n${CYAN}Verifying nodes are up (timeout: 5 min)...${NC}"
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

total_failed=$((${#precheck_fail[@]} + ${#imaging_failed[@]} + ${#final_fail[@]}))
if [ $total_failed -gt 0 ]; then
    echo -e "\n  ${RED}✗ Failed ($total_failed):${NC}"
    for h in "${precheck_fail[@]}"; do
        echo -e "    • $h ${YELLOW}(pre-check)${NC}"
    done
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
