#!/bin/bash

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
NC='\033[0m'

# Cosmos Core banner
COSMOS_BANNER="
${CYAN}
   ____                  ____
  / ___|___  ___  _ __  / ___|___  _ __ ___
 | |   / __|/ _ \| '_ \| |   / _ \| '__/ _ \\
 | |___\__ \ (_) | | | | |__| (_) | | |  __/
  \____|___/\___/|_| |_|\____\___/|_|  \___|
${NC}
     ${GREEN}Cosmos Core${NC} — ORBIT testbed bootstrap
"

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

show_about() {
    clear
    echo -e "$COSMOS_BANNER"
    echo -e "     ${YELLOW}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "     ${YELLOW}║${NC}                     ${GREEN}About Cosmos Core${NC}                     ${YELLOW}║${NC}"
    echo -e "     ${YELLOW}╠══════════════════════════════════════════════════════════╣${NC}"
    echo -e "     ${YELLOW}║${NC}  Bootstrap layer for the ORBIT testbed.                      ${YELLOW}║${NC}"
    echo -e "     ${YELLOW}║${NC}  Init + basic node setup — build your experiments on top.   ${YELLOW}║${NC}"
    echo -e "     ${YELLOW}╚══════════════════════════════════════════════════════════╝${NC}"
    echo -e "\n${PURPLE}Press Enter to return to menu...${NC}"
    read
}

show_menu() {
    clear
    echo -e "$COSMOS_BANNER"
    echo -e "     ${YELLOW}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "     ${YELLOW}║${NC}  ${CYAN}1.${NC} Initialize testbed (load image, power on nodes)        ${YELLOW}║${NC}"
    echo -e "     ${YELLOW}║${NC}  ${CYAN}2.${NC} Setup nodes (cleanup + install basic packages)        ${YELLOW}║${NC}"
    echo -e "     ${YELLOW}║${NC}  ${CYAN}3.${NC} About Cosmos Core                                    ${YELLOW}║${NC}"
    echo -e "     ${YELLOW}║${NC}  ${CYAN}4.${NC} Exit                                                 ${YELLOW}║${NC}"
    echo -e "     ${YELLOW}╚══════════════════════════════════════════════════════════╝${NC}"
    echo -e "\n${PURPLE}Choice: ${NC}"
}

while true; do
    show_menu
    read -r choice
    case $choice in
        1) check_requirements && initialize_environment ;;
        2) check_requirements && setup_nodes ;;
        3) show_about ; continue ;;
        4) echo -e "\n${GREEN}Bye.${NC}"; exit 0 ;;
        *) echo -e "${RED}Invalid option.${NC}" ;;
    esac
    echo -e "\n${PURPLE}Press Enter for menu...${NC}"
    read
done
