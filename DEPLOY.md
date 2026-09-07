# Deploy on a local Ubuntu server — full step-by-step guide

Complete, reusable procedure to bring the stack to production on a fresh Ubuntu
host (tested on a VirtualBox VM). The repo only contains **configuration**:
`.env`, the `llm_wiki/` content and `caddy/caddy-root.crt` are gitignored and
handled separately. The Caddy CA is **regenerated** on the host, not copied.

**Assumes**: an Ubuntu Server already installed, reachable over SSH, with a
**static LAN IP** (so the address and the Phase 2 client hosts entries stay valid
across reboots). Confirm it before starting: `ip -br a` (static IP on the
interface) and `ip route | grep default` (gateway present).

Phases run in order. Steps are numbered continuously across phases. Don't skip the
"gotcha" notes — each cost real time. **Phases 13–14 are optional** (file mirror,
local Ollama models); everything up to and including Phase 12 is the standard
path — **request routing (Phase 9 + Phase 10) is standard, not optional**.

---

## What carries over vs what you recreate

A fresh Ubuntu deploy reuses the **repo config** but starts Open WebUI with an
**empty database**. So:

**Carried over automatically** (committed to the repo):
- `docker-compose.yml` env — all default user permissions, RAG tuning, docling,
  Arena-off, single-model exposure, upload limits, web-search engine. → the
  **default permissions come out identical** to the source with no manual work.
- `litellm-config.yaml`, `caddy/Caddyfile`, `scripts/`.

**Migrated by hand** in the phases below: `.env`, `llm_wiki/`, and the Keycloak realm.

**Recreated on the fresh instance** (the Open WebUI DB is empty — not migrated):

| Item | Where |
|---|---|
| API key feature + personal API key | Phase 9 |
| RouteLLM connection + threshold | Phase 9 (manual, step 22) |
| `rewave-ai` model + system prompt | Phase 10 (manual, steps 25–31) + Phase 12 (`refresh_wiki.ps1`) |
| Model visibility (`rewave-ai` Public, targets Private) | Phase 10 (manual, step 31) |
| Task Model = `claude-haiku` (titles/tags) | Phase 10 (manual, step 30) |
| New-chat prompt suggestions ("Suggerito" cards) | Phase 12 (`seed_suggestions.ps1`) |
| Functions (`Presentazione PDF`) | Phase 12 (`seed_functions.ps1`) |
| Department **groups** + user→group assignment | see below |
| Knowledge Base contents | users re-upload; KB shells (name/description) must be re-created first — see README.md "Knowledge Bases (RAG)" |
| Chats / history | not migrated (per user) |

### Make permissions & groups identical to the source

1. **Defaults** are applied from env at first boot — verify at Admin Panel → Users →
   Groups → **Default Permissions**:
   - **Chat** — OFF: Controls, System Prompt, Params, Valves, Multiple Models,
     Share, Export. ON: File Upload, Web Upload, Web Search, Folders, STT/TTS/Call,
     Delete/Edit/Regenerate/Continue/Rate, Temporary.
   - **Features** — OFF: Image Generation, Code Interpreter, Calendar, Memories,
     API Keys, Automations. ON: Notes, Channels, Web Search, Folders.
   - **Workspace** — ON: Knowledge (+ sharing). OFF: Models, Prompts, Tools.
2. **Create the department groups** (Admin Panel → Users → Groups → **+**), e.g.
   `amministrazione`, `contabilita`, `progettazione`. A new group **inherits the
   current default permissions**, so it comes out already correct — no per-permission
   editing needed.
3. **Assign users** to their group (users appear after their first SSO login).
4. **Spot-check** with a non-admin account: no Controls panel; no image-gen /
   code-interpreter / calendar / memory / multi-model / share / export; Knowledge
   create + share available.

> If you change a default **after** a group exists, the group keeps the old value —
> re-apply it inside that group's permissions too.

---

## Exporting from an existing instance

Before deploying on a new host, export everything from the **source** instance
(the Windows dev machine or the current Ubuntu server). Do this while the source
stack is still running.

### Open WebUI — what can be exported

| Item | Export method | Gaps / what to redo manually |
|---|---|---|
| `rewave-ai` model | Admin Panel → Models → `rewave-ai` → **⋮ → Export** → JSON | Visibility (Public/Private) and RouteLLM connection are **not** in the JSON — redo: RouteLLM connection at Phase 9 step 22; Task Model at Phase 10 step 30; visibility at Phase 10 step 31 |
| Functions (`esporta_pdf`) | Admin Panel → Functions → `esporta_pdf` → **⋮ → Export** → JSON (or copy the Python source from `functions/esporta_pdf.py`) | Active + Global flags must be re-toggled after import |
| Prompt presets (`/commands`) | Workspace → Prompts → each preset → **⋮ → Export** → JSON | Re-import one by one; or re-create manually |
| Knowledge Base metadata | no export — only the KB shell (name, description) can be re-created | **Content (files) must be re-uploaded** by users or admins after the KB is re-created |
| Chats / history | not exportable as bulk admin operation (users can export their own) | not migrated |
| Global settings (suggestions, Task Model, permissions) | no export UI — use `seed_suggestions.ps1` for suggestion cards; Task Model at Phase 10 step 30; permissions seeded from env | — |

#### Import model on the new instance

