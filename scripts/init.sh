#!/bin/bash

# Exit on error (but we handle some errors ourselves)
set -e

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPTS_DIR/config.sh"
source "$SCRIPTS_DIR/lib.sh"

# Colors (must be $'...' so ESC is a real byte; printf does not treat \033 like echo -e)
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
CYAN=$'\033[0;36m'
NC=$'\033[0m'
CLR=$'\033[K'

# Kill a process and all its descendants (handles the omf pipeline tree)
kill_tree() {
    local pid=$1 sig=${2:-TERM}
    local children
    children=$(ps -o pid= --ppid "$pid" 2>/dev/null) || true
    for child in $children; do
        kill_tree "$child" "$sig"
    done
    kill -"$sig" "$pid" 2>/dev/null || true
}

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
trap 'rm -rf "$tmpdir"' EXIT

# --- Main initialization ---
echo -e "\n${CYAN}Turning off all nodes...${NC}"
omf tell -a offh -t all 2>&1 | grep -v "^/.*warning:" || true
# OMF often uses CR-overwrite lines; force a real newline so the next echo is not drawn on top.
printf '\n'
sleep 5

echo -e "\n${CYAN}Resetting attenuation matrix...${NC}"
INSTR_BASE="http://internal2dmz.orbit-lab.org:5054/instr"
response=$(wget -q -O- "${INSTR_BASE}/setAll?att=0" 2>/dev/null || echo "failed")
if echo "$response" | grep -q "status='OK'"; then
    echo -e "  ${GREEN}*${NC} Attenuation matrix reset (setAll)"
else
    # Avoid U+26A0 warning sign: many consoles render it as a wide emoji and clip the rest of the line.
    echo -e "  ${YELLOW}!${NC} Attenuation matrix reset (setAll — response unclear or unreachable)"
fi

# ISU Lab 4 manual: select matrix devices on switches 3–6, port 1 (same sequence as manual wget steps).
echo -e "  ${CYAN}Selecting matrix paths (selDevice switches 3–6)...${NC}"
sel_ok=0
for sw in 3 4 5 6; do
    sel_r=$(wget -q -O- "${INSTR_BASE}/selDevice?switch=${sw}&port=1" 2>/dev/null || true)
    if echo "$sel_r" | grep -q "status='OK'"; then
        ((sel_ok++)) || true
    fi
done
if [ "$sel_ok" -eq 4 ]; then
    echo -e "  ${GREEN}*${NC} Matrix device selection OK (4/4)"
elif [ "$sel_ok" -gt 0 ]; then
    echo -e "  ${YELLOW}!${NC} Matrix device selection partial (${sel_ok}/4 reported OK)"
else
    echo -e "  ${YELLOW}!${NC} Matrix device selection failed or unreachable (0/4 OK — check console→internal2dmz:5054)"
fi
sleep 3

# Create comma-separated list of nodes
node_list=$(IFS=,; echo "${required_nodes[*]}")

# --- Load image (capture output to parse for failures) ---
# Timeout for imaging process (seconds) - default 12 minutes
IMAGING_TIMEOUT=${IMAGING_TIMEOUT:-720}

echo -e "\n${CYAN}Loading image on ${#required_nodes[@]} nodes...${NC}"
timeout_mins=$((IMAGING_TIMEOUT / 60))
echo -e "  Timeout: ${timeout_mins} min"
echo ""

