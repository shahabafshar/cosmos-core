#!/bin/bash

# Run from repo root so .cosmos_plan, logs/, and script paths resolve
COSMOS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$COSMOS_ROOT"
source "$COSMOS_ROOT/scripts/config.sh"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
NC='\033[0m'

# Start session logging (single log file for entire session)
export LOG_FILE=$(start_logging "session")
write_log_header "Cosmos Session"
echo -e "${CYAN}Session log:${NC} $LOG_FILE"
sleep 1

# Log function for consistent logging
log() {
    local msg="$1"
    echo "$msg" | sed 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE"
}

# Cosmos banner (upper part of menu)
COSMOS_BANNER="
       ${CYAN}    ·    ✦    .         *         .    ✦    ·    .    *${NC}
       ═══════════════════════════════════════════════════════
         ██████╗ ██████╗ ███████╗███╗   ███╗ ██████╗ ███████╗
        ██╔════╝██╔═══██╗██╔════╝████╗ ████║██╔═══██╗██╔════╝
        ██║     ██║   ██║███████╗██╔████╔██║██║   ██║███████╗
        ██║     ██║   ██║╚════██║██║╚██╔╝██║██║   ██║╚════██║
        ╚██████╗╚██████╔╝███████║██║ ╚═╝ ██║╚██████╔╝███████║
         ╚═════╝ ╚═════╝ ╚══════╝╚═╝     ╚═╝ ╚═════╝ ╚══════╝
                 ╺━━━┓  ▄█▀  ▄█▀█▄  █▀▀▄  █▀▀▀  ┏━━━╸
                     ┃  █    █   █  █▄▄▀  █▀▀   ┃
                 ╺━━━┛  ▀█▄  ▀█▄█▀  █  █  █▄▄▄  ┗━━━╸
       ═══════════════════════════════════════════════════════${NC}
${CYAN}         ✦    ·    .         *         .    ·    ✦    .    *${NC}"

check_requirements() {
    echo -e "\n${CYAN}Checking requirements...${NC}"
    local required_commands=("ssh" "omf" "omf-5.4" "wget")
    local missing=()
    for cmd in "${required_commands[@]}"; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "${RED}Missing: ${missing[*]}${NC}"
        return 1
    fi
    [ -f "$COSMOS_ROOT/scripts/config.sh" ] || { echo -e "${RED}config.sh not found${NC}"; return 1; }
    [ -d "$LOG_DIR" ] || mkdir -p "$LOG_DIR"
    echo -e "${GREEN}OK${NC}"
    return 0
}

initialize_environment() {
    echo -e "\n${CYAN}Initializing ORBIT testbed...${NC}"
    if [ ! -f "$COSMOS_ROOT/scripts/init.sh" ]; then
        echo -e "${RED}init.sh not found${NC}"
        return 1
    fi
    bash "$COSMOS_ROOT/scripts/init.sh"
}

setup_nodes() {
    echo -e "\n${CYAN}Setting up nodes (cleanup + basic packages)...${NC}"
    if [ ! -f "$COSMOS_ROOT/scripts/setup.sh" ]; then
        echo -e "${RED}setup.sh not found${NC}"
        return 1
    fi
    bash "$COSMOS_ROOT/scripts/setup.sh"
}

power_off_all_nodes() {
    echo -e "\n${CYAN}Powering off all nodes in the grid...${NC}"
    if ! command -v omf &>/dev/null; then
        echo -e "${RED}omf not found${NC}"
        return 1
    fi
    omf tell -a offh -t all
    echo -e "${GREEN}All nodes powered off.${NC}"
    return 0
}