1. **Admin Panel → Models → Import** → select the exported JSON.
2. The model appears with all params and system prompt intact.
3. Redo the three items not in the JSON:
   - **RouteLLM connection** (Phase 9 step 22)
   - **Task Model = `claude-haiku`** (Phase 10 step 30)
   - **Visibility** — `rewave-ai` + `router-bert-<n>` Public; others Private (Phase 10 step 31)
4. Run `refresh_wiki.ps1` to inject the wiki bundle into the empty markers (Phase 12).

#### Import function on the new instance

**Option A — import JSON:** Admin Panel → Functions → **Import** → select the
exported JSON → toggle **Active** ON → toggle **Global** ON.

**Option B — paste source:** Admin Panel → Functions → **+** → paste
`functions/esporta_pdf.py` → Save → toggle Active + Global ON.

#### Import prompt presets

Workspace → Prompts → **Import** → select each exported JSON. Set each to
**Public** so all users see it. There is no bulk import; repeat per preset.

---

### Keycloak — export and import the realm

The Keycloak realm holds all users, groups, roles, and the OIDC client config for
Open WebUI. Export it from the source so the new instance starts with the same
identity setup.

#### Export (source machine, while stack is running)

**Option A — Admin Console (partial, no users):**
Keycloak Admin Console (`https://keycloak.rewave.local`) → select realm
`openwebui-rewave` → **Realm Settings → Action (top-right) → Partial export**:
- ✅ Include groups
- ✅ Include roles
- ✅ Include clients
- ✅ Include default roles
- Export → saves `realm-export.json`

> Users are **not** included in a partial export. They are re-created automatically
> at first SSO login via Keycloak (users log in through their IdP — no manual
> re-creation needed for SSO users). If you have local Keycloak accounts (non-SSO),
> re-create them manually after import.

**Option B — CLI (full, includes users):**
```bash
docker exec keycloak /opt/keycloak/bin/kc.sh export \
  --realm openwebui-rewave \
  --users realm_file \
  --dir /tmp/kc-export
docker cp keycloak:/tmp/kc-export/openwebui-rewave-realm.json ./keycloak-realm.json
```
> CLI export includes users and credentials. Handle the file as a secret (contains
> hashed passwords). Delete it after import.

#### Import (new instance)

The new Keycloak starts with an empty DB. Import the realm before any user tries
to log in.

**Via Admin Console** (simplest):
Admin Console → **Create realm → Import** → select `realm-export.json` → Create.
Then fix the two values that are masked in the export:
- **Client secret**: Clients → `openwebui` → Credentials → regenerate or paste
  `OAUTH_CLIENT_SECRET` from `.env`.
- **Admin user**: Users → Add user → assign realm role `admin` (the bootstrap
  admin from `KC_BOOTSTRAP_ADMIN_*` env is temporary and disappears after first
  login).

**Via CLI** (for scripted deploys):
```bash
docker cp ./keycloak-realm.json keycloak:/tmp/realm.json
docker exec keycloak /opt/keycloak/bin/kc.sh import \
  --realm openwebui-rewave \
  --file /tmp/realm.json
docker exec keycloak rm /tmp/realm.json   # clean up — file contains secrets
docker compose restart keycloak
```

> **Gotcha:** the CLI export masks the OIDC client secret as `**********`. After
> import, always reset it in Keycloak (Clients → `openwebui` → Credentials) to
> match `OAUTH_CLIENT_SECRET` in `.env` — otherwise SSO login fails with an
> invalid_client error.

---

## Phase 0 — Ubuntu prerequisites

1. Install Docker Engine + compose plugin from Docker's official apt repo:
   ```bash
   # add Docker's official GPG key + repo
   sudo apt-get update
   sudo apt-get install -y ca-certificates curl
   sudo install -m 0755 -d /etc/apt/keyrings
   sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
   sudo chmod a+r /etc/apt/keyrings/docker.asc
   echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

   # install engine + cli + compose plugin + buildx
   sudo apt-get update
   sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

   docker --version                  # verify engine
   docker compose version            # verify compose plugin
   ```
   As `root` the `docker` / `docker compose` commands run as-is; as a regular user
   prefix them with `sudo` (the daemon socket is root-owned).
2. Open the firewall (if ufw is enabled):
   ```bash
   sudo ufw allow 80/tcp
   sudo ufw allow 443/tcp
   ```
3. **Disable IPv6 (critical on any host with a broken IPv6 egress** — VirtualBox
   NAT, and also bare-metal LANs that advertise IPv6 with no working route out).
   Without this, the daemon/containers try the IPv6 addresses Docker Hub returns
   (AAAA records) first and stall: image pulls fail with `TLS handshake timeout` /
   token-fetch errors, and Open WebUI hangs at `Fetching 30 files: 0%` (the HF
   embedding model download) on first boot. `curl` masks it (happy-eyeballs falls
   back to IPv4) but `docker pull` does not. Make it persistent:
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
   A `.env` copied from Windows carries CRLF line endings, which Docker reads into
   variable values. Convert it to LF on the server:
   ```bash
   cd ~/openwebui-rewave
   sudo apt-get install -y dos2unix && dos2unix .env
   cat -A .env | head        # line ends show $ , not ^M$
   ```

## Phase 2 — Hostname resolution

`*.rewave.local` must resolve to the server on every machine that runs a browser.
The Ubuntu host always needs its own `/etc/hosts` entry (step 6). For the clients,
pick **Option A** (per-machine hosts file — simplest, no infra) **or Option B**
(one central DNS — no per-client edits).

6. On the Ubuntu host (needed for both options — the server resolves its own
   hostnames locally):
   ```bash
   echo "127.0.0.1 oi.rewave.local litellm.rewave.local keycloak.rewave.local" | sudo tee -a /etc/hosts
   ```

