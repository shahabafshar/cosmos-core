#!/bin/bash

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
NC='\033[0m'

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
    [ -f "config.sh" ] || { echo -e "${RED}config.sh not found${NC}"; return 1; }
    [ -d "logs" ] || mkdir -p "logs"
    echo -e "${GREEN}OK${NC}"
    return 0
}

initialize_environment() {
    echo -e "\n${CYAN}Initializing ORBIT testbed...${NC}"
    [ -f "init.sh" ] && bash init.sh || { echo -e "${RED}init.sh not found${NC}"; return 1; }
}

setup_nodes() {
    echo -e "\n${CYAN}Setting up nodes (cleanup + basic packages)...${NC}"
    [ -f "setup.sh" ] && bash setup.sh || { echo -e "${RED}setup.sh not found${NC}"; return 1; }
}

check_nodes() {
    echo -e "\n${CYAN}Checking nodes (ping)...${NC}"
    [ -f "config.sh" ] || { echo -e "${RED}config.sh not found${NC}"; return 1; }
    [ -f "lib.sh" ] || { echo -e "${RED}lib.sh not found${NC}"; return 1; }
    source config.sh
    source lib.sh
    local all_ok=true
    while IFS= read -r node_name; do
        [ -z "$node_name" ] && continue
        IFS='|' read -r hostname _ <<< "${NODES[$node_name]}"
        if check_node "$hostname"; then
            echo -e "${GREEN}  OK${NC} $hostname"
        else
            echo -e "${RED}  FAIL${NC} $hostname"
            all_ok=false
        fi
    done < <(get_enabled_node_keys)
    $all_ok && return 0 || return 1
}

configure_node_plan() {
    [ -f "config.sh" ] || { echo -e "${RED}config.sh not found${NC}"; return 1; }
    [ -f "lib.sh" ] || { echo -e "${RED}lib.sh not found${NC}"; return 1; }
    source config.sh
    source lib.sh
    local all_keys
    all_keys=($(printf '%s\n' "${!NODES[@]}" | sort -V))
    declare -A enabled
    local k
    for k in "${all_keys[@]}"; do enabled[$k]=1; done
    if [ -n "${PLAN_FILE:-}" ] && [ -f "$PLAN_FILE" ] && [ -s "$PLAN_FILE" ]; then
        for k in "${all_keys[@]}"; do enabled[$k]=0; done
        while IFS= read -r k; do
            k="${k%%[[:space:]]*}"
            [ -z "$k" ] && continue
            [ -n "${NODES[$k]+x}" ] && enabled[$k]=1
        done < "$PLAN_FILE"
    fi
    while true; do
        clear
        echo -e "$COSMOS_BANNER"
        echo -e "     ${YELLOW}Node plan — toggle nodes on/off for Init, Setup, Check${NC}\n"
        local i idx hostname
        for i in "${!all_keys[@]}"; do
            k="${all_keys[i]}"
            idx=$((i + 1))
            IFS='|' read -r hostname _ <<< "${NODES[$k]}"
            if [ "${enabled[$k]}" -eq 1 ] 2>/dev/null; then
                echo -e "     ${CYAN}${idx}.${NC} [${GREEN}x${NC}] ${k} — ${hostname}"
            else
                echo -e "     ${CYAN}${idx}.${NC} [${RED} ${NC}] ${k} — ${hostname}"
            fi
        done
        echo -e "\n     ${PURPLE}s${NC} Save and back   ${PURPLE}q${NC} Back without saving"
        echo -e "\n     Toggle by number (e.g. 1), or s/q: "
        read -r choice
        choice="${choice%%[[:space:]]*}"
        if [ -z "$choice" ]; then continue; fi
        if [ "$choice" = "s" ] || [ "$choice" = "S" ]; then
            if [ -n "${PLAN_FILE:-}" ]; then
                : > "$PLAN_FILE"
                for k in "${all_keys[@]}"; do
                    [ "${enabled[$k]}" -eq 1 ] 2>/dev/null && echo "$k" >> "$PLAN_FILE"
                done
                echo -e "\n${GREEN}Plan saved to $PLAN_FILE${NC}"
            fi
            return 0
        fi
        if [ "$choice" = "q" ] || [ "$choice" = "Q" ]; then
            return 0
        fi
        if [[ "$choice" =~ ^[0-9]+$ ]]; then
            idx=$((choice))
            if [ "$idx" -ge 1 ] 2>/dev/null && [ "$idx" -le "${#all_keys[@]}" ]; then
                k="${all_keys[idx-1]}"
                if [ "${enabled[$k]}" -eq 1 ] 2>/dev/null; then enabled[$k]=0; else enabled[$k]=1; fi
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
    echo -e "     ${YELLOW}║${NC}  ${CYAN}1.${NC} Initialize testbed (load image, power on nodes)      ${YELLOW}║${NC}"
    echo -e "     ${YELLOW}║${NC}  ${CYAN}2.${NC} Setup nodes (cleanup + install basic packages)       ${YELLOW}║${NC}"
    echo -e "     ${YELLOW}║${NC}  ${CYAN}3.${NC} Check nodes (ping reachability)                      ${YELLOW}║${NC}"
    echo -e "     ${YELLOW}║${NC}  ${CYAN}4.${NC} Configure node plan (turn nodes on/off)              ${YELLOW}║${NC}"
    echo -e "     ${YELLOW}║${NC}  ${CYAN}5.${NC} About Cosmos Core                                    ${YELLOW}║${NC}"
    echo -e "     ${YELLOW}║${NC}  ${CYAN}6.${NC} Exit                                                 ${YELLOW}║${NC}"
    echo -e "     ${YELLOW}╚══════════════════════════════════════════════════════════╝${NC}"
    echo -e "\n${PURPLE}Choice: ${NC}"
}

while true; do
    show_menu
    read -r choice
    case $choice in
        1) check_requirements && initialize_environment ;;
        2) check_requirements && setup_nodes ;;
        3) check_requirements && check_nodes ;;
        4) check_requirements && configure_node_plan ;;
        5) show_about ; continue ;;
        6) echo -e "\n${GREEN}Bye.${NC}"; exit 0 ;;
        *) echo -e "${RED}Invalid option.${NC}" ;;
    esac
    echo -e "\n${PURPLE}Press Enter for menu...${NC}"
    read
done