check_nodes() {
    # Log section header
    {
        echo ""
        echo "════════════════════════════════════════════════"
        echo "  CHECK — $(date '+%Y-%m-%d %H:%M:%S')"
        echo "════════════════════════════════════════════════"
        echo ""
    } >> "$LOG_FILE"
    
    echo -e "\n${CYAN}Checking nodes (ping, in parallel)...${NC}"
    [ ${#NODES[@]} -eq 0 ] && { echo -e "${RED}No nodes configured${NC}"; return 1; }
    
    local tmpdir
    tmpdir=$(mktemp -d) || { echo -e "${RED}Failed to create temp dir${NC}"; return 1; }
    trap "rm -rf '$tmpdir'" RETURN
    
    # Collect nodes to check (skip failed)
    local nodes_to_check=() keys_to_check=() skipped=0
    while IFS= read -r node_name; do
        [ -z "$node_name" ] && continue
        if is_node_failed "$node_name" 2>/dev/null; then
            ((skipped++)) || true
            continue
        fi
        IFS='|' read -r hostname _ <<< "${NODES[$node_name]}"
        nodes_to_check+=("$hostname")
        keys_to_check+=("$node_name")
    done < <(get_enabled_node_keys)
    
    [ $skipped -gt 0 ] && echo -e "${YELLOW}(Skipping $skipped failed nodes)${NC}"
    
    if [ ${#nodes_to_check[@]} -eq 0 ]; then
        echo -e "${RED}No nodes to check.${NC}"
        return 1
    fi
    
    # Parallel ping
    local pids=()
    for i in "${!nodes_to_check[@]}"; do
        hostname="${nodes_to_check[i]}"
        ( ping -c 1 -W 2 "$hostname" >/dev/null 2>&1; echo $? > "$tmpdir/$i" ) &
        pids+=($!)
    done
    wait "${pids[@]}" 2>/dev/null
    
    # Collect results
    local all_ok=true ok_count=0 fail_count=0
    {
        echo ""
        for i in "${!nodes_to_check[@]}"; do
            hostname="${nodes_to_check[i]}"
            key="${keys_to_check[i]}"
            code=$(cat "$tmpdir/$i" 2>/dev/null)
            if [ "$code" = "0" ]; then
                echo -e "  ${GREEN}✓${NC} $hostname"
                ((ok_count++)) || true
            else
                echo -e "  ${RED}✗${NC} $hostname"
                ((fail_count++)) || true
                all_ok=false
            fi
        done
        echo ""
        echo -e "${CYAN}Summary:${NC} ${GREEN}$ok_count OK${NC}, ${RED}$fail_count FAIL${NC}"
    } | tee >(sed 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE")
    
    $all_ok && return 0 || return 1
}

configure_node_plan() {
    local all_keys
    all_keys=($(printf '%s\n' "${!NODES[@]}" | sort -V))
    declare -A enabled
    declare -A unfail  # Track nodes to unfail on save
    local k
    for k in "${all_keys[@]}"; do enabled[$k]=1; unfail[$k]=0; done
    if [ -n "${PLAN_FILE:-}" ] && [ -f "$PLAN_FILE" ] && [ -s "$PLAN_FILE" ]; then
        for k in "${all_keys[@]}"; do enabled[$k]=0; done
        while IFS= read -r k; do
            k="${k%%[[:space:]]*}"
            [ -z "$k" ] && continue
            [ -n "${NODES[$k]+x}" ] && enabled[$k]=1
        done < "$PLAN_FILE"
    fi
    local col_w=20 cols=3
    local cursor=0  # Current cursor position (0-indexed)
    local total=${#all_keys[@]}

    # Function to draw the grid
    draw_grid() {
        clear
        echo -e "$COSMOS_BANNER"
        echo -e "     ${YELLOW}Select nodes — choose which nodes to work with${NC}"
        local method_label
        case "$DISCOVERY_METHOD" in
            omf)       method_label="discovered via OMF" ;;
            arp)       method_label="discovered via ARP (may be incomplete)" ;;
            hardcoded) method_label="hardcoded fallback" ;;
            cached)    method_label="loaded from cache (r to refresh)" ;;
            *)         method_label="unknown" ;;
        esac
        echo -e "     ${CYAN}Site: ${SITE:-unknown} | Nodes: ${method_label} | Full name: <shortname>.${NODE_DOMAIN}${NC}\n"
        local i idx idx_pad hostname short_name plain len pad k marker failed_count=0
        for i in "${!all_keys[@]}"; do
            k="${all_keys[i]}"
            idx=$((i + 1))
            idx_pad=$(printf "%2d" "$idx")
            IFS='|' read -r hostname _ <<< "${NODES[$k]}"
            short_name="${hostname%%.*}"
            # Cursor marker
            if [ "$i" -eq "$cursor" ]; then marker="${YELLOW}>${NC}"; else marker=" "; fi
            # Check if node is failed (and not marked for unfail)
            if is_node_failed "$k" 2>/dev/null && [ "${unfail[$k]}" -ne 1 ] 2>/dev/null; then
                # Failed node - show as unavailable
                plain="${idx_pad}. [!] ${short_name}"
                len=${#plain}
                pad=$((col_w - len - 1))
                [ "$pad" -lt 0 ] && pad=0
                echo -ne "    ${marker}${RED}${idx_pad}. [!] ${short_name}${NC}"
                ((failed_count++)) || true
            elif [ "${enabled[$k]}" -eq 1 ] 2>/dev/null; then
                plain="${idx_pad}. [x] ${short_name}"
                len=${#plain}
                pad=$((col_w - len - 1))
                [ "$pad" -lt 0 ] && pad=0
                echo -ne "    ${marker}${CYAN}${idx_pad}.${NC} [${GREEN}x${NC}] ${short_name}"
            else
                plain="${idx_pad}. [ ] ${short_name}"
                len=${#plain}
                pad=$((col_w - len - 1))
                [ "$pad" -lt 0 ] && pad=0
                echo -ne "    ${marker}${CYAN}${idx_pad}.${NC} [${RED} ${NC}] ${short_name}"
            fi
            printf '%*s' "$pad" ''
            if [ $(( (i + 1) % cols )) -eq 0 ] || [ $((i + 1)) -eq "$total" ]; then
                echo
            fi
        done
        if [ "$failed_count" -gt 0 ]; then
            echo -e "\n     ${RED}[!] = failed (${failed_count}) — select to retry, or r to clear all${NC}"
        fi
        echo -e "\n     ${PURPLE}Arrows${NC} move   ${PURPLE}Space${NC} select/deselect   ${PURPLE}a${NC} All   ${PURPLE}n${NC} None   ${PURPLE}t${NC} Toggle all"
        echo -e "     ${PURPLE}s${NC} Save   ${PURPLE}q${NC} Quit   ${PURPLE}r${NC} Refresh (clears failed)   ${PURPLE}Numbers+Enter${NC} multi-select"
    }

    while true; do
        draw_grid
        # Read single key (handle escape sequences for arrows)
        IFS= read -rsn1 key
        if [[ "$key" == $'\x1b' ]]; then
            read -rsn2 -t 0.01 seq
            key+="$seq"
        fi
        case "$key" in
            $'\x1b[A'|k) # Up
                if [ "$cursor" -ge "$cols" ]; then ((cursor-=cols)); fi
                ;;
            $'\x1b[B'|j) # Down
                if [ $((cursor + cols)) -lt "$total" ]; then ((cursor+=cols)); fi
                ;;
            $'\x1b[C'|l) # Right
                if [ $((cursor + 1)) -lt "$total" ]; then ((cursor++)); fi
                ;;
            $'\x1b[D'|h) # Left
                if [ "$cursor" -gt 0 ]; then ((cursor--)); fi
                ;;
            ' ') # Space - select/deselect current node
                k="${all_keys[cursor]}"
                if [ "${enabled[$k]}" -eq 1 ] 2>/dev/null; then
                    enabled[$k]=0
                    unfail[$k]=0  # If deselecting, don't unfail
                else
                    enabled[$k]=1
                    # Mark for unfail if it was failed (applied on save)
                    is_node_failed "$k" 2>/dev/null && unfail[$k]=1
                fi
                ;;
            a|A) # Select all (marks failed for unfail on save)
                for k in "${all_keys[@]}"; do
                    enabled[$k]=1
                    is_node_failed "$k" 2>/dev/null && unfail[$k]=1
                done
                ;;
            n|N) # Select none (also clears unfail marks)
                for k in "${all_keys[@]}"; do enabled[$k]=0; unfail[$k]=0; done
                ;;
            t|T) # Toggle all
                for k in "${all_keys[@]}"; do
                    if [ "${enabled[$k]}" -eq 1 ] 2>/dev/null; then
                        enabled[$k]=0
                        unfail[$k]=0
                    else
                        enabled[$k]=1
                        is_node_failed "$k" 2>/dev/null && unfail[$k]=1
                    fi
                done
                ;;
            s|S) # Save
                if [ -n "${PLAN_FILE:-}" ]; then
                    : > "$PLAN_FILE"
                    for k in "${all_keys[@]}"; do
                        [ "${enabled[$k]}" -eq 1 ] 2>/dev/null && echo "$k" >> "$PLAN_FILE"
                        # Clear failed status for nodes marked for unfail
                        [ "${unfail[$k]}" -eq 1 ] 2>/dev/null && clear_node_failed "$k"
                    done
                    echo -e "\n${GREEN}Plan saved${NC}"
                    sleep 0.5
                fi
                return 0
                ;;
            q|Q) # Quit without saving
                return 0
                ;;
            r|R) # Refresh - delete cache, clear failed, re-discover
                echo -e "\n${CYAN}Clearing failed nodes and re-discovering...${NC}"
                # Clear failed nodes
                clear_failed_nodes
                # Delete cache to force fresh discovery
                rm -f "$COSMOS_ROOT/.cosmos_nodes"
                unset NODES NODE_NAMES DISCOVERY_METHOD SITE NODE_DOMAIN
                declare -gA NODES
                source "$COSMOS_ROOT/scripts/config.sh"
                
                # Safety check - ensure NODES is populated
                if [ ${#NODES[@]} -eq 0 ]; then
                    echo -e "${RED}Error: No nodes found after refresh!${NC}"
                    echo -e "${YELLOW}Check your network connection or config.sh fallback list.${NC}"
                    sleep 2
                    continue
                fi
                
                all_keys=($(printf '%s\n' "${!NODES[@]}" | sort -V))
                total=${#all_keys[@]}
                cursor=0
                for k in "${all_keys[@]}"; do enabled[$k]=1; done
                if [ -n "${PLAN_FILE:-}" ] && [ -f "$PLAN_FILE" ] && [ -s "$PLAN_FILE" ]; then
                    for k in "${all_keys[@]}"; do enabled[$k]=0; done
                    while IFS= read -r k; do
                        k="${k%%[[:space:]]*}"
                        [ -z "$k" ] && continue
                        [ -n "${NODES[$k]+x}" ] && enabled[$k]=1
                    done < "$PLAN_FILE"
                fi
                local method_msg
                case "$DISCOVERY_METHOD" in
                    omf) method_msg="via OMF" ;;
                    arp) method_msg="via ARP" ;;
                    hardcoded) method_msg="(hardcoded fallback)" ;;
                    *) method_msg="" ;;
                esac
                echo -e "${GREEN}Found ${#NODES[@]} nodes ${method_msg}. Cache updated.${NC}"
                sleep 1
                ;;
            [0-9]) # Number input mode - show prompt and read full input
                local input="$key"
                echo -ne "\n     ${CYAN}Select/deselect:${NC} $input"
                while true; do
                    IFS= read -rsn1 ch
                    if [[ "$ch" == '' ]]; then  # Enter key
                        break
                    elif [[ "$ch" == $'\x7f' || "$ch" == $'\x08' ]]; then  # Backspace
                        if [ ${#input} -gt 0 ]; then
                            input="${input%?}"
                            echo -ne "\r     ${CYAN}Select/deselect:${NC} ${input} \b"
                        fi
                    elif [[ "$ch" == $'\x1b' ]]; then  # Escape - cancel
                        input=""
                        break
                    elif [[ "$ch" =~ [0-9\ ] ]]; then  # Numbers and spaces
                        input+="$ch"
                        echo -n "$ch"
                    fi
                done
                # Process the input - toggle each number
                for num in $input; do
                    if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 1 ] && [ "$num" -le "$total" ]; then
                        k="${all_keys[num-1]}"
                        if [ "${enabled[$k]}" -eq 1 ] 2>/dev/null; then
                            enabled[$k]=0
                            unfail[$k]=0
                        else
                            enabled[$k]=1
                            is_node_failed "$k" 2>/dev/null && unfail[$k]=1
                        fi
                        cursor=$((num - 1))  # Move cursor to last toggled
                    fi
                done
                ;;
        esac
    done
}

