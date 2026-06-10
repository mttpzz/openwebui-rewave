# Deploy on a local Ubuntu server — full step-by-step guide

Complete, reusable procedure to bring the stack to production on a fresh Ubuntu
host (tested on a VirtualBox VM). The repo only contains **configuration**:
`.env`, the `llm_wiki/` content and `caddy/caddy-root.crt` are gitignored and
handled separately. The Caddy CA is **regenerated** on the host, not copied.

Phases run in order. Don't skip the "gotcha" notes — each cost real time.

---

## Phase 0 — Ubuntu prerequisites

1. Install Docker Engine + compose plugin, add your user to the `docker` group:
   ```bash
   sudo apt-get update
   sudo apt-get install -y docker.io docker-compose-plugin
   sudo usermod -aG docker $USER     # then log out / back in
   docker compose version            # verify
   ```
2. Open the firewall (if ufw is enabled):
   ```bash
   sudo ufw allow 80/tcp
   sudo ufw allow 443/tcp
   ```
3. **Disable IPv6 (critical on VirtualBox NAT).** Without this, the container's
   outbound connections wait ~25s for a dead IPv6 route before falling back to
   IPv4 — Open WebUI hangs at `Fetching 30 files: 0%` (the HF embedding model
   download) on first boot. Make it persistent:
   ```bash
   sudo tee /etc/sysctl.d/99-disable-ipv6.conf >/dev/null <<'EOF'
   net.ipv6.conf.all.disable_ipv6 = 1
   net.ipv6.conf.default.disable_ipv6 = 1
   net.ipv6.conf.lo.disable_ipv6 = 1
   EOF
   sudo sysctl --system
   cat /proc/sys/net/ipv6/conf/all/disable_ipv6   # must print 1
   ```
   > If a container still pays the IPv6 penalty (host sysctl doesn't enter the
   > container netns), add `sysctls: ["net.ipv6.conf.all.disable_ipv6=1"]` to
   > that service in `docker-compose.yml`. In our test the host fix sufficed.

## Phase 1 — Get the project

4. The repo is **private** → clone over SSH (HTTPS would prompt for a PAT). Use
   an existing SSH key already registered on GitHub, or create one
   (`ssh-keygen -t ed25519` → add the `.pub` to GitHub → SSH keys):
   ```bash
   git clone git@github.com:mttpzz/openwebui-rewave.git
   cd openwebui-rewave
   ```
