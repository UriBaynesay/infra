# Infra: Personal VPS Hosting

Server-level state for the project — the host, its config, and (eventually)
reverse proxy, container orchestration wiring, and scheduled-task
definitions. See the root [`CLAUDE.md`](../CLAUDE.md) for the project-wide
purpose, repo-structure rationale, and Claude's role (tutor / co-designer /
builder) — all of which apply here unchanged.

This is its own git repo, independent of `apps/`. A change spanning infra +
an app is two commits in two repos, by design.

## Current state

- **Host:** one Hetzner Cloud VPS, provisioned 2026-09-10.
  - Type `CX23` (Cost-Optimized, shared x86, 2 vCPU / 4 GB / 40 GB),
    location Falkenstein (`fsn1`), Ubuntu 24.04 LTS.
  - Public IPv4 `178.105.102.146`, plus a routed IPv6 block.
  - Hostname `vpa-1`.
  - Reachable as `ssh vpa` (local `~/.ssh/config` alias → user `uri`, key
    `~/.ssh/hetzner_vpa`).
  - **Fully provisioned + hardened per [`docs/vps-provisioning.md`](docs/vps-provisioning.md)** —
    that runbook is the reproducible record of every step, with command
    explanations. Nothing on the box was done outside it.
- **Nothing deployed yet.** Docker is the next step (the actual reason the
  box exists). `apps/diet-helper` is the first thing that will run on it.

## What is NOT set up yet (deliberately, per build-gradually)

- **Docker / Compose** — next step.
- **Reverse proxy (nginx)** — after there's a containerized app to route to.
- **Hetzner Cloud Firewall** (the network-level one, distinct from the
  host's `ufw`) — after Docker + the app define which ports (80/443) need
  opening, so rules aren't guessed.
- **`fail2ban`** — lower priority now that SSH password auth is off; still
  standard, do as its own step.
- **App-level Postgres backup** — no Hetzner whole-disk backup was taken
  (declined at create time), so this is a real near-term gap once diet-helper
  holds data worth keeping.
- **`deploy.sh`** — the git-pull-and-reconcile deploy script (see root
  CLAUDE.md's Environment section for the shape already decided). Build it
  when there's a real deploy to make.
- **cloud-init** — provisioning was done by hand on purpose (learning value);
  revisit automating it once the manual steps are understood.
- **Monitoring / centralized logs / config management (Ansible etc.)** —
  real industry practice at scale or on a team, overkill for one study box.
  Note and revisit if a real need appears.

## Conventions

- **Never edit the live server as a substitute for committing here.** If a
  live fix is genuinely needed, reflect it back into this repo (the runbook
  or a real config file) so the repo and the box don't drift — same rule as
  the root CLAUDE.md's guardrails.
- **Confirm before destructive / infra-affecting commands on the box**
  (`sudo`, service restarts, firewall changes, `reboot`) — a bad change
  here is real downtime once something is deployed.
- The runbook in `docs/` is written to be re-runnable on a fresh VPS from
  scratch — keep it that way when steps change.
