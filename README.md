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

A quick-start tool for the [COSMOS](https://www.cosmos-lab.org/) (and [ORBIT](https://www.orbit-lab.org/)) wireless testbed. It gets your nodes imaged, powered on, and ready so you can jump straight into your experiment.

## How it works

1. You reserve a testbed slot and SSH into the console
2. Run Cosmos Core — it detects your site and discovers available nodes
3. Pick which nodes you want, hit Init — it images them, powers them on, verifies they're reachable
4. Optionally run Setup to install packages (iperf3, tmux, etc.)
5. SSH into your nodes and run your experiment

## Getting started

On your testbed console (e.g. `ssh you@sb4.orbit-lab.org`):

```bash
git clone https://github.com/shahabafshar/cosmos-core.git
cd cosmos-core
chmod +x *.sh scripts/*.sh
./main.sh
```

The interactive menu walks you through everything:

| Option              | What it does                                                  |
| ------------------- | ------------------------------------------------------------- |
| **1. Select nodes** | Pick which nodes to use (arrow keys + space, or type numbers) |
| **2. Initialize**   | Power off → image nodes → power on → verify reachable         |
| **3. Setup**        | Kill stale processes, reset interfaces, install packages      |
| **4. Check**        | Ping all selected nodes                                      |
| **5. Power off**    | Shut down selected nodes                                     |

After Init + Setup, your nodes are ready. SSH in and do your thing:

```bash
ssh root@node1-1
```

## Supported testbeds

Cosmos Core auto-detects the site from the console hostname. Tested on:

| Testbed              | Domain                 | Notes                                    |
| -------------------- | ---------------------- | ---------------------------------------- |
| **grid**             | grid.orbit-lab.org     | 186 nodes, many with Atheros WiFi        |
| **outdoor**          | outdoor.orbit-lab.org  | Outdoor deployment                       |
| **sb4**              | sb4.orbit-lab.org      | 9-node sandbox with RF attenuator matrix |
| **sb1–sb3**          | sb1–sb3.orbit-lab.org  | Small sandboxes (2 nodes each)           |
| **COSMOS sandboxes** | *.cosmos-lab.org       | bed, weeks, sb1, sb2                     |

Node discovery, caching, and file paths are all per-site — you can switch between testbeds without conflicts.

## What it handles for you

- **Node discovery** — auto-discovers nodes via OMF (falls back to ARP, then hardcoded list)
- **Imaging** — loads `wifi-experiment.ndz` via `omf load` with progress tracking
- **Attenuation matrix** — resets the JFW RF matrix on sb4 (skipped on other testbeds)
- **Failure tracking** — nodes that fail during imaging or boot are marked `[!]` and auto-skipped; press `r` to clear and retry
- **Logging** — full session logs under `logs/` with timestamps

## Configuration

Edit `scripts/config.sh` if you need to change defaults:

| Setting             | Default        | Description                                          |
| ------------------- | -------------- | ---------------------------------------------------- |
| `PACKAGES`          | `iperf3 tmux`  | Packages installed on each node during Setup         |
| `DEFAULT_INTERFACE` | `wlan0`        | Interface reset during Setup                         |
| `IMAGING_TIMEOUT`   | `800` (seconds)| Max time for `omf load`                              |
| `STALL_DETECTION`   | `0`            | Set to `1` to enable early abort when imaging stalls |
| `SSH_USER`          | `root`         | SSH user for node operations                         |

Most settings are auto-detected. You usually don't need to change anything.

## Requirements

- A [COSMOS/ORBIT](https://www.cosmos-lab.org/) account with a testbed reservation
- Run on the testbed console (not your local machine)

## Credits

**Created by:** Shahab Afshar
**Course:** Wireless Network Security (CprE 5370)
**Professor:** Dr. Mohamed Selim
**Institution:** Iowa State University

## Disclaimer

This is an independent, community-created tool and is **not affiliated with, endorsed by, or supported by** the COSMOS/ORBIT testbed, Rutgers University, WINLAB, or the NSF. COSMOS and ORBIT are trademarks of their respective owners. Use this tool at your own risk and in accordance with the testbed's acceptable use policies.

## License

MIT — see [LICENSE](LICENSE).
