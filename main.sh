#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

COSMOS_ROOT="$(cd "$(dirname "$0")" && pwd)"
if [ ! -f "$COSMOS_ROOT/scripts/cosmos.sh" ]; then
    echo -e "${RED}scripts/cosmos.sh not found${NC}"
    exit 1
fi

[ -x "$COSMOS_ROOT/scripts/cosmos.sh" ] || chmod +x "$COSMOS_ROOT/scripts/cosmos.sh"
echo -e "${GREEN}Starting Cosmos Core...${NC}"
exec bash "$COSMOS_ROOT/scripts/cosmos.sh"
