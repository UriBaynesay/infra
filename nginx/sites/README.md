# nginx site configs

One `.conf` file per app, each defining that app's reverse-proxy route
(hostname → the app's `localhost:<port>` container). nginx itself runs
**natively on the host** (`apt install nginx`), not containerized — see
`../../CLAUDE.md` for why.

Not populated yet — no app is routed through a real domain/HTTPS at this
point. When the first app is ready for that (a real deploy, not just
reachable at `<server-ip>:<port>`), the app's compose file changes its
publish to `127.0.0.1:<port>:<port>` (host-only, no longer open to the
internet directly), and a `<app-name>.conf` goes here.