show_about() {
    clear
    echo -e "$COSMOS_BANNER"
    echo -e "     ${YELLOW}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "     ${YELLOW}║${NC}                      ${GREEN}About Cosmos Core${NC}                   ${YELLOW}║${NC}"
    echo -e "     ${YELLOW}╠══════════════════════════════════════════════════════════╣${NC}"
    echo -e "     ${YELLOW}║${NC}                                                          ${YELLOW}║${NC}"
    echo -e "     ${YELLOW}║${NC}  ${CYAN}Created by:${NC} Shahab Afshar                               ${YELLOW}║${NC}"
    echo -e "     ${YELLOW}║${NC}  ${CYAN}Course:${NC} Wireless Network Security                       ${YELLOW}║${NC}"
    echo -e "     ${YELLOW}║${NC}  ${CYAN}Professor:${NC} Dr. Mohamed Selim                            ${YELLOW}║${NC}"
    echo -e "     ${YELLOW}║${NC}                                                          ${YELLOW}║${NC}"
    echo -e "     ${YELLOW}║${NC}  ${GREEN}Cosmos Core${NC} is the bootstrap layer for the ORBIT        ${YELLOW}║${NC}"
    echo -e "     ${YELLOW}║${NC}  testbed. It initializes nodes and installs packages;    ${YELLOW}║${NC}"
    echo -e "     ${YELLOW}║${NC}  you choose which nodes are on and run your experiments. ${YELLOW}║${NC}"
    echo -e "     ${YELLOW}║${NC}                                                          ${YELLOW}║${NC}"
    echo -e "     ${YELLOW}╚══════════════════════════════════════════════════════════╝${NC}"
    echo -e "\n${PURPLE}Press Enter to return to main menu...${NC}"
    read
}

