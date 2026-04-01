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
    local required_commands=("ssh" "omf" "wget")
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
    # Dynamic layout: compute col width from longest node name, fit as many columns as terminal allows.
    local max_name_len=0
    for k in "${all_keys[@]}"; do
        IFS='|' read -r hostname _ <<< "${NODES[$k]}"
        local sn="${hostname%%.*}"
        [ ${#sn} -gt "$max_name_len" ] && max_name_len=${#sn}
    done
    # Each cell: " NNN. [x] <name>  " — index(4) + ". [x] "(6) + name + padding(2)
    local cell_w=$((max_name_len + 13))
    local term_w
    term_w=$(tput cols 2>/dev/null || echo 80)
    local cols=$(( (term_w - 2) / cell_w ))
    [ "$cols" -lt 1 ] && cols=1
    [ "$cols" -gt 6 ] && cols=6

    local cursor=0  # Current cursor position (0-indexed)
    local total=${#all_keys[@]}

    # Paging: compute visible rows from terminal height
    local term_h page_offset=0
    term_h=$(tput lines 2>/dev/null || echo 24)
    # Reserve lines for: banner(~4) + header(2) + footer(5) + failed line(1) = ~12
    local header_lines=12
    local page_rows=$(( term_h - header_lines ))
    [ "$page_rows" -lt 3 ] && page_rows=3

    # grid_start_row: screen row where the node grid begins (set by draw_grid)
    local grid_start_row=0

    # Repaint a single cell in-place + update the summary header line.
    # Used for Space toggle — avoids full redraw.
    repaint_cell() {
        local i=$1
        local vis=$((i - page_offset * cols))
        local cell_total=$((4 + cell_w))
        local row=$((grid_start_row + vis / cols))
        local col=$(( (vis % cols) * cell_total ))
        local k="${all_keys[i]}"
        local idx=$((i + 1))
        local idx_pad hostname short_name marker plain len pad
        if [ "$total" -ge 100 ]; then idx_pad=$(printf "%3d" "$idx"); else idx_pad=$(printf "%2d" "$idx"); fi
        IFS='|' read -r hostname _ <<< "${NODES[$k]}"
        short_name="${hostname%%.*}"
        if [ "$i" -eq "$cursor" ]; then marker="${YELLOW}>${NC}"; else marker=" "; fi
        plain="${idx_pad}. [x] ${short_name}"
        len=${#plain}
        pad=$((cell_w - len - 1))
        [ "$pad" -lt 0 ] && pad=0

        tput cup "$row" "$col"
        if is_node_failed "$k" 2>/dev/null && [ "${unfail[$k]}" -ne 1 ] 2>/dev/null; then
            echo -ne "    ${marker}${RED}${idx_pad}. [!] ${short_name}${NC}"
        elif [ "${enabled[$k]}" -eq 1 ] 2>/dev/null; then
            echo -ne "    ${marker}${CYAN}${idx_pad}.${NC} [${GREEN}x${NC}] ${short_name}"
        else
            echo -ne "    ${marker}${CYAN}${idx_pad}.${NC} [${RED} ${NC}] ${short_name}"
        fi
        printf '%*s' "$pad" ''

        # Update summary header line (row 14+2 = banner + title + site, then summary is next)
        local sel_count=0 failed_count=0
        for k in "${all_keys[@]}"; do
            [ "${enabled[$k]}" -eq 1 ] 2>/dev/null && ((sel_count++)) || true
            is_node_failed "$k" 2>/dev/null && [ "${unfail[$k]}" -ne 1 ] 2>/dev/null && ((failed_count++)) || true
        done
        tput cup 16 0  # summary line: banner(14) + title(1) + site(1) = row 16
        echo -ne "     ${GREEN}${sel_count} selected${NC} / ${total} total"
        [ "$failed_count" -gt 0 ] && echo -ne "  ${RED}${failed_count} failed${NC}"
        tput el  # clear rest of line

        # Park cursor
        tput cup "$((grid_start_row + page_rows + 5))" 0
    }

    # Swap the > marker between two grid indices (no full redraw).
    # Only call when both indices are on the currently visible page.
    move_marker() {
        local old=$1 new=$2
        local old_vis=$((old - page_offset * cols))
        local new_vis=$((new - page_offset * cols))
        # Each cell is (4 + cell_w) chars wide. The > marker is at offset 4 within the cell.
        local cell_total=$((4 + cell_w))
        local old_row=$((grid_start_row + old_vis / cols))
        local old_col=$(( (old_vis % cols) * cell_total + 4 ))
        local new_row=$((grid_start_row + new_vis / cols))
        local new_col=$(( (new_vis % cols) * cell_total + 4 ))
        # Erase old marker
        tput cup "$old_row" "$old_col"
        echo -n " "
        # Draw new marker
        tput cup "$new_row" "$new_col"
        echo -ne "${YELLOW}>${NC}"
        # Park terminal cursor out of the way
        tput cup "$((grid_start_row + page_rows + 5))" 0
    }

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
        echo -e "     ${CYAN}Site: ${SITE:-unknown} | Nodes: ${method_label} | Full name: <shortname>.${NODE_DOMAIN}${NC}"

        # Count selected and failed for header summary
        local sel_count=0 failed_count=0
        for k in "${all_keys[@]}"; do
            [ "${enabled[$k]}" -eq 1 ] 2>/dev/null && ((sel_count++)) || true
            is_node_failed "$k" 2>/dev/null && [ "${unfail[$k]}" -ne 1 ] 2>/dev/null && ((failed_count++)) || true
        done
        echo -e "     ${GREEN}${sel_count} selected${NC} / ${total} total${failed_count:+  ${RED}${failed_count} failed${NC}}\n"

        # Compute total grid rows and paging
        local total_rows=$(( (total + cols - 1) / cols ))
        local cursor_row=$((cursor / cols))

        # Auto-scroll: ensure cursor row is visible
        if [ "$cursor_row" -lt "$page_offset" ]; then
            page_offset=$cursor_row
        elif [ "$cursor_row" -ge $((page_offset + page_rows)) ]; then
            page_offset=$((cursor_row - page_rows + 1))
        fi

        # Page indicator
        if [ "$total_rows" -gt "$page_rows" ]; then
            local cur_page=$((page_offset / page_rows + 1))
            local total_pages=$(( (total_rows + page_rows - 1) / page_rows ))
            echo -e "     ${CYAN}Page ${cur_page}/${total_pages}${NC} (${PURPLE}PgUp/PgDn${NC} to scroll)"
        fi
        echo ""

        local start_idx=$((page_offset * cols))
        local end_idx=$(( (page_offset + page_rows) * cols ))
        [ "$end_idx" -gt "$total" ] && end_idx=$total

        # Grid start row (0-based for tput cup):
        # Banner: 14 lines, then title(1) + site(1) + summary+blank(2) + page?(1) + blank(1)
        local total_rows_all=$(( (total + cols - 1) / cols ))
        grid_start_row=$((14 + 4))  # banner(14) + title + site + summary + blank
        if [ "$total_rows_all" -gt "$page_rows" ]; then
            ((grid_start_row += 1)) || true  # page indicator
        fi
        ((grid_start_row += 1)) || true  # blank line after page indicator / summary

        local i idx idx_pad hostname short_name plain len pad k marker
        for (( i=start_idx; i<end_idx; i++ )); do
            k="${all_keys[i]}"
            idx=$((i + 1))
            if [ "$total" -ge 100 ]; then idx_pad=$(printf "%3d" "$idx"); else idx_pad=$(printf "%2d" "$idx"); fi
            IFS='|' read -r hostname _ <<< "${NODES[$k]}"
            short_name="${hostname%%.*}"
            if [ "$i" -eq "$cursor" ]; then marker="${YELLOW}>${NC}"; else marker=" "; fi
            plain="${idx_pad}. [x] ${short_name}"
            len=${#plain}
            pad=$((cell_w - len - 1))
            [ "$pad" -lt 0 ] && pad=0
            if is_node_failed "$k" 2>/dev/null && [ "${unfail[$k]}" -ne 1 ] 2>/dev/null; then
                echo -ne "    ${marker}${RED}${idx_pad}. [!] ${short_name}${NC}"
            elif [ "${enabled[$k]}" -eq 1 ] 2>/dev/null; then
                echo -ne "    ${marker}${CYAN}${idx_pad}.${NC} [${GREEN}x${NC}] ${short_name}"
            else
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
        echo -e "     ${PURPLE}PgUp/PgDn${NC} page   ${PURPLE}Home/End${NC} jump"
    }

    # Read a single keypress, properly consuming escape sequences.
    read_key() {
        local c
        REPLY=""
        IFS= read -rsn1 c
        if [[ "$c" == $'\x1b' ]]; then
            local seq=""
            while IFS= read -rsn1 -t 0.05 c; do
                seq+="$c"
                [[ "$c" =~ [A-Za-z~] ]] && break
            done
            REPLY=$'\x1b'"${seq}"
        else
            REPLY="$c"
        fi
    }

    local needs_full=1  # first iteration always does full draw
    local prev_cursor=0

    # Suppress terminal echo for the entire selection loop.
    # This prevents escape sequences from printing to screen during repaints.
    local old_stty
    old_stty=$(stty -g)
    stty -echo

    while true; do
        if [ "$needs_full" -eq 1 ]; then
            draw_grid
            needs_full=0
        fi
        prev_cursor=$cursor
        read_key
        local key="$REPLY"
        local items_per_page=$((page_rows * cols))
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
            $'\x1b[5~') # PgUp
                cursor=$((cursor - items_per_page))
                [ "$cursor" -lt 0 ] && cursor=0
                needs_full=1
                ;;
            $'\x1b[6~') # PgDn
                cursor=$((cursor + items_per_page))
                [ "$cursor" -ge "$total" ] && cursor=$((total - 1))
                needs_full=1
                ;;
            $'\x1b[H'|$'\x1b[1~') # Home
                cursor=0
                needs_full=1
                ;;
            $'\x1b[F'|$'\x1b[4~') # End
                cursor=$((total - 1))
                needs_full=1
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
                repaint_cell "$cursor"
                ;;
            a|A) # Select all (marks failed for unfail on save)
                for k in "${all_keys[@]}"; do
                    enabled[$k]=1
                    is_node_failed "$k" 2>/dev/null && unfail[$k]=1
                done
                needs_full=1
                ;;
            n|N) # Select none (also clears unfail marks)
                for k in "${all_keys[@]}"; do enabled[$k]=0; unfail[$k]=0; done
                needs_full=1
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
                needs_full=1
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
                stty "$old_stty"
                return 0
                ;;
            q|Q) # Quit without saving
                stty "$old_stty"
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
                needs_full=1
                ;;
        esac

        # Arrow moves on the same page: just swap the > marker
        if [ "$needs_full" -eq 0 ] && [ "$cursor" -ne "$prev_cursor" ]; then
            # Check both are on the current visible page
            local old_vis=$((prev_cursor - page_offset * cols))
            local new_vis=$((cursor - page_offset * cols))
            local vis_count=$((page_rows * cols))
            if [ "$old_vis" -ge 0 ] && [ "$old_vis" -lt "$vis_count" ] \
               && [ "$new_vis" -ge 0 ] && [ "$new_vis" -lt "$vis_count" ]; then
                move_marker "$prev_cursor" "$cursor"
            else
                # Crossed page boundary — full redraw
                needs_full=1
            fi
        fi
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
    # Check if plan file exists and has content
    if [ -f "$PLAN_FILE" ] && [ -s "$PLAN_FILE" ]; then
        echo -e "     ${YELLOW}║${NC}  ${CYAN}2.${NC} Initialize selected nodes (load image, power on)     ${YELLOW}║${NC}"
        echo -e "     ${YELLOW}║${NC}  ${CYAN}3.${NC} Setup selected nodes (cleanup + install packages)    ${YELLOW}║${NC}"
        echo -e "     ${YELLOW}║${NC}  ${CYAN}4.${NC} Check selected nodes (ping reachability)             ${YELLOW}║${NC}"
        echo -e "     ${YELLOW}║${NC}  ${CYAN}5.${NC} Power off selected nodes                             ${YELLOW}║${NC}"
    else
        echo -e "     ${YELLOW}║${NC}  ${RED}2.${NC} Initialize selected nodes (select nodes first)       ${YELLOW}║${NC}"
        echo -e "     ${YELLOW}║${NC}  ${RED}3.${NC} Setup selected nodes (select nodes first)            ${YELLOW}║${NC}"
        echo -e "     ${YELLOW}║${NC}  ${RED}4.${NC} Check selected nodes (select nodes first)            ${YELLOW}║${NC}"
        echo -e "     ${YELLOW}║${NC}  ${RED}5.${NC} Power off selected nodes (select nodes first)        ${YELLOW}║${NC}"
    fi
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
        2|3|4|5)
            if [ ! -f "$PLAN_FILE" ] || [ ! -s "$PLAN_FILE" ]; then
                echo -e "${RED}Please select nodes first (option 1).${NC}"
            else
                case $choice in
                    2) check_requirements && initialize_environment ;;
                    3) check_requirements && setup_nodes ;;
                    4) check_requirements && check_nodes ;;
                    5) check_requirements && power_off_all_nodes ;;
                esac
            fi
            ;;
        6) show_about ; continue ;;
        7) echo -e "\n${GREEN}Bye.${NC}"; exit 0 ;;
        *) echo -e "${RED}Invalid option.${NC}" ;;
    esac
    echo -e "\n${PURPLE}Press Enter for menu...${NC}"
    read
done
