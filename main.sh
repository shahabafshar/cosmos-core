#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

if [ ! -f "cosmos.sh" ]; then
    echo -e "${RED}cosmos.sh not found${NC}"
    exit 1
fi

[ -x "cosmos.sh" ] || chmod +x cosmos.sh
echo -e "${GREEN}Starting Cosmos Core...${NC}"
./cosmos.sh
