# Deploy on a local Ubuntu server (test)

Guide to bring the stack up on a fresh Ubuntu host. The repo only contains
configuration: `.env`, the `llm_wiki/` content and `caddy/caddy-root.crt` are
gitignored and must be handled separately (the CA cert is **regenerated**, not
copied).

## 0. Prerequisites (Ubuntu host)

```bash
# Docker Engine + compose plugin
sudo apt-get update
sudo apt-get install -y docker.io docker-compose-plugin
sudo usermod -aG docker $USER   # then re-login
docker compose version          # verify

# Firewall (if ufw is enabled)
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
```

## 1. Get the project

```bash
git clone https://github.com/mttpzz/openwebui-rewave.git
cd openwebui-rewave
```

Then **manually copy in the gitignored files** (USB / network share). The whole
`llm_wiki/` directory is excluded from the repo (vault recreated per deploy), so
a fresh clone has no `llm_wiki/` at all — copy the entire folder:

- `.env`  → repo root
- the entire `llm_wiki/` directory (`raw/`, `wiki/`, `CLAUDE.md`, `index.md`, `log.md`) → repo root

Example (run from the Windows repo root, `<server>` = Ubuntu host):
```powershell
scp .env admin@<server>:~/openwebui-rewave/.env
scp -r llm_wiki admin@<server>:~/openwebui-rewave/
```

Do **NOT** copy `caddy/caddy-root.crt` from Windows — that CA's private key lives
in the Windows `caddy-data` volume. Ubuntu's Caddy generates its own CA (step 4).

## 2. Hostname resolution

`*.rewave.local` must resolve to the server on whatever machine runs the browser.

On the Ubuntu host:
```bash
echo "127.0.0.1 oi.rewave.local litellm.rewave.local keycloak.rewave.local n8n.rewave.local" | sudo tee -a /etc/hosts
```

On any LAN client used for testing, add to its hosts file (`<server-ip>` = Ubuntu LAN IP):
```
<server-ip> oi.rewave.local litellm.rewave.local keycloak.rewave.local n8n.rewave.local
```

## 3. Apply Ubuntu-specific config edits

Two edits enable port 80 + HTTP→HTTPS redirect (disabled on Windows because it
often occupies port 80).

**`caddy/Caddyfile`** — remove the global block:
```diff
-{
-    auto_https disable_redirects        # active on Windows (port 80 used by other apps); remove on Ubuntu to enable HTTP→HTTPS auto-redirect
-}
-
 oi.rewave.local {
```

**`docker-compose.yml`** — caddy service, uncomment port 80:
```diff
     ports:
-      # - "80:80"  # comment on windows because port 80 is often used by other applications
+      - "80:80"
       - "443:443"
```

## 4. Bootstrap the Caddy CA (order matters)

The `openwebui` and `n8n` services bind-mount `./caddy/caddy-root.crt`. If that
file is missing at first `up`, Docker creates a **directory** in its place and
breaks the containers. So generate the CA first:

```bash
# Make sure no stale directory exists
rm -rf caddy/caddy-root.crt

# Start ONLY caddy (no dependencies) so it generates its internal CA
docker compose up -d --no-deps caddy
sleep 5

# Extract the generated root CA into ./caddy/ (container is named caddy-oi)
docker cp caddy-oi:/data/caddy/pki/authorities/local/root.crt ./caddy/caddy-root.crt
ls -l caddy/caddy-root.crt   # must be a FILE
```

> If the file did not appear, give Caddy a moment and re-run the `docker cp`.
> Path inside the container: `/data/caddy/pki/authorities/local/root.crt`.

## 5. Bring up the whole stack

```bash
docker compose up -d
docker compose ps
docker compose logs -f openwebui   # watch for clean startup
```

`openwebui` and `n8n` run `update-ca-certificates` at entrypoint and now trust
the freshly generated Caddy CA for internal HTTPS calls (e.g. OIDC to Keycloak).

## 6. Keycloak realm (re-create on the new host)

A fresh `keycloak-db` is empty. With `ENABLE_LOGIN_FORM=false` + signup off,
**nobody can log in until SSO is configured**. Recreate the realm:

### 6a. Export from the Windows machine (current working stack)

Run on Windows where Keycloak is up:
```powershell
docker exec keycloak /opt/keycloak/bin/kc.sh export `
  --realm openwebui-rewave --users skip --file /tmp/realm.json
docker cp keycloak:/tmp/realm.json .\realm-export.json
```
Copy `realm-export.json` to the Ubuntu server (manual transfer).

> Exports mask the client secret (`**********`). You will set it in step 6c.

### 6b. Import on Ubuntu

Admin console: open `https://keycloak.rewave.local` → login with
`KEYCLOAK_ADMIN` / `KEYCLOAK_ADMIN_PASSWORD` (from `.env`) → top-left realm
dropdown → **Create realm** → browse `realm-export.json` → Create.

### 6c. Fix the `openwebui` client secret

The OIDC client secret must match `.env`'s `OAUTH_CLIENT_SECRET`:

Clients → `openwebui` → **Credentials** → set/regenerate the secret so it equals
`OAUTH_CLIENT_SECRET` in `.env` (or copy the new value into `.env` and
`docker compose up -d openwebui`).

Also verify under the `openwebui` client:
- **Valid redirect URIs** includes `https://oi.rewave.local/oauth/oidc/callback`
- **Web origins** includes `https://oi.rewave.local`

Then test login at `https://oi.rewave.local`. First SSO user with the `admin`
role (from `realm_access.roles`) becomes Open WebUI admin.

## 7. Create the `rewave-ai` model + push the wiki

1. In Open WebUI: **Admin → Settings → Models → +** create a model `rewave-ai`
   based on `claude-sonnet`. In its **System Prompt** put the markers the
   refresh script looks for:
   ```
   =====BEGIN WIKI=====
   =====END WIKI=====
   ```
2. Create an API key: **Settings → Account → API Keys → +**.
3. Push the bundle. The scripts are PowerShell — easiest is to run them **from
   the Windows machine** (which already has `llm_wiki/` and `pwsh`), targeting
   the Ubuntu server over plain HTTP to skip cert trust:
   ```powershell
   $env:OPENWEBUI_URL     = "http://<server-ip>:3000"
   $env:OPENWEBUI_API_KEY = "<api-key-from-ubuntu-instance>"
   $env:OPENWEBUI_MODEL_ID = "rewave-ai"
   pwsh -File .\scripts\refresh_wiki.ps1
   ```
   Alternatively install PowerShell on Ubuntu (`sudo snap install powershell
   --classic`) and run it there (requires the `llm_wiki/` content present).

## 8. Notes

- **n8n**: a fresh `n8n-data` volume is empty — the chat→mail workflow is not
  transferred. Re-create or import workflows in the n8n UI if needed for the test.
- **Ollama**: the `llama3.1` mapping in `litellm-config.yaml` is commented out;
  if enabled, `host.docker.internal:11434` now points to the Ubuntu host, so
  Ollama must run there.
- **OPENWEBUI_URL in `.env`**: only used by `refresh_wiki.ps1`. For an on-server
  run set it to `http://localhost:3000`.
- Restart cheatsheet: edit `litellm-config.yaml` → `docker compose restart
  litellm`; edit `caddy/Caddyfile` → `docker compose restart caddy`.
```
