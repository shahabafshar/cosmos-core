#!/bin/bash

# Exit on error
set -e

# Source configuration
source config.sh
source lib.sh

# Get list of required nodes (only those enabled in the plan)
required_nodes=()
while IFS= read -r node_name; do
    [ -z "$node_name" ] && continue
    IFS='|' read -r hostname _ <<< "${NODES[$node_name]}"
    required_nodes+=("$hostname")
done < <(get_enabled_node_keys)
if [ ${#required_nodes[@]} -eq 0 ]; then
    echo "No nodes enabled in the plan. Use 'Configure node plan' in the menu to enable nodes."
    exit 1
fi

# Record start time
init_start_time=$(date +%s)

# Turn off all nodes in the grid
echo "Turning off all nodes..."
omf tell -a offh -t all
sleep 10

# Reset sandbox attenuation matrix
echo "Resetting sandbox attenuation matrix..."
wget -q -O- "http://internal2dmz.orbit-lab.org:5054/instr/setAll?att=0"
sleep 5

# Create comma-separated list of nodes
node_list=$(IFS=,; echo "${required_nodes[*]}")

# Load image on required nodes
echo "Loading image on required nodes..."
omf-5.4 load -i wifi-experiment.ndz -t "$node_list"
sleep 10

# Turn on required nodes
echo "Turning on required nodes..."
omf tell -a on -t "$node_list"
sleep 10

# Wait for nodes to be fully up with timeout
echo "Waiting for nodes to be fully up..."
timeout=600  # 10 minutes in seconds
start_time=$(date +%s)

while true; do
    all_up=true
    for hostname in "${required_nodes[@]}"; do
        if ! check_node "$hostname"; then
            all_up=false
            break
        fi
    done

    if $all_up; then
        echo "All nodes are up and responding"
        break
    fi

    current_time=$(date +%s)
    elapsed=$((current_time - start_time))
    if [ $elapsed -ge $timeout ]; then
        echo "Timeout waiting for nodes to come up"
        exit 1
    fi

    sleep 10
done

# Calculate and report total elapsed time
init_end_time=$(date +%s)
total_elapsed=$((init_end_time - init_start_time))
minutes=$((total_elapsed / 60))
seconds=$((total_elapsed % 60))

echo "====================init========================"
echo "Initialization completed successfully"
echo "Total initialization time: ${minutes}m ${seconds}s"
echo "Nodes initialized: ${#required_nodes[@]}"
echo "Status: All nodes operational"
echo "================================================"
