# Cosmos Core

Bootstrap layer for the [ORBIT testbed](https://www.orbit-lab.org/). Cosmos Core handles **initialization** and **basic node setup** so you can run your own experiments on a ready grid.

## What it does

- **Init** — Powers off the grid, resets the attenuation matrix, loads the node image, powers on your nodes, and waits until they are reachable.
- **Setup** — On every node: cleanup (kill stale processes, reset interface), install a configurable set of basic packages (e.g. `iperf3`, `tmux`), and optionally run extra commands you define.

No test suites or role-specific daemons (AP/client/jammer) are included; you build those on top.

## Quick start

```bash
./main.sh
```

Menu options:

1. **Initialize testbed** — Run `init.sh` (load image, power on nodes).
2. **Setup nodes** — Run `setup.sh` (cleanup + install packages on all nodes).
3. **About** — Short description.
4. **Exit**

Manual usage:

```bash
./init.sh    # Initialize ORBIT testbed
./setup.sh   # Setup all nodes (cleanup + packages)
```

## Configuration

Edit `config.sh`:

- **NODES** — List of nodes (`hostname|ip|role|interface|network`). Same format as ORBITRON; roles are for your reference only (Cosmos Core does not configure AP/client/jammer).
- **NETWORKS** — Optional; kept for compatibility or future use.
- **PACKAGES** — Space-separated list of packages to install on every node (default: `iperf3 tmux`).
- **SETUP_EXTRA_COMMANDS** — Optional array of shell commands to run on each node after package install. Uncomment and add as needed.

## Requirements

- ORBIT testbed access
- On your machine: `ssh`, `omf`, `omf-5.4`, `wget`

## License

MIT — see [LICENSE](LICENSE).
