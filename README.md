<p align="center">
  <img src="icon.png" width="128" height="128" alt="PortBar icon">
</p>

<h1 align="center">PortBar</h1>

<p align="center">
  See which dev servers hold which ports, and stop them, from the menu bar or the terminal.
</p>

## Overview

PortBar lists every listening TCP port on your Mac with the stack behind it (Laravel, Vite, Next.js, Astro, Docker, Postgres and more) and the project it runs from. It reads sockets straight from libproc, so a scan takes about 10 ms and needs no `lsof`. It is plain AppKit with no dependencies and no network access.

## Features

- Stack detection from the process arguments: Vite, Astro, Django, Rails, Postgres, Redis and more
- Project names from the git checkout, including worktrees (`my-app · fix-x`)
- Docker ports show the container and compose project, and stop with `docker stop`
- Kill sends SIGTERM, then SIGKILL after 3 seconds. A `php artisan serve` parent is stopped too, so it does not respawn
- System ports (Control Center, Tailscale, app helpers) are hidden by default and cannot be killed from the menu
- `LAN` marks servers bound to all interfaces
- One binary is both the app and the `portbar` CLI

## Install

```sh
brew install --cask laurenschristian/tap/portbar
xattr -dr com.apple.quarantine /Applications/PortBar.app
```

From source: `./build.sh install` builds, copies to /Applications, links `portbar` into `/opt/homebrew/bin` and launches it.

## CLI

```
portbar                   list dev servers
portbar --all             include system ports
portbar 8000              details for one port
portbar kill 8000 5173    stop servers by port
portbar kill --all-dev    stop every dev server (asks first, -y skips)
portbar --json            machine-readable output
```

## Limits

PortBar sees only your own user's processes. Root daemons need `sudo lsof -iTCP -sTCP:LISTEN`.

## License

MIT