5. **Copy in the gitignored files** (manual: USB / share / scp). A fresh clone
   has an empty `llm_wiki/` (only `README.md`):
   - `.env` → repo root
   - `llm_wiki/` content: `raw/`, `wiki/`, `CLAUDE.md`, `index.md`, `log.md`
     (and optionally `_bundle.md`) → into `llm_wiki/`
   - Do **NOT** copy `caddy/caddy-root.crt` (regenerated in Phase 4).

   Example with scp (from the source machine, `<server>` = Ubuntu host):
   ```powershell
   scp .env admin@<server>:~/openwebui-rewave/.env
   scp -r llm_wiki/raw llm_wiki/wiki llm_wiki/CLAUDE.md llm_wiki/index.md `
       llm_wiki/log.md admin@<server>:~/openwebui-rewave/llm_wiki/
   ```

## Phase 2 — Hostname resolution

`*.rewave.local` must resolve to the server on every machine that runs a browser.

6. On the Ubuntu host:
   ```bash
   echo "127.0.0.1 oi.rewave.local litellm.rewave.local keycloak.rewave.local n8n.rewave.local" | sudo tee -a /etc/hosts
   ```
7. Get the server LAN IP (`hostname -I`) and add to each **client** machine's
   hosts file (Windows: `C:\Windows\System32\drivers\etc\hosts`, as Admin):
   ```
   <server-ip> oi.rewave.local litellm.rewave.local keycloak.rewave.local n8n.rewave.local
   ```
   Verify from the client: `ping oi.rewave.local` → `<server-ip>`.

## Phase 3 — Ubuntu-specific config edits

8. `caddy/Caddyfile` — remove the global block (enables HTTP→HTTPS redirect;
   it was disabled on Windows where port 80 is busy):
   ```diff
   -{
   -    auto_https disable_redirects ...
   -}
   -
    oi.rewave.local {
   ```
9. `docker-compose.yml` — caddy service, uncomment port 80:
   ```diff
        ports:
   -      # - "80:80"  # comment on windows ...
   +      - "80:80"
          - "443:443"
   ```

## Phase 4 — Bootstrap the Caddy internal CA (order matters)

`openwebui` and `n8n` bind-mount `./caddy/caddy-root.crt`. If it's missing at
first `up`, Docker creates a **directory** there and breaks them. Generate the
CA first, with caddy alone:

10. ```bash
    rm -rf caddy/caddy-root.crt
    docker compose up -d --no-deps caddy        # generates internal CA
    sleep 5
    docker cp caddy-oi:/data/caddy/pki/authorities/local/root.crt ./caddy/caddy-root.crt
    ls -l caddy/caddy-root.crt                   # must be a FILE (~600 B)
    ```
    > If absent, wait a few seconds and repeat the `docker cp`.

## Phase 5 — Bring up the whole stack

11. ```bash
    docker compose up -d
    docker compose ps
    ```
12. Wait for `openwebui` to become `healthy` (first boot downloads the HF
    embedding model — fast once IPv6 is off). Verify:
    ```bash
    docker exec openwebui curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8080/health   # 200
    ```
    > Even with `BYPASS_WEB_SEARCH_EMBEDDING_AND_RETRIEVAL=true` (full-context
    > wiki, no RAG), Open WebUI still downloads the embedding model once at boot.

## Phase 6 — Trust the Caddy CA on the client

The Ubuntu Caddy CA is **new** (its private key lives in the host's `caddy-data`
volume — not transferable from Windows). Install it on the client so
`*.rewave.local` is trusted and the OAuth redirects don't hit cert warnings.

13. ```powershell
    scp admin@<server>:~/openwebui-rewave/caddy/caddy-root.crt .\ubuntu-caddy-root.crt
    # PowerShell as Admin:
    Import-Certificate -FilePath .\ubuntu-caddy-root.crt -CertStoreLocation Cert:\LocalMachine\Root
    ```
    Restart the browser. (Quick alternative without installing: click through the
    `ERR_CERT_AUTHORITY_INVALID` warning, but SSO redirects make this painful.)

## Phase 7 — Keycloak realm (fresh DB = empty)

With `ENABLE_LOGIN_FORM=false` + signup off, nobody can log in until SSO is set.

14. **Export** the realm from the source instance (Windows):
    ```powershell
    docker exec keycloak /opt/keycloak/bin/kc.sh export --realm openwebui-rewave --dir /tmp/realm-export
    docker cp keycloak:/tmp/realm-export .\realm-export
    ```
    > With `--file` you must add `--users same_file`; `--users skip` only works
    > with `--dir`.
15. **Import** on Ubuntu via the admin console (reads the file from the browser,
    one realm file only): open `https://keycloak.rewave.local` → login with
    `KEYCLOAK_ADMIN` / `KEYCLOAK_ADMIN_PASSWORD` (from `.env`) → realm dropdown →
    **Create realm** → browse `openwebui-rewave-realm.json` → Create.
    > To preserve existing users too, use `--import-realm` with the dir mounted
    > into `/opt/keycloak/data/import/` instead.
16. **Fix the client secret** (export masks it as `**********`): Clients →
    `openwebui` → **Credentials** → set the secret = `OAUTH_CLIENT_SECRET` in
    `.env`. Under **Settings**, verify Valid redirect URIs includes
    `https://oi.rewave.local/oauth/oidc/callback` and Web origins
    `https://oi.rewave.local`.
17. **Create a login user** (realm was imported without users): Users → Add user
    (real email) → **Credentials** → Set password, **Temporary: ON** (or add
    Required user action **Update Password** to force a first-login change) →
    **Role mapping** → assign realm role `admin`.

## Phase 8 — First login

18. From the client open `https://oi.rewave.local` → click **Keycloak SSO** →
    log in with the user from step 17. The `admin` role maps to an Open WebUI
    admin (`realm_access.roles`). Errors → `docker compose logs --tail 40 openwebui`.

## Phase 9 — Create the `rewave-ai` model

19. Admin Panel → Settings → Models → **+**:
    - **Name**: `ReWave AI`, **Model ID**: `rewave-ai`, **Base Model**: `claude-sonnet`.
    - **Description**: `Assistente aziendale ReWave (no RAG, wiki full-context)`.
20. **System Prompt** — the 3-source instructions + the wiki markers (the bundle
    is injected between the markers in Phase 12):
    ```
    Sei assistente Rewave Srl (cartotecnica, italiano).
    [... 3-source rules: WIKI / WEB SEARCH RESULTS / GENERAL KNOWLEDGE ...]

    =====BEGIN WIKI=====
    =====END WIKI=====
    ```
21. **Advanced Params**: `temperature = 0.2`, `max_tokens = 4096`.
22. **Capabilities** — ON: `file_context`, `vision`, `file_upload`, `web_search`,
    `citations`, `status_updates`. OFF: `image_generation`, `code_interpreter`,
    `terminal`, `usage`, `builtin_tools`.
23. **Default Features**: only `web_search` ON. **Builtin Tools**: all OFF.
24. Test: new chat → `rewave-ai` → "ciao". Errors → `docker compose logs --tail 30 litellm` (check `ANTHROPIC_API_KEY`).

## Phase 10 — Tools (n8n clients: `send_email`, `mail_digest`)

25. Enable the API Key feature (needed in Phase 12): Admin Panel → Settings →
    General → **Enable API Key** ON → Save (or `ENABLE_API_KEY: "true"` in compose).
26. **Export** from the source: Workspace → Tools → each tool → Export `.json`.
27. **Import** on Ubuntu: Workspace → Tools → Import → select the `.json` files.
28. **Set Valves** (not exported) on each tool: `N8N_AUTH_SECRET` = the shared
    secret of the n8n webhooks. (`N8N_WEBHOOK_URL` defaults are already correct;
    `send_email` VERIFY_TLS=false, `mail_digest`=true.)
29. Attach them to the model: `rewave-ai` → edit → **Tools** tab → check
    `send_email` + `mail_digest` → Save.

## Phase 11 — Migrate n8n (workflows + credentials)

Workflow JSON does **not** contain credentials. Credentials are portable only if
the Ubuntu n8n uses the **same `N8N_ENCRYPTION_KEY`** (same `.env`).

30. **Export** from the source (Windows):
    ```powershell
    docker exec n8n n8n export:workflow --all --output=/tmp/workflows.json
    docker exec n8n n8n export:credentials --all --output=/tmp/credentials.json
    docker cp n8n:/tmp/workflows.json .\n8n-workflows.json
    docker cp n8n:/tmp/credentials.json .\n8n-credentials.json
    ```
31. **Copy** to the server: `scp .\n8n-workflows.json .\n8n-credentials.json admin@<server>:~/openwebui-rewave/`
32. **Import** on Ubuntu (use absolute paths + explicit dest filename — a failed
    `docker cp` is what causes `ENOENT /tmp/...json`):
    ```bash
    docker cp ~/openwebui-rewave/n8n-credentials.json n8n:/tmp/credentials.json
    docker cp ~/openwebui-rewave/n8n-workflows.json   n8n:/tmp/workflows.json
    docker exec n8n ls -l /tmp/credentials.json /tmp/workflows.json   # confirm
    docker exec n8n n8n import:credentials --input=/tmp/credentials.json
    docker exec n8n n8n import:workflow   --input=/tmp/workflows.json
    docker compose restart n8n
    ```
33. In `https://n8n.rewave.local`: verify workflows + credentials, toggle each
    webhook workflow **Active** ON.
34. **Cleanup** (credentials file holds encrypted secrets):
    ```bash
    rm ~/openwebui-rewave/n8n-credentials.json
    docker exec n8n rm /tmp/credentials.json /tmp/workflows.json
    ```

## Phase 12 — Push the wiki bundle into the model

35. Create an API key on the **server** Open WebUI: Settings (user avatar) →
    Account → API Keys → **+** → copy `sk-...`. (This key is per-instance — the
    one in `.env` belongs to the source instance.)
36. From the maintenance machine (Windows, where `llm_wiki/` + `pwsh` live),
    push to the server. `refresh_wiki.ps1` auto-loads `.env` (which points at the
    source) so **override via parameters** — params take precedence:
    ```powershell
    pwsh -File .\scripts\refresh_wiki.ps1 -BaseUrl "https://oi.rewave.local" -ApiKey "sk-<server-key>" -ModelId "rewave-ai"
    ```
    It regenerates the bundle, GETs the model, replaces the text between
    `=====BEGIN WIKI=====` / `=====END WIKI=====`, and PATCHes it back. (TLS works
    because the client trusts the Caddy CA from Phase 6.)
37. Test in chat: ask something covered by the vault — the answer must cite real
    `[[slug]]` pages from `index.md` and respect the 3-source rules.

## Phase 13 — (optional) Mirror `llm_wiki/` files onto the server

The chat works without this (the bundle lives in the model's system prompt). Copy
the files only to keep the server self-consistent or to maintain the vault there.

38. ```powershell
    scp -r llm_wiki/raw llm_wiki/wiki llm_wiki/CLAUDE.md llm_wiki/index.md `
        llm_wiki/log.md llm_wiki/_bundle.md admin@<server>:~/openwebui-rewave/llm_wiki/
    ```
    To maintain the vault from the server: install pwsh
    (`sudo snap install powershell --classic`), put the server API key in the
    server `.env` as `OPENWEBUI_API_KEY`, then run `refresh_wiki.ps1` there.

---

## Operations cheatsheet

```bash
docker compose up -d                 # start / re-create changed containers
docker compose ps                    # status
docker compose logs -f <service>     # tail
docker compose restart litellm       # after editing litellm-config.yaml
docker compose restart caddy         # after editing caddy/Caddyfile
docker compose down                  # stop (named volumes persist)
```

- After editing `.env` → `docker compose up -d` (re-creates affected services).
- Wiki updates: re-run the Phase 12 `refresh_wiki.ps1` command.
- If the bundle outgrows Sonnet's context, switch the `claude-sonnet` mapping in
  `litellm-config.yaml` to an Opus 1M-context model, then `restart litellm`.
```
