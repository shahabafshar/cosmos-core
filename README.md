# Cosmos Core

```
              ·    ✦    .         *         .    ✦    ·    .    *
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
            ═══════════════════════════════════════════════════════
              ✦    ·    .         *         .    ·    ✦    .    *
```

**Created by:** Shahab Afshar  
**Course:** Wireless Network Security  
**Professor:** Dr. Mohamed Selim  

---

Bootstrap layer for the [ORBIT testbed](https://www.orbit-lab.org/). Cosmos Core handles **initialization** and **basic node setup** so you can run your own experiments on a ready grid.

## What it does

- **Init** — Powers off the grid, resets the attenuation matrix, loads the node image, powers on your nodes, and waits until they are reachable.
- **Setup** — On every node: cleanup (kill stale processes, reset interface), install a configurable set of basic packages (e.g. `iperf3`, `tmux`), and optionally run extra commands you define.

No test suites or role-specific daemons (AP/client/jammer) are included; you build those on top.

## Quick start

```bash
./main.sh
```

All scripts except the entry point live in `scripts/`. The menu offers:

1. **Configure node plan** — Turn nodes on/off for Init, Setup, Check.
2. **Initialize testbed** — Load image, power on selected nodes.
3. **Setup nodes** — Cleanup + install packages on selected nodes.
4. **Check nodes** — Ping selected nodes (parallel).
5. **Power off all nodes** — Shut down the grid.
6. **About** — Credits and short description.
7. **Exit**

Manual usage (from repo root):

```bash
./main.sh                              # Start menu
bash scripts/init.sh                   # Initialize ORBIT testbed (selected nodes)
bash scripts/setup.sh                  # Setup selected nodes (cleanup + packages)
```

## Configuration

Edit `scripts/config.sh`:

- **NODE_HOSTNAMES** — Space-separated list of node hostnames. Which nodes are used is set in the menu (“Configure node plan”), not in the config.
- **DEFAULT_INTERFACE** — Interface to reset during Setup (e.g. `wlan0`).
- **PLAN_FILE** — File that stores which nodes are on (default: `.cosmos_plan` at repo root). Edit via the menu, not by hand.
- **PACKAGES** — Space-separated list of packages to install on each node (default: `iperf3 tmux`).
- **SETUP_EXTRA_COMMANDS** — Optional array of commands to run on each node after package install. Uncomment to use.

## Requirements

- ORBIT testbed access
- On your machine: `ssh`, `omf`, `omf-5.4`, `wget`

## License

MIT — see [LICENSE](LICENSE).