# Progress tracking: bar denominator comes from OMF when it prints batch size (e.g. "onto 10 nodes").
# Plan size is NOT the same as OMF's current imaging batch — do not default the bar to plan count.
total_nodes=${#required_nodes[@]}
echo "0" > "$tmpdir/nodes_up"
echo "0" > "$tmpdir/nodes_imaged"
echo "0" > "$tmpdir/nodes_failed_bar"
echo "0" > "$tmpdir/last_nodes_up"
echo "$(date +%s)" > "$tmpdir/last_progress_time"
rm -f "$tmpdir/nodes_total_omf"
rm -f "$tmpdir/stall_triggered"

# Serialize TTY writes: background timer + OMF pipeline otherwise interleave and corrupt one line.
tty_lock="$tmpdir/imaging_tty.lock"
touch "$tty_lock"
exec 3>>"$tty_lock"

# Stall detection settings (from config.sh)
BOOT_STALL_TIMEOUT=${BOOT_STALL_TIMEOUT:-120}
BOOT_MIN_PERCENT=${BOOT_MIN_PERCENT:-50}

# Start elapsed timer with progress bar in background
imaging_start=$(date +%s)
timer_pid=""
omf_pid_file="$tmpdir/omf_pid"
(
    t_mins=$((IMAGING_TIMEOUT / 60))
    while true; do
        now=$(date +%s)
        elapsed=$((now - imaging_start))
        mins=$((elapsed / 60))
        secs=$((elapsed % 60))
        
        # Read current progress; tr -dc strips any \r / whitespace OMF leaves behind
        nodes_up=$(cat "$tmpdir/nodes_up" 2>/dev/null | tr -dc '0-9');       nodes_up=${nodes_up:-0}
        nodes_imaged=$(cat "$tmpdir/nodes_imaged" 2>/dev/null | tr -dc '0-9'); nodes_imaged=${nodes_imaged:-0}
        nodes_failed=$(cat "$tmpdir/nodes_failed_bar" 2>/dev/null | tr -dc '0-9'); nodes_failed=${nodes_failed:-0}
        omf_tot=$(cat "$tmpdir/nodes_total_omf" 2>/dev/null | tr -dc '0-9');  omf_tot=${omf_tot:-}
        last_up=$(cat "$tmpdir/last_nodes_up" 2>/dev/null | tr -dc '0-9');   last_up=${last_up:-0}
        last_progress=$(cat "$tmpdir/last_progress_time" 2>/dev/null | tr -dc '0-9'); last_progress=${last_progress:-$now}
        
        # Track progress changes for stall detection
        if [ "$nodes_up" != "$last_up" ]; then
            echo "$nodes_up" > "$tmpdir/last_nodes_up"
            echo "$now" > "$tmpdir/last_progress_time"
            last_progress=$now
        fi
        
        # Stall detection: if no progress for BOOT_STALL_TIMEOUT and enough nodes are up (uses OMF batch size only)
        stall_time=$((now - last_progress))
        if [ -n "$omf_tot" ] && [ "$omf_tot" -ge 1 ] 2>/dev/null && [ "$nodes_up" -gt 0 ]; then
            pct=$((nodes_up * 100 / omf_tot))
            if [ "$stall_time" -ge "$BOOT_STALL_TIMEOUT" ] && [ "$pct" -ge "$BOOT_MIN_PERCENT" ] && [ "$nodes_up" -lt "$omf_tot" ]; then
                # Stall detected! Kill omf process
                if [ ! -f "$tmpdir/stall_triggered" ]; then
                    touch "$tmpdir/stall_triggered"
                    omf_pid=$(cat "$omf_pid_file" 2>/dev/null || echo "")
                    if [ -n "$omf_pid" ]; then
                        flock 3
                        printf "\r${CLR}\n"
                        printf "  ${YELLOW}Stall detected: %d/%d nodes up, no progress for %ds — stopping${NC}\n" \
                            "$nodes_up" "$omf_tot" "$stall_time"
                        flock -u 3
                        # Kill the entire process tree (omf load + grep + tee + while read)
                        kill_tree "$omf_pid" TERM
                        sleep 2
                        kill_tree "$omf_pid" 9
                    fi
                fi
            fi
        fi

        # Bar width is always the *plan* size (total selected nodes).
        # OMF's current batch size (omf_tot) is used for stall logic above, but we want failures (x)
        # and successes (# / :) to be counted against the original selection, not just the active batch.
        bar_w=$total_nodes

        im=$nodes_imaged
        up=$nodes_up
        fl=$nodes_failed
        T=$bar_w
        [ "$im" -gt "$T" ] && im=$T
        [ "$up" -gt "$T" ] && up=$T
        [ "$fl" -gt "$T" ] && fl=$T
        boot_only=$((up - im))
        [ "$boot_only" -lt 0 ] && boot_only=0
        max_boot=$((T - im - fl))
        [ "$max_boot" -lt 0 ] && max_boot=0
        [ "$boot_only" -gt "$max_boot" ] && boot_only=$max_boot
        dot_count=$((T - im - boot_only - fl))
        [ "$dot_count" -lt 0 ] && dot_count=0

        im_s=$(printf '%*s' "$im" '' | tr ' ' '#')
        bo_s=$(printf '%*s' "$boot_only" '' | tr ' ' ':')
        do_s=$(printf '%*s' "$dot_count" '' | tr ' ' '.')
        fa_s=$(printf '%*s' "$fl" '' | tr ' ' 'x')
        bar_colored="${GREEN}${im_s}${YELLOW}${bo_s}${NC}${do_s}${RED}${fa_s}${NC}"

        # Compact line with stall indicator.
        # i = imaged (#), b = up-only (:), f = failed (x), w = waiting (.),
        # /N = plan size (selected nodes), bt=M = current OMF batch size when known.
        flock 3
        if [ -n "$omf_tot" ] && [ "$omf_tot" -ge 1 ] 2>/dev/null; then
            if [ "$stall_time" -ge 30 ] && [ "$nodes_up" -lt "$omf_tot" ]; then
                printf "\r  ${YELLOW}[%d:%02d/%d:00]${NC} [%s] i%db%df%dw%d/%d bt%d ${RED}stall:%d/%ds${NC} ${CLR}" \
                    "$mins" "$secs" "$t_mins" "$bar_colored" \
                    "$im" "$boot_only" "$fl" "$dot_count" "$total_nodes" "$omf_tot" "$stall_time" "$BOOT_STALL_TIMEOUT"
            else
                printf "\r  ${YELLOW}[%d:%02d/%d:00]${NC} [%s] i%db%df%dw%d/%d bt%d ${CLR}" \
                    "$mins" "$secs" "$t_mins" "$bar_colored" \
                    "$im" "$boot_only" "$fl" "$dot_count" "$total_nodes" "$omf_tot"
            fi
        else
            printf "\r  ${YELLOW}[%d:%02d/%d:00]${NC} [%s] …p%d ${CLR}" \
                "$mins" "$secs" "$t_mins" "$bar_colored" "$total_nodes"
        fi
        flock -u 3
        sleep 1
    done
) &
timer_pid=$!

# Ensure timer is killed on script exit (success or failure)
cleanup_timer() {
    [ -n "$timer_pid" ] && kill $timer_pid 2>/dev/null || true
    wait $timer_pid 2>/dev/null || true
    flock 3
    printf "\r${CLR}"
    flock -u 3
}
trap 'cleanup_timer; rm -rf "$tmpdir"' EXIT

# Run omf load - save output and track PID for stall detection
omf_output_file="$tmpdir/omf_output.txt"
set +e  # Don't exit on error here

# Run omf in background with output processing.
(
    stdbuf -oL omf load -i wifi-experiment.ndz -t "$node_list" -o "$IMAGING_TIMEOUT" 2>&1 | \
    grep --line-buffered -v "^/.*warning:" | \
    stdbuf -oL tee "$omf_output_file" | \
    while IFS= read -r line; do
        # Update progress: legacy OMF 5.4 "Waiting for nodes (Up/Down/Total): U/..."
        if echo "$line" | grep -q "Waiting for nodes"; then
            up_count=$(echo "$line" | grep -oP '\): \K[0-9]+' || echo "0")
            tot=$(echo "$line" | grep -oP '\): [0-9]+/[0-9]+/\K[0-9]+' || echo "")
            [ -n "$up_count" ] && echo "$up_count" > "$tmpdir/nodes_up"
            [ -n "$tot" ] && echo "$tot" > "$tmpdir/nodes_total_omf"
        # Newer `omf load` UI: "Round 1: U/T nodes online" or "Loading disk image onto T nodes"
        elif echo "$line" | grep -qE '^[[:space:]]*Round [0-9]+:[[:space:]]*[0-9]+/[0-9]+[[:space:]]+nodes online'; then
            up_count=$(echo "$line" | grep -oP 'Round [0-9]+: \K[0-9]+' | head -1)
            tot=$(echo "$line" | grep -oP 'Round [0-9]+: [0-9]+/\K[0-9]+' | head -1)
            [ -n "$up_count" ] && echo "$up_count" > "$tmpdir/nodes_up"
            [ -n "$tot" ] && echo "$tot" > "$tmpdir/nodes_total_omf"
        elif echo "$line" | grep -qiP 'Loading disk image.*onto\s+[0-9]+\s+nodes'; then
            tot=$(echo "$line" | grep -oiP 'onto\s+\K[0-9]+' | head -1)
            if [ -n "$tot" ]; then
                echo "$tot" > "$tmpdir/nodes_total_omf"
                # Seed failure count once based on (plan - first-batch). This makes the bar
                # immediately reflect nodes that never even entered the current imaging batch.
                cur_fail=$(cat "$tmpdir/nodes_failed_bar" 2>/dev/null | tr -d ' \n\r' || echo "0")
                [ -z "$cur_fail" ] && cur_fail=0
                if [ "$total_nodes" -gt "$tot" ] 2>/dev/null; then
                    target_fail=$((total_nodes - tot))
                    # Don't decrease failures if we already counted some real "Giving up" events.
                    if [ "$cur_fail" -lt "$target_fail" ] 2>/dev/null; then
                        echo "$target_fail" > "$tmpdir/nodes_failed_bar"
                    fi
                fi
            fi
        # OMF progress: first number inside Progress(...) is finished/imaged count (when present).
        elif echo "$line" | grep -qP '(?i)Progress\s*\('; then
            done_n=$(echo "$line" | grep -oP '(?i)Progress\s*\(\s*\K[0-9]+' | head -1)
            [ -n "$done_n" ] && echo "$done_n" > "$tmpdir/nodes_imaged"
        elif echo "$line" | grep -qi 'Giving up on node'; then
            f=$(cat "$tmpdir/nodes_failed_bar" 2>/dev/null | tr -d ' \n\r' || echo "0")
            [ -z "$f" ] && f=0
            echo $((f + 1)) > "$tmpdir/nodes_failed_bar"
        fi
        # Print the line (clearing progress bar first, it will redraw)
        flock 3
        printf "\r${CLR}"
        echo "$line"
        flock -u 3
    done
) &
omf_bg_pid=$!
echo "$omf_bg_pid" > "$omf_pid_file"

# Wait for omf to finish, with overall timeout
wait_start=$(date +%s)
omf_exit=0
while kill -0 "$omf_bg_pid" 2>/dev/null; do
    now=$(date +%s)
    elapsed=$((now - wait_start))
    if [ "$elapsed" -ge "$IMAGING_TIMEOUT" ]; then
        flock 3
        printf "\r${CLR}\n"
        echo -e "  ${YELLOW}Overall timeout reached (${IMAGING_TIMEOUT}s) - stopping imaging${NC}"
        flock -u 3
        kill_tree "$omf_bg_pid" TERM
        sleep 2
        kill_tree "$omf_bg_pid" 9
        omf_exit=124
        break
    fi
    sleep 1
done
# Wait and suppress "Terminated" noise from killed pipeline
wait "$omf_bg_pid" 2>/dev/null || omf_exit=$?
# Ensure no orphans survive
kill_tree "$omf_bg_pid" 9 2>/dev/null

# Check if stall detection triggered the stop
stall_aborted=0
if [ -f "$tmpdir/stall_triggered" ]; then
    # We killed `omf load` early, so we cannot reliably determine per-node imaging success.
    # Instead of exiting, we continue with a conservative subset:
    # we will later limit "turn on" candidates to the first OMF imaging batch size (T).
    stall_aborted=1
    omf_exit=0
fi
set -e

# If imaging was interrupted due to overall timeout, stop here.
if [ "$omf_exit" -ne 0 ]; then
    # Stop the timer (if still running)
    cleanup_timer
    timer_pid=""  # Prevent double-kill in trap

    imaging_end=$(date +%s)
    imaging_elapsed=$((imaging_end - imaging_start))
    imaging_mins=$((imaging_elapsed / 60))
    imaging_secs=$((imaging_elapsed % 60))

    echo -e "  ${YELLOW}Imaging interrupted (exit=$omf_exit) after ${imaging_mins}m ${imaging_secs}s — not powering on unknown-imaged nodes${NC}"
    exit 1
fi

# Stop the timer
cleanup_timer
timer_pid=""  # Prevent double-kill in trap

# Show imaging duration
imaging_end=$(date +%s)
imaging_elapsed=$((imaging_end - imaging_start))
imaging_mins=$((imaging_elapsed / 60))
imaging_secs=$((imaging_elapsed % 60))
if [ "$stall_aborted" -eq 1 ]; then
    echo -e "  ${YELLOW}Imaging stopped (stall) after ${imaging_mins}m ${imaging_secs}s${NC}"
else
    echo -e "  ${GREEN}Imaging completed in ${imaging_mins}m ${imaging_secs}s${NC}"
fi

# Conservative continuation after stall: limit candidates to first OMF batch
if [ "$stall_aborted" -eq 1 ]; then
    batch_size=$(cat "$tmpdir/nodes_total_omf" 2>/dev/null || echo "")
    if [ -n "$batch_size" ] && [ "$batch_size" -ge 1 ] 2>/dev/null && [ "$batch_size" -lt "$total_nodes" ] 2>/dev/null; then
        # Mark the nodes that were never in OMF's batch as failed, then slice.
        dropped=0
        for (( i=batch_size; i<${#node_keys[@]}; i++ )); do
            mark_node_failed "${node_keys[i]}"
            ((dropped++)) || true
        done
        required_nodes=("${required_nodes[@]:0:$batch_size}")
        node_keys=("${node_keys[@]:0:$batch_size}")
        total_nodes=${#required_nodes[@]}
        echo -e "  ${YELLOW}Stall: continuing with ${batch_size} batch nodes, ${dropped} excluded nodes marked failed.${NC}"
    fi
fi

# Even without stall, OMF may have silently dropped nodes (batch < plan).
# Mark the extras as failed so they don't linger in the plan.
if [ "$stall_aborted" -eq 0 ]; then
    omf_batch=$(cat "$tmpdir/nodes_total_omf" 2>/dev/null | tr -dc '0-9')
    omf_batch=${omf_batch:-0}
    if [ "$omf_batch" -ge 1 ] && [ "$omf_batch" -lt "${#node_keys[@]}" ] 2>/dev/null; then
        dropped=0
        for (( i=omf_batch; i<${#node_keys[@]}; i++ )); do
            if ! is_node_failed "${node_keys[i]}"; then
                mark_node_failed "${node_keys[i]}"
                ((dropped++)) || true
            fi
        done
        if [ "$dropped" -gt 0 ]; then
            echo -e "  ${YELLOW}OMF batch was ${omf_batch}/${#node_keys[@]} — ${dropped} excluded nodes marked failed.${NC}"
        fi
        required_nodes=("${required_nodes[@]:0:$omf_batch}")
        node_keys=("${node_keys[@]:0:$omf_batch}")
        total_nodes=${#required_nodes[@]}
    fi
fi

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
        if omf load -i wifi-experiment.ndz -t "$group_list" -o "$IMAGING_TIMEOUT" 2>&1 | grep -v "^/.*warning:" | tee "$group_omf_output"; then
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

# After a stall, OMF never printed "Giving up" for the stragglers so all batch
# nodes passed the filter above. Ping-sweep to drop nodes that never PXE-booted.
if [ "$stall_aborted" -eq 1 ] && [ ${#successful_nodes[@]} -gt 1 ]; then
    echo -e "\n${CYAN}Pre-power-on ping sweep (filtering unreachable nodes)...${NC}"
    pre_ok_nodes=()
    pre_ok_keys=()
    pre_pids=()
    for i in "${!successful_nodes[@]}"; do
        (
            if ping -c 1 -W 3 "${successful_nodes[i]}" >/dev/null 2>&1; then
                echo "ok" > "$tmpdir/pre_ping_$i"
            else
                echo "fail" > "$tmpdir/pre_ping_$i"
            fi
        ) &
        pre_pids+=($!)
    done
    wait "${pre_pids[@]}" 2>/dev/null || true

    for i in "${!successful_nodes[@]}"; do
        status=$(cat "$tmpdir/pre_ping_$i" 2>/dev/null || echo "fail")
        if [ "$status" = "ok" ]; then
            pre_ok_nodes+=("${successful_nodes[i]}")
            pre_ok_keys+=("${successful_keys[i]}")
        else
            echo -e "  ${RED}x${NC} ${successful_nodes[i]} — unreachable after imaging, skipping"
            mark_node_failed "${successful_keys[i]}"
        fi
    done

    pre_total=${#successful_nodes[@]}
    if [ ${#pre_ok_nodes[@]} -gt 0 ]; then
        successful_nodes=("${pre_ok_nodes[@]}")
        successful_keys=("${pre_ok_keys[@]}")
        echo -e "  ${GREEN}${#successful_nodes[@]}/${pre_total} nodes reachable after imaging${NC}"
    else
        echo -e "${RED}No nodes reachable after imaging. Nothing to power on.${NC}"
        exit 1
    fi
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

# Stall detection for reachability:
# If the number of responding nodes stops increasing for BOOT_STALL_TIMEOUT and
# we're already above BOOT_MIN_PERCENT of the candidate set, stop early.
verify_last_up_count=0
verify_last_progress_time=$(date +%s)
candidate_total=${#successful_nodes[@]}

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

    # Track progress changes for reachability stall detection
    if [ "$up_count" -gt "$verify_last_up_count" ]; then
        verify_last_up_count=$up_count
        verify_last_progress_time=$current_time
    fi

    verify_stall_time=$((current_time - verify_last_progress_time))
    if [ "$candidate_total" -gt 0 ] 2>/dev/null; then
        verify_pct=$((up_count * 100 / candidate_total))
    else
        verify_pct=0
    fi
    if [ "$all_up" = "false" ] && [ "$candidate_total" -gt 0 ] 2>/dev/null; then
        if [ "$verify_stall_time" -ge "${BOOT_STALL_TIMEOUT:-120}" ] 2>/dev/null && [ "$verify_pct" -ge "${BOOT_MIN_PERCENT:-50}" ] 2>/dev/null; then
            echo -e "\n  ${YELLOW}Stall detected: ${up_count}/${candidate_total} nodes responding, no improvement for ${verify_stall_time}s — proceeding${NC}"
            break
        fi
    fi
    
    # Show progress on same line, with stall countdown when no progress
    if [ "$verify_stall_time" -ge 10 ] && [ "$up_count" -gt 0 ] && [ "$all_up" = "false" ]; then
        printf "\r  [Elapsed: %d:%02d] %d/%d nodes responding ${RED}stall:%d/%ds${NC}${CLR}" \
            "$mins" "$secs" "$up_count" "${#successful_nodes[@]}" "$verify_stall_time" "${BOOT_STALL_TIMEOUT:-120}"
    else
        printf "\r  [Elapsed: %d:%02d] %d/%d nodes responding${CLR}" "$mins" "$secs" "$up_count" "${#successful_nodes[@]}"
    fi
    
    if [ "$all_up" = "true" ]; then
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
