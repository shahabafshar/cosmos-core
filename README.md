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

1. **Select nodes** — Choose which nodes to work with. Arrows + space, or type numbers + Enter.
2. **Initialize selected nodes** — Load image, power on selected nodes.
3. **Setup selected nodes** — Cleanup + install packages on selected nodes.
4. **Check selected nodes** — Ping selected nodes (parallel).
5. **Power off selected nodes** — Shut down selected nodes.
6. **About** — Credits and short description.
7. **Exit**

Manual usage (from repo root):

```bash
./main.sh                              # Start menu
bash scripts/init.sh                   # Initialize ORBIT testbed (selected nodes)
bash scripts/setup.sh                  # Setup selected nodes (cleanup + packages)
```

## Node discovery

On startup, Cosmos automatically detects the ORBIT site (outdoor, sb1, etc.) and discovers nodes:

1. **OMF query** (primary) — Uses `omf stat -t all` to list available nodes.
2. **ARP table** (fallback) — Parses `arp -a` if OMF fails (shows warning: may be incomplete).
3. **Hardcoded** (fallback) — Uses the node list in `config.sh` if both methods fail.

Discovered nodes are cached in `.cosmos_nodes`. Press `r` inside **Select nodes** to re-discover and update the cache.

## Failure handling

Cosmos tracks nodes that fail during operations:

- **Pre-check** — Before initializing, unreachable nodes are detected via ping and can be skipped.
- **During operations** — Nodes that fail during imaging, setup, or boot are automatically marked as failed.
- **Visual indicator** — Failed nodes show as `[!]` in red in the node selection screen and cannot be selected.
- **Auto-skip** — Subsequent operations automatically skip failed nodes.
- **Clear failures** — Press `r` (refresh) in the node selection screen to clear the failed list and retry.

Failed nodes are tracked in `.cosmos_failed` (auto-generated, gitignored).

## Logging

A single session log is created when Cosmos starts, capturing all operations:

```
logs/session_safshar_2026-02-03_16-30-45.log
```

The log includes:
- Session header (user, date, host, site)
- All operations with timestamps (INITIALIZE, SETUP, CHECK)
- Full output with ANSI colors stripped

## Parallel execution

Setup runs in parallel for faster operation:
1. **Reachability check** — All nodes pinged simultaneously
2. **Package installation** — All reachable nodes setup at once

This significantly reduces setup time when working with many nodes.

## Configuration

Edit `scripts/config.sh`:

- **NODE_DOMAIN** — Auto-detected or set manually (e.g. `outdoor.orbit-lab.org`).
- **NODE_NAMES** — Auto-discovered or hardcoded fallback list of short node names.
- **DEFAULT_INTERFACE** — Interface to reset during Setup (e.g. `wlan0`).
- **PLAN_FILE** — File that stores which nodes are on (default: `.cosmos_plan` at repo root). Edit via the menu.
- **PACKAGES** — Space-separated list of packages to install on each node (default: `iperf3 tmux`).
- **SETUP_EXTRA_COMMANDS** — Optional array of commands to run on each node after package install.

## Requirements

- ORBIT testbed access
- On your machine: `ssh`, `omf`, `omf-5.4`, `wget`

## License

MIT — see [LICENSE](LICENSE).