### Option A — per-client hosts file

#### A1 — Script (recommended)

The script `scripts/provision_user_pc.ps1` handles both hostname resolution
(this step) **and** the CA certificate (Phase 6 step 13) in one go. Run it
once per client PC, from an elevated PowerShell:

```powershell
# from the repo root on the client PC, or share the script + caddy-root.crt separately:
powershell -ExecutionPolicy Bypass -File .\scripts\provision_user_pc.ps1 -ServerIP <server-ip>
```

Idempotent (safe to re-run, updates entries if the server IP changes). Includes
a `-Uninstall` flag to reverse all changes.

> The script also needs `caddy\caddy-root.crt`. Copy it from the server first
> (or run the script after Phase 6 below). Default cert path =
> `caddy\caddy-root.crt` relative to the repo root; override with `-CertPath`.

#### A2 — Manual

7. Get the server LAN IP (`hostname -I`) and add to each **client** machine's
   hosts file (Windows: `C:\Windows\System32\drivers\etc\hosts`, as Admin):
   ```
   <server-ip> oi.rewave.local litellm.rewave.local keycloak.rewave.local
   ```
   Verify from the client: `ping oi.rewave.local` → `<server-ip>`.

### Option B — central DNS (dnsmasq on the server)

One wildcard record resolves every `*.rewave.local` for all clients via the
router's DHCP-advertised DNS — no per-client hosts edits. Works directly for
Windows clients (no mDNS conflict on `.local`); for Mac/Linux clients, which
intercept `.local` over mDNS, rename the domain to a non-reserved suffix
(e.g. `.rewave.lan`) across `Caddyfile`, Keycloak redirect URIs, `.env` and
`docker-compose.yml` first.

7. Set up dnsmasq on the server (this is the alternative to step 7 above — do
   one or the other):

   a. Install dnsmasq:
   ```bash
   sudo apt-get install -y dnsmasq
   ```
   b. dnsmasq listens **only on the LAN IP** so it does not clash with
   `systemd-resolved` (which holds `127.0.0.53:53`). Create
   `/etc/dnsmasq.d/rewave.conf` (substitute the server IP and the gateway):
   ```
   listen-address=<SERVER_IP>
   bind-interfaces
   no-resolv
   server=<GATEWAY_IP>
   address=/rewave.local/<SERVER_IP>
   ```
   - `address=/rewave.local/...` → wildcard: any `*.rewave.local` → the server.
   - `no-resolv` + `server=<gateway>` → forward everything else upstream (avoids a
     loop back into systemd-resolved).
   c. Enable and start it, open port 53 if ufw is active:
   ```bash
   sudo systemctl enable --now dnsmasq
   sudo ufw allow 53
   ```
   If dnsmasq fails to bind port 53, set `DNSStubListener=no` in
   `/etc/systemd/resolved.conf`, then `sudo systemctl restart systemd-resolved`.
   d. On the **router**, set the DHCP primary DNS to the server IP
   (<SERVER_IP>). Clients pick it up on lease renewal (`ipconfig /renew` on
   Windows). Verify locally on the server and from a client:
   ```bash
   nslookup oi.rewave.local <SERVER_IP>   # → server IP (wildcard works)
   nslookup google.com <SERVER_IP>        # → resolves (upstream forward works)
   ```
   ```
   nslookup oi.rewave.local                 # from a Windows client → server IP
   ```

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

`openwebui` bind-mounts `./caddy/caddy-root.crt`. If it's missing at
first `up`, Docker creates a **directory** there and breaks it. Generate the
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
    > The embedding model is downloaded once at first boot — it powers the document
    > / Knowledge Base RAG (in-chat upload + collections). The `docling` image is
    > large (~GB): first `up` pulls it, and the first document conversion downloads
    > OCR/layout models. Both are one-off.
    > The `routellm` service also builds (from `routellm/Dockerfile`) and downloads
    > its small `bert` classifier on first boot — used by the request routing in
    > Phase 9 / Phase 10.

## Phase 6 — Trust the Caddy CA on the client

The Ubuntu Caddy CA is **new** (its private key lives in the host's `caddy-data`
volume — not transferable from Windows). Install it on the client so
`*.rewave.local` is trusted and the OAuth redirects don't hit cert warnings.

First, copy the cert from the server:
```powershell
scp admin@<server>:~/openwebui-rewave/caddy/caddy-root.crt .\caddy-root.crt
```

#### Option 1 — Script (recommended)

If you are running `provision_user_pc.ps1` (Phase 2 Option A1), it handles the
cert automatically — no separate step needed. Just make sure `caddy-root.crt` is
in place before running the script (or pass `-CertPath .\caddy-root.crt`).

The script is idempotent: skips install if the cert is already trusted, replaces
an outdated cert if the CA was regenerated.

#### Option 2 — Manual

13. ```powershell
    # PowerShell as Admin:
    Import-Certificate -FilePath .\caddy-root.crt -CertStoreLocation Cert:\LocalMachine\Root
    ```
    Restart the browser. (Quick alternative without installing: click through the
    `ERR_CERT_AUTHORITY_INVALID` warning, but SSO redirects make this painful.)

#### Firefox

