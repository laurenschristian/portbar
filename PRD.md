# PortBar PRD

Status: v1.0.0 built, 2026-10-06
Owner: Laurens
License: MIT, public repo `laurenschristian/portbar`

## Summary

A menu bar app and CLI that answer "what is still running on this port?" for a Mac that runs many local dev servers (Vite, Astro, Django, docs sites, Docker). It names the stack and project for each port and stops it in one click.

## Requirements

1. List listening TCP ports with stack, project, PID, uptime and bind address.
2. Hide system and app-bundle listeners by default; a toggle shows them.
3. Map Docker Desktop ports to containers; stopping one runs `docker stop`.
4. Kill = SIGTERM, then SIGKILL after 3 s. Never PID 1, this process, or another user's process.
5. Menu bar count of dev ports. CLI with list, detail, kill, kill all, JSON.
6. AppKit only, no dependencies, universal binary, about 0% idle CPU.

## Design

- `PortCore`: libproc socket scan (`PROC_PIDLISTFDS` + `PROC_PIDFDSOCKETINFO`), process info (`KERN_PROCARGS2`, `PROC_PIDVNODEPATHINFO`), detection, Docker parsing, kill. Unit tested with SwiftPM.
- `PortBar`: one binary. Run as `portbar` or with arguments it is the CLI; otherwise the menu bar app.
- The app rescans every 30 s for the count, and on each menu open. `docker ps` runs only when a Docker engine owns a listening port.

## Out of scope

UDP, root-owned listeners, remote hosts, notarization.