show_menu() {
    clear
    echo -e "$COSMOS_BANNER"
    echo -e "     ${YELLOW}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "     ${YELLOW}║${NC}  ${CYAN}1.${NC} Select nodes (choose which nodes to work with)       ${YELLOW}║${NC}"
    echo -e "     ${YELLOW}║${NC}  ${CYAN}2.${NC} Initialize selected nodes (load image, power on)     ${YELLOW}║${NC}"
    echo -e "     ${YELLOW}║${NC}  ${CYAN}3.${NC} Setup selected nodes (cleanup + install packages)    ${YELLOW}║${NC}"
    echo -e "     ${YELLOW}║${NC}  ${CYAN}4.${NC} Check selected nodes (ping reachability)             ${YELLOW}║${NC}"
    echo -e "     ${YELLOW}║${NC}  ${CYAN}5.${NC} Power off selected nodes                             ${YELLOW}║${NC}"
    echo -e "     ${YELLOW}║${NC}  ${CYAN}6.${NC} About Cosmos Core                                    ${YELLOW}║${NC}"
    echo -e "     ${YELLOW}║${NC}  ${CYAN}7.${NC} Exit                                                 ${YELLOW}║${NC}"
    echo -e "     ${YELLOW}╚══════════════════════════════════════════════════════════╝${NC}"
    echo -e "\n${PURPLE}Choice: ${NC}"
}

while true; do
    show_menu
    read -r choice
    case $choice in
        1) check_requirements && configure_node_plan ;;
        2) check_requirements && initialize_environment ;;
        3) check_requirements && setup_nodes ;;
        4) check_requirements && check_nodes ;;
        5) check_requirements && power_off_all_nodes ;;
        6) show_about ; continue ;;
        7) echo -e "\n${GREEN}Bye.${NC}"; exit 0 ;;
        *) echo -e "${RED}Invalid option.${NC}" ;;
    esac
    echo -e "\n${PURPLE}Press Enter for menu...${NC}"
    read
done