Firefox ignores the Windows cert store. Either:
- **Per user**: `about:config` → `security.enterprise_roots.enabled` = `true`
- **Admin / machine-wide**: deploy a `policies.json` under the Firefox install dir.
  See [Mozilla docs](https://support.mozilla.org/en-US/kb/setting-certificate-authorities-firefox).

## Phase 7 — Keycloak realm (fresh DB = empty)

With `ENABLE_LOGIN_FORM=false` + signup off, nobody can log in until SSO is set.

> **Export / import procedure:** see the "Keycloak — export and import the realm"
> section at the top of this document for the full export (CLI or Admin Console),
> import, and gotchas (masked client secret, CLI cleanup). The steps below assume
> the realm JSON is already on hand.

14. **Export** the realm from the source instance if not done already — see
    "Exporting from an existing instance → Keycloak" at the top of this file.
15. **Import** on Ubuntu: open `https://keycloak.rewave.local` → login with
    `KEYCLOAK_ADMIN` / `KEYCLOAK_ADMIN_PASSWORD` (from `.env`) → realm dropdown →
    **Create realm** → browse `openwebui-rewave-realm.json` → Create.
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

## Phase 9 — Enable API access & model connections

Do this **before** creating `rewave-ai`: the model needs a **base model**, and the
base model comes from a **connection**. This phase also enables the API key feature
the maintenance scripts (Phase 12) need. The chat path is **routed** (weak/strong)
by default, so the base model is the RouteLLM router — set its connection up here.

19. **Enable the API Key feature** (global): Admin Panel → Settings → **General** →
    **Enable API Key** ON → Save. (Or `ENABLE_API_KEY: "true"` in compose — but on an
    existing DB toggle it in the UI.) Without this, nobody can mint the personal key
    used by every `*.ps1` script.
20. **Create a personal API key** — Settings (user avatar, top-right) → **Account** →
    **API Keys** → **+** → copy the `sk-...` value. This key is **per-instance** — the
    one in `.env` belongs to the *source* instance; the scripts in Phase 11/12 take
    this fresh server key via `-ApiKey`.
21. **Verify the LiteLLM connection** (the source of the `claude-*` models) — Admin
    Panel → Settings → **Connections** → OpenAI API. The env (`OPENAI_API_BASE_URL=
    http://litellm:4000/v1`, key = `LITELLM_MASTER_KEY`) seeds it on a fresh DB, so it
    should already be listed and serve `claude-sonnet` (strong) + `claude-haiku`
    (weak) — LiteLLM exposes `/v1/models`, so they auto-discover. If it's missing
    (existing DB / cleared config), add it manually: **+** → URL
    `http://litellm:4000/v1`, API key = the LiteLLM master key, API Type =
    Chat Completions → Save. These two models become selectable **base models**.
22. **Add the RouteLLM connection** (the standard routed base model). Admin Panel → Settings →
    Connections → OpenAI API → **+**:
    - **URL**: `http://routellm:6060/v1` · **Authentication**: None ·
      **API Type**: Chat Completions
    - **Model ID** (the `+` field): add **`router-bert-<threshold>`** manually
      (RouteLLM does not serve `/v1/models`, so it can't be auto-discovered — a
      404 there is normal). Use the threshold from step 23. Save.
    > For each request the local `bert` classifier scores the **last user message**
    > and routes simple ones to `claude-haiku`, complex ones to `claude-sonnet`,
    > both reached back through LiteLLM (so caching + param-drops apply). The weak
    > tier is **cloud Haiku, not a local model** — a CPU Ollama model can't prefill
    > the full-context wiki (~16k+ tokens, no caching) fast enough. See
    > `routellm/README.md`. (`litellm-config.yaml` already gives both models
    > `cache_control_injection_points` and `additional_drop_params: ["top_p"]`, plus
    > global `drop_params: true` — RouteLLM always injects `temperature`+`top_p`,
    > which Anthropic rejects together, hence the top_p drop.)
23. **Calibrate the threshold** — the cutoff is baked into the model id
    (`router-bert-0.6` = `0.6`; **higher → more traffic to the weak model**). The
    `[eval]` deps aren't in the runtime image, install them just for the run:
    ```bash
    docker compose exec routellm pip install "routellm[eval]==0.2.0"
    docker compose exec routellm python -m routellm.calibrate_threshold \
      --task calibrate --routers bert --strong-model-pct 0.5
    # → prints e.g. "threshold = 0.4066". Lower --strong-model-pct → cheaper.
    ```
    The `bert` router is English-trained, so treat the calibrated value as a
    starting point and tune empirically (current value: `router-bert-0.6`). Pass the
    chosen `router-bert-<threshold>` as the Model ID at step 22 and the Base Model at step 25.
    > **Skipping routing?** If you do not want weak/strong routing, skip steps 22–23
    > and use `claude-sonnet` as the base model in Phase 10. Everything else in
    > Phase 10 is the same except the visibility of `router-bert-<threshold>`.

## Phase 10 — Create the `rewave-ai` model

`rewave-ai` is the **only** model users pick; its base model is the RouteLLM router
from Phase 9 (or `claude-sonnet` if you skipped routing).

Steps 24–31 are the Admin-UI procedure. After completing them run the wiki push (Phase 12) to fill the empty markers.

24. **Activate & test Web Search manually from a chat** (the engine is already
    enabled by env — `ENABLE_WEB_SEARCH`, `WEB_SEARCH_ENGINE=duckduckgo`,
    `RAG_WEB_LOADER_ENGINE=playwright`). Open a new chat, toggle **Web Search** on
    in the message-box integrations menu, and ask a current-events question. Confirm
    it returns results with citations (proves `playwright` + duckduckgo work) before
    wiring it into the model. **Note:** web search stays a **per-chat manual toggle**,
    *not* a model Default Feature — see step 29 (enabling it as a default breaks
    routing).
25. **Create the model** — Admin Panel → Settings →
    Models → **+**:
    - **Name**: `ReWave AI`, **Model ID**: `rewave-ai`
    - **Base Model**: `router-bert-<threshold>` (the routed standard path, from
      Phase 9 step 22). *(Skipped routing? use `claude-sonnet`.)*
    - **Description**: `Assistente aziendale ReWave`.
26. **System Prompt** — open Admin Panel → Settings → Models → `rewave-ai` →
    **System Prompt** and paste the **whole block below verbatim**, including the two
    empty `=====BEGIN/END WIKI=====` marker lines (leave them empty — Phase 12's
    `refresh_wiki.ps1` injects the bundle between them). Save. This is the live
    3-source prompt (priority order: WIKI → WEB SEARCH RESULTS → GENERAL KNOWLEDGE):
    ```
    Sei assistente Rewave Srl (cartotecnica, italiano).

    Hai 3 fonti info in ordine priorità:

    1. WIKI REWAVE (sotto, tra marker BEGIN/END WIKI): conoscenza interna autoritativa su clienti, prodotti, decisioni, mercato. Cita con [[slug-pagina]] solo se slug esiste in sezione index.md del bundle.

    2. WEB SEARCH RESULTS: se nel contesto della chat appaiono risultati di ricerca web (snippet con URL, iniettati automaticamente dal sistema), usali per rispondere e cita URL. Non chiedere mai all'utente di "attivare web search" — se risultati ci sono, sono già lì; se non ci sono, rispondi con wiki + general knowledge.

    3. GENERAL KNOWLEDGE: domande tech generiche, concetti, how-to → rispondi normale senza forzare wiki.

    Regole:
    - Info in wiki → cita wiki, non duplicare con web.
    - Wiki dice "unclear" o manca dato → dichiara "non in wiki" poi rispondi con web results (se presenti) o general knowledge.
    - Mai inventare slug wiki.
    - Mai chiedere all'utente di abilitare funzionalità — usa ciò che hai in contesto.
    - Lingua: italiano default.
    - Se domanda totalmente fuori dominio Rewave → rispondi normale general purpose, ignora wiki.

    =====BEGIN WIKI=====
    =====END WIKI=====
    ```
27. **Advanced Params**: `temperature = 0.2`, `max_tokens = 4096`.
28. **Capabilities** — ON: `file_context`, `vision`, `file_upload`, `web_search`,
    `citations`, `status_updates`, `builtin_tools`. OFF: `image_generation`,
    `code_interpreter`, `terminal`, `usage`.
29. **Default Features & Builtin Tools** —
    - **Default Features**: leave **Web Search OFF**. It stays a *capability* (step
      28) so users toggle it per-chat (step 24), but it must **not** be a default.
    - **Builtin Tools**: enable only **Time & Calculation** (reliable math + date
      arithmetic); leave all others OFF.
    > ‼️ **Why Web Search must not be a Default Feature.** With web search (or any
    > retrieved context / citations) active, Open WebUI wraps **every** user message
    > in a long `### Task: Respond to the user query using the provided context,
    > incorporating inline citations …` template. RouteLLM classifies `messages[-1]`
    > — i.e. that template, not the real question — so it scores **every** query as
    > complex and routes **everything to Sonnet**, defeating the router.
    > - **Web Search**: capability ON, Default Feature OFF. A query with search
    >   toggled on then routes to Sonnet — appropriate (web-augmented = "heavy").
    > - **Citations**: fine to leave **on** — passive (only format sources when
    >   there's retrieved context: `#kb`, uploaded files, or toggled web search).
    >   They don't wrap plain chat, so normal queries still route to Haiku.
    > - Same logic for `#kb` / uploaded-file queries: they get the context template
    >   → Sonnet (appropriate for document Q&A).
30. **Pin the Task Model to the cheapest model (`claude-haiku`)** — manual:
    Admin Panel → Settings → **Interface** → **Task Model** (local *and* external) =
    **`claude-haiku`**. Open WebUI fires background calls per chat — **chat title
    generation, tag generation**, follow-up suggestions, search-query generation —
    and these must run on the **cheap** model, not Sonnet. Without this pin they'd
    route through `rewave-ai` → the router → often the strong model. Pointing them at
    Haiku keeps titles/tags cheap and off Sonnet. (Requires the LiteLLM connection
    from step 21 so `claude-haiku` is selectable; refresh the connection if it
    doesn't appear.)
31. **Visibility** — subtle but important. Open WebUI resolves
    a model's **base model with the requesting user's permissions**, not server-side:
    - `rewave-ai` → **Public** (the only model users pick)
    - `router-bert-<threshold>` → **Public too**. It is `rewave-ai`'s *base model*;
      if it's Private a non-admin gets **`model not found`** when using `rewave-ai`.
      (It then also shows in the selector — acceptable; picking it raw just gives
      routing without the wiki.)
    - `claude-sonnet` / `claude-haiku` / `gemma3-4b` → **Private**. These are the
      router's *targets*: `routellm` calls them through LiteLLM with the **master
      key** (server-side), so users never resolve them and don't need access.

    Set at Admin Panel → Settings → Models → *(model)* → visibility.
    > The built-in **Arena Model** entry is hidden via
    > `ENABLE_EVALUATION_ARENA_MODELS=false` (in `docker-compose.yml`). On an
    > already-initialized DB, disable it at Admin Panel → Settings → Evaluation
    > (turn Arena Models off).
    > **Skipped routing?** Then `claude-sonnet` is the base model → make it **Public**
    > instead, and there is no `router-bert-<threshold>` entry.
32. **Verify** — new chat on `rewave-ai`:
    - first, `"ciao"` answers (errors → `docker compose logs --tail 30 litellm`,
      check `ANTHROPIC_API_KEY`).
    - a trivial prompt ("salutami") → served by `claude-haiku`
    - a complex one (multi-step analysis / comparison) → `claude-sonnet`
    - log in as a **non-admin** → `rewave-ai` must answer (not "model not found").

    Check which model served a request from inside the stack (LiteLLM has no host
    port):
    ```bash
    docker compose exec -T litellm python - <<'PY'
    import os, json, urllib.request
    key=os.environ["LITELLM_MASTER_KEY"]
    d=json.loads(urllib.request.urlopen(urllib.request.Request(
        "http://localhost:4000/spend/logs",
        headers={"Authorization":f"Bearer {key}"})).read())
    for r in (d if isinstance(d,list) else d.get("data",[]))[-10:]:
        print(r.get("startTime","")[-8:], r.get("model"))
    PY
    ```
    `general_settings.store_prompts_in_spend_logs: true` (in `litellm-config.yaml`)
    also records the request/response content in those logs for debugging — note it
    persists chat content in litellm-db (privacy); set it back to `false` if you only
    needed it while tuning.
    > **Changing the threshold later** = a new model id → update it in **both** the
    > connection's Model IDs (step 22) **and** `rewave-ai`'s Base Model (step 25).

## Phase 11 — Documents & Knowledge Bases

In-chat file upload and Knowledge Bases (Open WebUI "Knowledge" / "Conoscenza")
run through the `docling` service (extraction + OCR) and a local multilingual
embedding model. On a fresh DB the `docker-compose.yml` env seeds all of this, so
no manual setup is normally needed. These keys are **PersistentConfig**: env seeds
a new DB only; on an already-initialized DB change them in the UI instead.

33. Verify extraction + embedding — Admin Panel → Settings → **Documents**:
    - Content Extraction Engine = **Docling**, URL `http://docling:5001`
    - Embedding Model = `sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2`
      (local engine), downloaded on first boot
    From env `CONTENT_EXTRACTION_ENGINE=docling`, `DOCLING_SERVER_URL`,
    `RAG_EMBEDDING_MODEL`. Docling extracts PDF / Office / scanned PDFs (OCR,
    RapidOCR default — handles Latin text + numbers well).

> **Vector store = pgvector, not Chroma.** The `openwebui-vector-db` service
> (`pgvector/pgvector:pg16`) holds all RAG embeddings; Open WebUI uses it via
> `VECTOR_DB=pgvector` + `PGVECTOR_DB_URL` (password `OWUI_VECTOR_DB_PASSWORD` in
> `.env`, hex only — must be URL-safe). It scales far past embedded Chroma and is
> backed up like the other postgres DBs. **Re-index when migrating:** vectors do
> not transfer between backends (Chroma→pgvector) or across embedding models —
> existing Knowledge Bases must be re-uploaded. The old Chroma data sits inert in
> the `openwebui-data` volume and can be purged afterward.
34. Verify retrieval tuning (same Documents page): Top K = 5, Top K Reranker = 5,
    Hybrid Search ON, Reranking Model **empty**. From env `RAG_TOP_K=5`,
    `ENABLE_RAG_HYBRID_SEARCH=true`, `RAG_TOP_K_RERANKER=5`,
    `RAG_HYBRID_BM25_WEIGHT=0.5`. Hybrid = semantic + keyword (good for exact
    codes/sigle); with no reranking model it falls back to embedding similarity.
35. Let users create & share Knowledge. On a fresh DB the env seeds it
    (`USER_PERMISSIONS_WORKSPACE_KNOWLEDGE_ACCESS=true`,
    `..._ALLOW_SHARING=true`, `..._ALLOW_PUBLIC_SHARING=false`). On an existing DB
    set it in the UI: Admin Panel → Users → Groups → **Default Permissions** →
    **Workspace Permissions** → Knowledge Access ON, Knowledge Sharing ON,
    Public Sharing OFF.
36. (optional) **Department groups** — sharing a collection "to a department"
    requires that group to exist. Create them under Admin Panel → Users → Groups
    (e.g. `amministrazione`, `contabilita`, `progettazione`) and assign users, or
    sync from Keycloak via an OIDC group claim. Until a group exists, users can
    still share collections with individual users.

> **Chat Controls hidden from base users.** `USER_PERMISSIONS_CHAT_CONTROLS=false`
> (+ `_SYSTEM_PROMPT`, `_PARAMS`, `_VALVES`) removes the per-chat **Controls** panel
> (system prompt / advanced params / valves override) for non-admins. On an
> already-initialized DB set it in Admin Panel → Users → Groups → **Default
> Permissions** → **Chat** (turn Controls off).
>
> Other base-user permissions are also locked via env: **off** =
> `FEATURES_IMAGE_GENERATION`, `FEATURES_CODE_INTERPRETER`, `FEATURES_CALENDAR`,
> `FEATURES_MEMORIES`, `CHAT_MULTIPLE_MODELS`, `CHAT_SHARE`, `CHAT_EXPORT`; **on** =
> `WORKSPACE_KNOWLEDGE_ACCESS` + `WORKSPACE_KNOWLEDGE_ALLOW_SHARING` (create & share
> KBs). Kept on for users: file upload, web upload, web search, folders, notes,
> channels, voice (stt/tts/call). Same Default Permissions / per-group path applies
> on an existing DB.
>
> **Gotcha:** a **group freezes the default permissions as they were when the group
> was created**, and group permissions override the default. If a user is in a group
> created while Controls was still allowed, they keep it — also turn Controls off in
> that group: Admin Panel → Users → Groups → *(group)* → Permissions → Chat. (On a
> fresh deploy the env seeds the default first, so groups created afterwards inherit
> Controls = off.)

> **Images (PNG/JPG) are not accepted** for RAG in this Open WebUI version — only
> documents and **PDF** (scanned PDFs are OCR'd). For scans use PDF, not images.
> Native-text PDFs extract best; complex templates (colored tables, empty rows,
> logos) extract less reliably.

End-user guide (Italian, for the office departments): [GUIDA_UTENTI.md](GUIDA_UTENTI.md).

## Phase 12 — Push the wiki bundle, suggestion cards and functions

This belongs right after the documents/KB setup — it loads the actual content
(wiki, suggestion cards, functions) into the model. All scripts use the
**server** API key minted in Phase 9 (step 20) — pass it via `-ApiKey`. They
auto-load `.env`, which points at the *source* instance, so the `-BaseUrl` /
`-ApiKey` / `-ModelId` parameters override it.

37. From the maintenance machine (Windows, where `llm_wiki/` + `pwsh` live),
    push the wiki bundle to the server:
    ```powershell
    pwsh -File .\scripts\refresh_wiki.ps1 -BaseUrl "https://oi.rewave.local" -ApiKey "sk-<server-key>" -ModelId "rewave-ai"
    ```
    It regenerates the bundle, GETs the model, replaces the text between
    `=====BEGIN WIKI=====` / `=====END WIKI=====`, and PATCHes it back. (TLS works
    because the client trusts the Caddy CA from Phase 6.)
38. Test in chat: ask something covered by the vault — the answer must cite real
    `[[slug]]` pages from `index.md` and respect the 3-source rules.
39. Seed the new-chat prompt suggestion cards (the "Suggerito" cards on an empty
    chat). The `DEFAULT_PROMPT_SUGGESTIONS` env only seeds a fresh DB, so on a
    re-seeded or existing DB set them via the API script:
    ```powershell
    pwsh -File .\scripts\seed_suggestions.ps1 -BaseUrl "https://oi.rewave.local" -ApiKey "sk-<server-key>"
    ```
    Idempotent: overwrites the whole list via `POST /api/v1/configs/suggestions`
    (edit the `$suggestions` array in the script). Verify: open a new chat → the
    cards appear under "Suggerito".

    **Manual UI path:** Admin Panel → Settings → Interface → "Default Prompt
    Suggestions". Each card has two title lines and a content string.
    > ⚠️ **Known OWUI bug (as of v0.9.6):** the UI does not pre-fill the existing
    > values — the fields appear empty even when cards are active. Editing blindly
    > overwrites whatever is set. Use the script to be safe. Check whether this is
    > fixed in newer versions before relying on the UI
    > ([upstream discussion](https://github.com/open-webui/open-webui/discussions/7024)).
40. Install the custom **Functions** (the `Presentazione PDF` filter: triggers on
    any reply containing a reveal.js deck — `<div class="reveal">` — regardless of
    how the presentation was requested. Renders slides to PDF via the playwright
    container, appends a download link, no button click needed). DB rows, push via:
    ```powershell
    pwsh -File .\scripts\seed_functions.ps1 -BaseUrl "https://oi.rewave.local" -ApiKey "sk-<server-key>"
    ```
    Idempotent: creates missing functions, refreshes existing code, and sets
    `is_active` + `is_global` so they apply to `rewave-ai` with no per-model
    assignment. No restart needed (Open WebUI loads the code live). Verify in chat:
    ask for a presentation in natural language → the model generates reveal.js HTML →
    a **📄 Scarica la presentazione (PDF)** link appears automatically. (No extra pip
    deps: the openwebui image already ships `playwright`, the exact version of the
    `playwright` service.)

    **Manual import** (alternative to the script — e.g. on an existing instance):
    Admin Panel → Functions → **+** → paste contents of `functions/esporta_pdf.py` →
    Save → toggle **Active** ON → toggle **Global** ON. Global = filter runs for
    every model; skip Global and attach under Admin Panel → Models → `rewave-ai` →
    Functions tab if you want it scoped to `rewave-ai` only.

---

## Phase 13 — (optional) Mirror `llm_wiki/` files onto the server

The chat works without this (the bundle lives in the model's system prompt). Copy
the files only to keep the server self-consistent or to maintain the vault there.

42. ```powershell
    scp -r llm_wiki/raw llm_wiki/wiki llm_wiki/CLAUDE.md llm_wiki/index.md `
        llm_wiki/log.md llm_wiki/_bundle.md admin@<server>:~/openwebui-rewave/llm_wiki/
    ```
    To maintain the vault from the server: install pwsh
    (`sudo snap install powershell --classic`), put the server API key in the
    server `.env` as `OPENWEBUI_API_KEY`, then run `refresh_wiki.ps1` there.

---

## Phase 14 — (optional) Local models via Ollama on the server

Ollama installed via the official script runs as a systemd service bound to
`127.0.0.1:11434` — safe by default, but unreachable from containers. Do **not**
"fix" it with a plain `OLLAMA_HOST=0.0.0.0`: that exposes an unauthenticated
LLM API to the whole LAN. Pick one of these instead:

43. **Option A (preferred) — bind to the Docker bridge only.** Containers reach
    the host at `host.docker.internal` → `172.17.0.1` (docker0), so listen there
    and nowhere else:
    ```bash
    sudo systemctl edit ollama
    ```
    ```ini
    [Unit]
    # docker0 must exist before Ollama binds to it
    After=docker.service
    Wants=docker.service

    [Service]
    Environment="OLLAMA_HOST=172.17.0.1:11434"
    ```
    ```bash
    sudo systemctl daemon-reload && sudo systemctl restart ollama
    ```

44. **Option B — bind everywhere, firewall the LAN out.** Only if ufw is active
    (`sudo ufw status` → active, default deny incoming):
    ```bash
    sudo systemctl edit ollama   # [Service] Environment="OLLAMA_HOST=0.0.0.0:11434"
    sudo ufw allow from 172.16.0.0/12 to any port 11434 proto tcp
    sudo systemctl restart ollama
    ```

45. The `litellm` service has no `extra_hosts` in `docker-compose.yml` (only
    `openwebui` does), so `host.docker.internal` does not resolve from it. Add:
    ```yaml
    # docker-compose.yml → litellm service
    extra_hosts:
      - "host.docker.internal:host-gateway"
    ```

46. Add (or keep) the optional `gemma3-4b` block in `litellm-config.yaml`, then
    `docker compose up -d litellm`. **Note:** this local model is **not** used by
    request routing (Phase 9 / Phase 10) — the weak tier is cloud `claude-haiku`,
    because a CPU model can't prefill the full-context wiki fast enough. Keep
    `gemma3-4b` only if you want a local model for admin testing; otherwise skip
    Phase 14.

    > **Tuning — keep the model warm (CPU-only hosts).** When Ollama unloads an
    > idle model (default after 5 min) the next request pays a full weight reload
    > **and** re-runs the system-prompt prefill — slow on a CPU-only host, and the
    > cost scales with the prompt size (the full-context wiki sits in the prompt,
    > so the bigger the wiki the slower the cold start). Raise the keep-alive
    > window either globally on the host (`sudo systemctl edit ollama` →
    > `Environment="OLLAMA_KEEP_ALIVE=30m"`, then `sudo systemctl restart ollama`;
    > on Windows: `setx OLLAMA_KEEP_ALIVE "30m"` then restart Ollama) or —
    > preferred, version-controlled — per-model in `litellm-config.yaml`
    > (`keep_alive: "30m"` under the model's `litellm_params`, then restart
    > `litellm`). Trade-off: a resident model holds its RAM while idle (roughly the
    > quant file size) — lower the window, or keep the `5m` default, if the host is
    > memory-constrained. `-1` = never unload, `0` = unload immediately.

47. Verify reachability from the container, and that the LAN is locked out:
    ```bash
    docker exec litellm python -c "import urllib.request; print(urllib.request.urlopen('http://host.docker.internal:11434').read())"   # → b'Ollama is running'
    # from another machine on the LAN: curl http://<server>:11434  → must time out / be refused
    ```

---

## Optional & disabled features — how to enable / disable

This deployment ships with some features turned off. How to toggle them:

### `llama3.1` local model — admin-only
Visible only to admins by default; needs Ollama on the host (Phase 14).
- **Show to all users:** Admin Panel → Settings → Models → `llama3.1` →
  visibility **Public**.
- **Hide again:** same screen → **Private**.

### Local models via Ollama — not installed by default
See Phase 14. Without it `llama3.1` has no backend and cannot answer.

### Request routing (RouteLLM) — standard, but removable
Routing (Phase 9 + Phase 10) is the default. To run **without** it, set `rewave-ai`'s
Base Model back to `claude-sonnet` (Admin → Settings → Models → `rewave-ai`), make
`claude-sonnet` **Public**, and ignore the `router-bert-<threshold>` connection.
Every chat then goes straight to Sonnet (more capable, more expensive).

---

## Operations cheatsheet

```bash
docker compose up -d                 # start / re-create changed containers
docker compose ps                    # status
docker compose logs -f <service>     # tail
docker compose restart litellm       # after editing litellm-config.yaml
docker compose restart caddy         # after editing caddy/Caddyfile
docker compose up -d --build routellm # after editing routellm/Dockerfile
docker compose down                  # stop (named volumes persist)
```

- After editing `.env` → `docker compose up -d` (re-creates affected services).
- `rewave-ai` model / connection / visibility / task-model changes: update manually in Admin Panel (Phase 10 steps 25–31).
- Wiki updates: re-run the Phase 12 `refresh_wiki.ps1` command.
- Suggestion-card or function changes: re-run
  `seed_suggestions.ps1` / `seed_functions.ps1` (idempotent — safe on every redeploy).
- Routing threshold change: update the id in **both** the RouteLLM connection (Phase 9
  step 22) **and** `rewave-ai`'s Base Model (Phase 10 step 25) in Admin Panel.
- Full from-scratch model setup: Phase 10 (Admin UI) → `refresh_wiki.ps1` → `seed_suggestions.ps1` → `seed_functions.ps1`.
- If the bundle outgrows Sonnet's context, switch the `claude-sonnet` mapping in
  `litellm-config.yaml` to an Opus 1M-context model, then `restart litellm`.
```
