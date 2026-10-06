<p align="center">
  <img src="icon.png" width="128" height="128" alt="PortBar icon">
</p>

<h1 align="center">PortBar</h1>

<p align="center">
  See which dev servers hold which ports on your Mac, and stop them, from the menu bar, the terminal or your coding agent.
</p>

<p align="center">
  <a href="https://github.com/laurenschristian/portbar/releases/latest"><img src="https://img.shields.io/github/v/release/laurenschristian/portbar" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/macOS-13%2B-blue" alt="macOS 13+">
  <img src="https://img.shields.io/badge/arch-Apple%20Silicon%20%7C%20Intel-lightgrey" alt="Universal binary">
  <a href="LICENSE"><img src="https://img.shields.io/github/license/laurenschristian/portbar" alt="MIT License"></a>
</p>

## Overview

If you run several dev servers and Docker side by side, ports pile up. You lose track of which server from last week still holds port 8000, or which worktree a Vite server belongs to.

PortBar lists every listening TCP port with the stack behind it, the project it runs from, who started it, and how much memory it uses. It stops, restarts and cleans up servers for you. It reads sockets straight from the kernel through libproc, so a full scan takes about 25 ms and needs no `lsof`.

It is plain AppKit with no dependencies, no analytics and no network access.

## Features

**See what runs**
- Stack detection from the process arguments: Vite, Astro, Nuxt, Django, Rails, Flask, Bun and 30 more, each with its brand icon
- Project names from the git checkout, including worktrees (`my-app · fix-login`)
- Who started each server: Claude Code, Codex, Ghostty, iTerm, VS Code, Cursor
- Memory per server, counted over the whole process tree (Vite's esbuild, php -S workers)
- Docker ports map to the container and compose project, with memory and CPU from `docker stats`
- `LAN` marks servers that listen on all interfaces

**Keep it clean**
- Idle auto-stop: a dev server with no connections and no CPU use for 8 hours (or 24 h, 3 days, off) is stopped, with a notification
- Orphans: when you delete a folder or remove a git worktree, its servers stop within a second
- Memory alerts when one dev server passes 2, 3, 4 or 8 GB
- Postgres, Redis, MySQL, PHP-FPM and Docker containers are pinned in a Services section and never auto-stopped
- System listeners (Control Center, AirPlay, app helpers) are hidden and protected

**Act on it**
- Kill sends SIGTERM, then SIGKILL after 3 seconds. A `php artisan serve` parent is stopped too, so it does not respawn
- Restart reruns the same command in the same folder and environment, logging to `~/Library/Logs/PortBar/<port>.log`
- Open the URL, reveal the folder, copy the command, open the project's Laravel log
- ⌃⌥P opens the menu from anywhere

**For coding agents**
- `portbar next-free 8000 --claim my-task` hands out a free port and reserves it for 10 minutes, so parallel agents never pick the same one
- A built-in MCP server (`portbar mcp`) gives agents `list_ports`, `who`, `claim_port`, `stop_port` and `restart_port`. It refuses to stop services and system processes

## Performance

Measured on macOS 26, Apple Silicon:

| Metric | PortBar 1.1.1 |
| --- | --- |
| Memory footprint | 26 MB |
| Idle CPU | 0.0% |
| Full port scan | about 25 ms |
| App bundle | 1.2 MB (universal) |

PortBar rescans every 30 seconds in the background and when you open the menu. `docker ps` runs only when a Docker engine owns a listening port.

## Requirements

- macOS 13 Ventura or later

## Installation

### Homebrew (recommended)

```sh
brew install --cask laurenschristian/tap/portbar
xattr -dr com.apple.quarantine /Applications/PortBar.app
```

The cask installs the app and links the `portbar` command.

### Manual download

1. Download the latest `PortBar-vX.Y.Z.dmg` from [Releases](https://github.com/laurenschristian/portbar/releases/latest).
2. Open the disk image and drag PortBar to Applications.
3. Run `xattr -dr com.apple.quarantine /Applications/PortBar.app`.
4. Optional: `ln -s /Applications/PortBar.app/Contents/MacOS/PortBar /opt/homebrew/bin/portbar` for the CLI.

> [!NOTE]
> PortBar is not notarized by Apple yet, so Gatekeeper blocks the first launch. The `xattr` command removes the download quarantine flag.

## Usage

### Menu bar

The icon shows how many dev servers run. Click it, or press ⌃⌥P.

| Section | Contents |
| --- | --- |
| Dev servers | Port, stack, project, memory, uptime or idle time, `agent` and `LAN` tags |
| Services | Postgres, Redis, Docker containers and other always-on services |
| Row submenu | Open, Copy URL, Reveal Folder, Laravel log, details, Restart, Kill |
| Footer | Stop All Dev Servers, Stop Idle Servers, Auto-Stop and Memory Alert thresholds, Show System Ports, Launch at Login |

### Command line

```
$ portbar
PORT  STACK         PROJECT                         OWNER        PID    UP   IDLE  MEM     BIND
3210  Next.js       docs-site · main                Claude Code  23218  9m   now   3.9 GB  *
5173  Vite          my-app · dev                    Ghostty      5370   2h   now   412 MB  local
8000  Laravel       my-app · dev                    Ghostty      5402   2h   40m   96 MB   local
5432  Postgres                                                   1295   34d  keep  964 MB  local
5433  Docker        api · db-1                                   89594  5d   keep  512 MB  *
```

| Command | Result |
| --- | --- |
| `portbar` | Dev servers and services |
| `portbar --all` | Include system ports |
| `portbar --sort mem` | Biggest memory first |
| `portbar 8000` | Details for one port: command, folder, owner, log path |
| `portbar who 8000` | One line: what holds the port |
| `portbar free 8000` | Stop whatever holds it; succeeds if the port is already free |
| `portbar restart 8000` | Stop and rerun the same command |
| `portbar kill 8000 5173` | Stop servers by port (`--force` for system processes) |
| `portbar kill --all-dev` | Stop every dev server (asks first; `-y` skips) |
| `portbar kill --idle` | Stop orphans and servers idle past the threshold |
| `portbar next-free 8000 --claim name` | Print a free port and reserve it |
| `portbar --json` | Machine-readable output for scripts |

### Coding agents (MCP)

Register the server once:

```sh
claude mcp add portbar -s user -- /opt/homebrew/bin/portbar mcp
```

Any MCP client works the same way: the command is `portbar mcp` over stdio. Agents then claim a port before they start a server, and can see and clean up what they started.

## How it works

- Sockets come from `proc_pidinfo(PROC_PIDLISTFDS)` and `proc_pidfdinfo(PROC_PIDFDSOCKETINFO)`; arguments, environment and folder from `KERN_PROCARGS2` and `PROC_PIDVNODEPATHINFO`.
- A server counts as active when it holds an open connection or its CPU time grew since the last scan.
- PortBar sees only your own user's processes. Root daemons need `sudo lsof -iTCP -sTCP:LISTEN`.

## Building from source

```sh
./build.sh            # build build/PortBar.app (universal)
./build.sh install    # build, copy to /Applications, link the CLI, launch
./build.sh test       # unit tests
```

## Credits

Brand icons from [Simple Icons](https://simpleicons.org) (CC0). Trademarks belong to their owners.

## License

MIT
