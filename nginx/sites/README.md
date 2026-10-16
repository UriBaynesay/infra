# nginx site configs

One `.conf` file per app, each defining that app's reverse-proxy route
(hostname -> the app's `127.0.0.1:<port>` container). nginx itself runs
**natively on the host** (`apt install nginx`), not containerized — see
`../../CLAUDE.md` for why.

The files here are the source of truth. On the server each one is a symlink
into `/etc/nginx/sites-enabled/`, so editing the repo and reloading is the
whole change process:

```bash
cd ~/infra && git pull
sudo ln -s ~/infra/nginx/sites/<app-name>.conf /etc/nginx/sites-enabled/<app-name>.conf   # first time only
sudo nginx -t && sudo systemctl reload nginx   # reload, not restart: no dropped connections
```

Hostnames are `<app>.v1vpa.duckdns.org` (DuckDNS resolves any subdomain of
`v1vpa.duckdns.org` to the VPS). Certificates come from Let's Encrypt via
`certbot certonly --nginx`, which only obtains the cert and leaves these files
untouched; each `.conf` references the cert paths by hand.
