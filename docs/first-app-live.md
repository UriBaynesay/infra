# From a hardened box to a live HTTPS app

Continues [`vps-provisioning.md`](vps-provisioning.md). Everything here runs on
`vpa-1` as `uri` unless it says "local". Written as the reproducible record of
getting `apps/diet-helper` live at `https://diet.v1vpa.duckdns.org`; repeat the
app-specific parts (sections 3-4, 6-7) for each new app.

## 1. Docker from Docker's own apt repo

Ubuntu's `docker.io` package lags; Docker's repo is the current path. The GPG
key lets apt verify every package really comes from Docker.

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker uri      # takes effect at next login
sudo reboot                      # also loads the pending kernel; reconnect after
docker run hello-world           # verify, no sudo
```

## 2. Docker bypasses ufw: bind published ports to loopback

Docker writes its own iptables rules for published ports, which `ufw` neither
sees nor controls: a port can show as blocked in `ufw status` and still be open.
Rule for every app: never publish to `0.0.0.0`. In compose, write
`"127.0.0.1:3000:3000"`, not `"3000:3000"`. Postgres is loopback-only too.
nginx (a host process, so `ufw` does apply) is the only public listener.

## 3. Deploy keys (one per private repo, read-only)

```bash
ssh-keygen -t ed25519 -f ~/.ssh/<name>_deploy_key -N "" -C "vpa-1 deploy key: <name>"
cat ~/.ssh/<name>_deploy_key.pub
```

Add the public key at GitHub repo -> Settings -> Deploy keys, **write access
unchecked**. Then an SSH alias so the right key is used for that repo:

```bash
cat >> ~/.ssh/config <<'EOF'

Host github.com-<name>
    HostName github.com
    User git
    IdentityFile ~/.ssh/<name>_deploy_key
    IdentitiesOnly yes
EOF
ssh -T git@github.com-<name>     # first time: confirm GitHub's host key
```

Used for `infra` itself (cloned to `~/infra`, not `/srv`: it is operator tooling,
not a deployed app) and for each app (`apps.conf` uses the alias URL).

## 4. First deploy of an app

```bash
git clone git@github.com-infra:UriBaynesay/infra.git ~/infra
sudo chown uri:uri /srv                  # once; deploy.sh creates /srv/<app>
nano /srv/<app>/.env                     # secrets, by hand, never committed
chmod 600 /srv/<app>/.env
cd ~/infra && ./deploy.sh <app>
```

`deploy.sh` clones on first run, refuses to continue without `.env`, then runs
`docker compose -f docker-compose.yml up -d --build`. Generate secrets that end
up inside a URL (database passwords) with `openssl rand -hex 24`, **not**
`-base64`: a `/` in a password breaks connection-string parsing
(`ERR_INVALID_URL`).

## 5. Migrations run from your PC through an SSH tunnel

The production image is a pruned runtime with no `tsx`/`drizzle-kit`, so
`docker compose exec app npm run db:migrate` cannot work. Postgres is
loopback-only on the server, so tunnel to it (local PowerShell/terminal):

```bash
ssh -L 5433:127.0.0.1:5432 vpa -N         # leave running
# in apps/diet-helper, in another terminal:
DATABASE_URL=postgresql://<user>:<password>@localhost:5433/<db> npm run db:migrate
```

## 6. Hostname: DuckDNS

Free, no purchase. `duckdns.org` is on the Public Suffix List, so each name has
its own Let's Encrypt rate-limit bucket (`sslip.io` does not, and shares one
worldwide). At duckdns.org: sign in, add domain `v1vpa`, set its ip to
`178.105.102.146`. Every subdomain resolves to that IP too, so each app gets
`<app>.v1vpa.duckdns.org` with no further DNS work. Check:
`nslookup diet.v1vpa.duckdns.org`.

## 7. nginx + HTTPS

```bash
sudo apt-get install -y nginx
sudo ufw allow 'Nginx Full'                                    # 80 + 443
cd ~/infra && git pull
sudo ln -s ~/infra/nginx/sites/<app>.conf /etc/nginx/sites-enabled/<app>.conf
sudo rm /etc/nginx/sites-enabled/default                       # only the symlink
sudo nginx -t && sudo systemctl reload nginx                   # check, then graceful reload
sudo apt-get install -y certbot python3-certbot-nginx
sudo certbot certonly --nginx -d <app>.v1vpa.duckdns.org       # cert only; config stays ours
```

Commit the HTTPS version of the site config (`nginx/sites/diet-helper.conf` is the
model), pull, `nginx -t`, reload. Verify renewal with
`sudo certbot renew --dry-run` and `systemctl list-timers | grep certbot`.
Keep the 80 -> 443 redirect inside `location /`, not a server-level `return`, so
certbot's renewal challenge can still be answered.

Cutover for the app: in its `.env` set `APP_URL=https://<hostname>`, deploy the
version that binds `127.0.0.1` only and sets the session cookie `Secure`, then
`sudo ufw delete allow 3000/tcp`. Verify `http://<ip>:3000` no longer answers.

## 8. Nightly Postgres backups

```bash
sudo systemctl link ~/infra/systemd/pg-backup@.service ~/infra/systemd/pg-backup@.timer
sudo systemctl enable --now pg-backup@<app>.timer              # 03:30 UTC nightly
sudo systemctl start pg-backup@<app>.service                   # one right now
sudo ls -lh /var/backups/<app>/
```

Dumps are root-only, kept 14 days, same disk (survives mistakes, not losing the
VPS; an off-box copy is still open). **Restore drill**, into a scratch database:

```bash
DC="docker compose -f /srv/<app>/docker-compose.yml --project-directory /srv/<app>"
$DC exec -T postgres sh -c 'createdb -U "$POSTGRES_USER" restore_test'
sudo sh -c 'zcat "$(ls -t /var/backups/<app>/*.sql.gz | head -1)"' | $DC exec -T postgres sh -c 'psql -U "$POSTGRES_USER" -d restore_test -v ON_ERROR_STOP=1 -q'
$DC exec -T postgres sh -c 'psql -U "$POSTGRES_USER" -d restore_test -tAc "select count(*) from profiles"'
$DC exec -T postgres sh -c 'dropdb -U "$POSTGRES_USER" restore_test'
```

## Gotchas hit on the way

- **`sharp` missing `libvips` in production only.** Next's `output: "standalone"`
  traces JS imports statically and silently drops native `.so` files. Fixed with
  `outputFileTracingIncludes: { "/**": ["./node_modules/@img/**/*"] }` in
  `next.config.ts`. Works in dev (full `node_modules`), fails in the pruned image.
- **Behind nginx, Node sees plain HTTP**, so `request.url` says `http:` for HTTPS
  visitors. Apps must read `X-Forwarded-Proto` (diet-helper: `getRequestOrigin`).
- **nginx 1.24** (Ubuntu 24.04) needs `listen 443 ssl http2;`, not `http2 on;`.
- **nginx body limit** defaults to 1 MB; set `client_max_body_size` above the app's
  upload cap, and `proxy_read_timeout` above its slowest inline call.
