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
"gotcha" notes — each cost real time. **Phases 15–16 are optional** (file mirror,
local Ollama models); everything up to and including Phase 14 is the standard
path — **request routing (Phase 9 + Phase 10) is standard, not optional**. n8n runs
by default (admins use it at `n8n.rewave.local`), but its chat **tools are not
exposed to base users** — see *Optional & disabled features* near the end.

---

## What carries over vs what you recreate

A fresh Ubuntu deploy reuses the **repo config** but starts Open WebUI with an
**empty database**. So:

**Carried over automatically** (committed to the repo):
- `docker-compose.yml` env — all default user permissions, RAG tuning, docling,
  Arena-off, single-model exposure, upload limits, web-search engine. → the
  **default permissions come out identical** to the source with no manual work.
- `litellm-config.yaml`, `caddy/Caddyfile`, `scripts/`.

**Migrated by hand** in the phases below: `.env`, `llm_wiki/`, the Keycloak realm,
n8n workflows/credentials, and the Open WebUI tools.

**Recreated on the fresh instance** (the Open WebUI DB is empty — not migrated):

| Item | Where |
|---|---|
| API key feature + personal API key | Phase 9 |
| RouteLLM connection + threshold | Phase 9 (connection: `seed_model.ps1`) |
| `rewave-ai` model + system prompt | Phase 10 (`seed_model.ps1`) + Phase 12 (`refresh_wiki.ps1`) |
| Model visibility (`rewave-ai` Public, targets Private) | Phase 10 (`seed_model.ps1`) |
| Task Model = `claude-haiku` (titles/tags) | Phase 10 (`seed_model.ps1`) |
| Prompt presets (`/commands`) | Phase 12 (`seed_prompts.ps1`) |
| New-chat prompt suggestions ("Suggerito" cards) | Phase 12 (`seed_suggestions.ps1`) |
| Functions (`Presentazione PDF`) | Phase 12 (`seed_functions.ps1`) |
| Department **groups** + user→group assignment | see below |
| Knowledge Base contents | users re-upload; folder-backed KBs via `sync_documenti.ps1` (Phase 11) |
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
   echo "127.0.0.1 oi.rewave.local litellm.rewave.local keycloak.rewave.local n8n.rewave.local" | sudo tee -a /etc/hosts
   ```

### Option A — per-client hosts file

7. Get the server LAN IP (`hostname -I`) and add to each **client** machine's
   hosts file (Windows: `C:\Windows\System32\drivers\etc\hosts`, as Admin):
   ```
   <server-ip> oi.rewave.local litellm.rewave.local keycloak.rewave.local n8n.rewave.local
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
   listen-address=192.168.1.115
   bind-interfaces
   no-resolv
   server=192.168.1.253
   address=/rewave.local/192.168.1.115
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
   (`192.168.1.115`). Clients pick it up on lease renewal (`ipconfig /renew` on
   Windows). Verify locally on the server and from a client:
   ```bash
   nslookup oi.rewave.local 192.168.1.115   # → server IP (wildcard works)
   nslookup google.com 192.168.1.115        # → resolves (upstream forward works)
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
22. **Add the RouteLLM connection** (the standard routed base model). **This is done
    automatically by `seed_model.ps1` in Phase 10** — you only need to do it by hand
    for an existing DB or a no-script setup. Manual: Admin Panel → Settings →
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
    chosen `router-bert-<threshold>` to `seed_model.ps1 -RouterModelId` (Phase 10),
    or, if adding the connection by hand, use it in the Model ID at step 22.
    > **Skipping routing?** If you do not want weak/strong routing, skip steps 22–23
    > and use `claude-sonnet` as the base model in Phase 10. Everything else in
    > Phase 10 is the same except the visibility of `router-bert-<threshold>`.

## Phase 10 — Create the `rewave-ai` model

`rewave-ai` is the **only** model users pick; its base model is the RouteLLM router
from Phase 9 (or `claude-sonnet` if you skipped routing).

**Automated path (recommended).** `seed_model.ps1` does steps 25–31 in one call —
it creates the RouteLLM connection (Phase 9 step 22), the `rewave-ai` model with the
full system prompt + params + capabilities + default-features, sets visibility
(router Public, targets Private), and pins the Task Model to `claude-haiku`:
```powershell
pwsh -File .\scripts\seed_model.ps1 -BaseUrl "https://oi.rewave.local" -ApiKey "sk-<server-key>" -RouterModelId "router-bert-<threshold>"
```
Idempotent (create-or-update). Use the threshold from Phase 9 step 23; the default
is `router-bert-0.6`. Then run the wiki push (Phase 12) to fill the empty markers.
The system-prompt text lives in `seed_model.ps1` (`$systemPrompt`) — that script is
its source of truth; the copy in step 26 is for reference / manual setup.

Steps 24–31 below: step 24 is a manual check; steps 25–31 document **what the script
sets**, and double as the **manual Admin-UI procedure** for an existing DB or a
no-script setup.

24. **Activate & test Web Search manually from a chat** (the engine is already
    enabled by env — `ENABLE_WEB_SEARCH`, `WEB_SEARCH_ENGINE=duckduckgo`,
    `RAG_WEB_LOADER_ENGINE=playwright`). Open a new chat, toggle **Web Search** on
    in the message-box integrations menu, and ask a current-events question. Confirm
    it returns results with citations (proves `playwright` + duckduckgo work) before
    wiring it into the model. **Note:** web search stays a **per-chat manual toggle**,
    *not* a model Default Feature — see step 29 (enabling it as a default breaks
    routing).
25. **Create the model** *(script: automatic)* — manual: Admin Panel → Settings →
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
    > Source of truth = the live model. To re-extract it exactly:
    > `docker exec openwebui python -c "import sqlite3,json; print(json.loads(sqlite3.connect('/app/backend/data/webui.db').execute(\"select params from model where id='rewave-ai'\").fetchone()[0])['system'].split('=====BEGIN WIKI=====')[0])"`
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
30. **Pin the Task Model to the cheapest model (`claude-haiku`)** *(script:
    automatic; or env `TASK_MODEL`/`TASK_MODEL_EXTERNAL` on a fresh DB)* — manual:
    Admin Panel → Settings → **Interface** → **Task Model** (local *and* external) =
    **`claude-haiku`**. Open WebUI fires background calls per chat — **chat title
    generation, tag generation**, follow-up suggestions, search-query generation —
    and these must run on the **cheap** model, not Sonnet. Without this pin they'd
    route through `rewave-ai` → the router → often the strong model. Pointing them at
    Haiku keeps titles/tags cheap and off Sonnet. (Requires the LiteLLM connection
    from step 21 so `claude-haiku` is selectable; refresh the connection if it
    doesn't appear.)
31. **Visibility** *(script: automatic)* — subtle but important. Open WebUI resolves
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

> **(optional) Folder → KB sync.** To pre-load a KB from a local folder (instead of
> users uploading by hand), set two positionally paired lists in `.env`
> (`SYNC_FOLDERS=path1;path2`, `SYNC_KB_NAMES=kb1;kb2`) and run
> `pwsh -File .\scripts\sync_documenti.ps1` (creates the KB if missing; uploads via
> docling + OCR; incremental re-runs via a per-KB state file in `.sync_state/`).
> The KB is **not** attached to any model — users query it on demand with `#kbname`,
> so set its access control under **Workspace → Knowledge → Access**. For a remote
> share, point `SYNC_FOLDERS` at the mounted path (SMB/UNC) or run the script there.
> On the server pass `-BaseUrl https://oi.rewave.local -ApiKey sk-<server-key>` like
> the Phase 12 scripts (the key from Phase 9 step 20).

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

## Phase 12 — Push the wiki bundle and prompt presets

This belongs right after the documents/KB setup — it loads the actual content
(wiki, presets, suggestion cards, functions) into the model. All scripts use the
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
39. Seed the shared `/command` prompt presets (public — visible to all users).
    They are DB rows, not seeded by env, so create them via the API script:
    ```powershell
    pwsh -File .\scripts\seed_prompts.ps1 -BaseUrl "https://oi.rewave.local" -ApiKey "sk-<server-key>"
    ```
    Idempotent: re-run to update the presets or add new ones (edit the `$presets`
    array in the script). Verify in chat: type `/` → the preset menu appears.
40. Seed the new-chat prompt suggestion cards (the "Suggerito" cards on an empty
    chat). The `DEFAULT_PROMPT_SUGGESTIONS` env only seeds a fresh DB, so on a
    re-seeded or existing DB set them via the API script:
    ```powershell
    pwsh -File .\scripts\seed_suggestions.ps1 -BaseUrl "https://oi.rewave.local" -ApiKey "sk-<server-key>"
    ```
    Idempotent: overwrites the whole list via `POST /api/v1/configs/suggestions`
    (edit the `$suggestions` array in the script). Verify: open a new chat → the
    cards appear under "Suggerito".
41. Install the custom **Functions** (the `Presentazione PDF` filter: after a
    `/presentazione` reply it renders the reveal.js slides to a PDF via the
    playwright container and appends a download link to the message — no button,
    fully automatic). DB rows like presets, so push them via the API script:
    ```powershell
    pwsh -File .\scripts\seed_functions.ps1 -BaseUrl "https://oi.rewave.local" -ApiKey "sk-<server-key>"
    ```
    Idempotent: creates missing functions, refreshes existing code, and sets
    `is_active` + `is_global` so they apply to `rewave-ai` with no per-model
    assignment. No restart needed (Open WebUI loads the code live). Verify in chat:
    run `/presentazione` → under the slides a **📄 Scarica la presentazione (PDF)**
    link appears within a second or two. (No extra pip deps: the openwebui image
    already ships `playwright`, the exact version of the `playwright` service.)

## Phase 13 — Tools (n8n clients: `send_email`, `mail_digest`)

> **The chat tools are kept private to admins, not attached to `rewave-ai`.** n8n
> runs, and admins build/test workflows at `n8n.rewave.local`. Import the tools
> (steps 42–44) so admins can enable them per chat; **skip step 45** (attaching to
> `rewave-ai`) unless you want all users to have them — to do that, see *Optional &
> disabled features* (make the tools public **and** attach them). The API Key
> feature they relied on is already enabled in Phase 9 (step 19).

42. **Export** from the source: Workspace → Tools → each tool → Export `.json`.
43. **Import** on Ubuntu: Workspace → Tools → Import → select the `.json` files.
44. **Set Valves** (not exported) on each tool: `N8N_AUTH_SECRET` = the shared
    secret of the n8n webhooks. (`N8N_WEBHOOK_URL` defaults are already correct;
    `send_email` VERIFY_TLS=false, `mail_digest`=true.)
45. Attach them to the model: `rewave-ai` → edit → **Tools** tab → check
    `send_email` + `mail_digest` → Save.

## Phase 14 — Migrate n8n (workflows + credentials)

n8n runs by default; do this phase to bring the admin's workflows over. n8n has its
own login at `n8n.rewave.local` — base Open WebUI users have no n8n account, so it
is effectively admin-only.

Workflow JSON does **not** contain credentials. Credentials are portable only if
the Ubuntu n8n uses the **same `N8N_ENCRYPTION_KEY`** (same `.env`).

46. **Export** from the source (Windows):
    ```powershell
    docker exec n8n n8n export:workflow --all --output=/tmp/workflows.json
    docker exec n8n n8n export:credentials --all --output=/tmp/credentials.json
    docker cp n8n:/tmp/workflows.json .\n8n-workflows.json
    docker cp n8n:/tmp/credentials.json .\n8n-credentials.json
    ```
47. **Copy** to the server: `scp .\n8n-workflows.json .\n8n-credentials.json admin@<server>:~/openwebui-rewave/`
48. **Import** on Ubuntu (use absolute paths + explicit dest filename — a failed
    `docker cp` is what causes `ENOENT /tmp/...json`):
    ```bash
    docker cp ~/openwebui-rewave/n8n-credentials.json n8n:/tmp/credentials.json
    docker cp ~/openwebui-rewave/n8n-workflows.json   n8n:/tmp/workflows.json
    docker exec n8n ls -l /tmp/credentials.json /tmp/workflows.json   # confirm
    docker exec n8n n8n import:credentials --input=/tmp/credentials.json
    docker exec n8n n8n import:workflow   --input=/tmp/workflows.json
    docker compose restart n8n
    ```
49. In `https://n8n.rewave.local`: verify workflows + credentials, toggle each
    webhook workflow **Active** ON.
50. **Cleanup** (credentials file holds encrypted secrets):
    ```bash
    rm ~/openwebui-rewave/n8n-credentials.json
    docker exec n8n rm /tmp/credentials.json /tmp/workflows.json
    ```

---

## Phase 15 — (optional) Mirror `llm_wiki/` files onto the server

The chat works without this (the bundle lives in the model's system prompt). Copy
the files only to keep the server self-consistent or to maintain the vault there.

51. ```powershell
    scp -r llm_wiki/raw llm_wiki/wiki llm_wiki/CLAUDE.md llm_wiki/index.md `
        llm_wiki/log.md llm_wiki/_bundle.md admin@<server>:~/openwebui-rewave/llm_wiki/
    ```
    To maintain the vault from the server: install pwsh
    (`sudo snap install powershell --classic`), put the server API key in the
    server `.env` as `OPENWEBUI_API_KEY`, then run `refresh_wiki.ps1` there.

---

## Phase 16 — (optional) Local models via Ollama on the server

Ollama installed via the official script runs as a systemd service bound to
`127.0.0.1:11434` — safe by default, but unreachable from containers. Do **not**
"fix" it with a plain `OLLAMA_HOST=0.0.0.0`: that exposes an unauthenticated
LLM API to the whole LAN. Pick one of these instead:

52. **Option A (preferred) — bind to the Docker bridge only.** Containers reach
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

53. **Option B — bind everywhere, firewall the LAN out.** Only if ufw is active
    (`sudo ufw status` → active, default deny incoming):
    ```bash
    sudo systemctl edit ollama   # [Service] Environment="OLLAMA_HOST=0.0.0.0:11434"
    sudo ufw allow from 172.16.0.0/12 to any port 11434 proto tcp
    sudo systemctl restart ollama
    ```

54. The `litellm` service has no `extra_hosts` in `docker-compose.yml` (only
    `openwebui` does), so `host.docker.internal` does not resolve from it. Add:
    ```yaml
    # docker-compose.yml → litellm service
    extra_hosts:
      - "host.docker.internal:host-gateway"
    ```

55. Add (or keep) the optional `gemma3-4b` block in `litellm-config.yaml`, then
    `docker compose up -d litellm`. **Note:** this local model is **not** used by
    request routing (Phase 9 / Phase 10) — the weak tier is cloud `claude-haiku`,
    because a CPU model can't prefill the full-context wiki fast enough. Keep
    `gemma3-4b` only if you want a local model for admin testing; otherwise skip
    Phase 16.

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

56. Verify reachability from the container, and that the LAN is locked out:
    ```bash
    docker exec litellm python -c "import urllib.request; print(urllib.request.urlopen('http://host.docker.internal:11434').read())"   # → b'Ollama is running'
    # from another machine on the LAN: curl http://<server>:11434  → must time out / be refused
    ```

---

## Optional & disabled features — how to enable / disable

This deployment ships with some features turned off. How to toggle them:

### n8n — runs; email chat tools admin-only
n8n runs by default. Admins use it at `n8n.rewave.local` (its own login) to build
and test workflows; base Open WebUI users have no n8n account. The n8n-backed chat
tools (`send_email`, `mail_digest`) are kept **private to admins** (no public access
grant) and are **not attached** to `rewave-ai`, so base users never see them.
Everyone uses the same `rewave-ai` model.

- **Admin use (already works):** in any chat, open the tools selector (the ➕ /
  tools icon by the message box) and enable `send_email` / `mail_digest`. Admins
  have access (owner + admin bypass), so the tools appear there for them only.
- **Enable for ALL users:** two things are both required — Open WebUI filters a
  model's tools by each user's access, so attaching alone is not enough:
  1. Make the tools public: Workspace → Tools → each tool → **Access** → Public
     (read).
  2. Attach them to the assistant: `rewave-ai` → edit → **Tools** tab → check
     `send_email` + `mail_digest` → Save.
  To roll back, uncheck them on `rewave-ai` and set the tools' Access back to
  Private.
- **Stop n8n entirely:** `docker compose stop n8n n8n-db` (data persists in the
  `n8n-data` / `n8n-db-data` volumes). To keep it from auto-starting, add
  `profiles: ["n8n"]` to both services in `docker-compose.yml`.

### `llama3.1` local model — admin-only
Visible only to admins by default; needs Ollama on the host (Phase 16).
- **Show to all users:** Admin Panel → Settings → Models → `llama3.1` →
  visibility **Public**.
- **Hide again:** same screen → **Private**.

### Local models via Ollama — not installed by default
See Phase 16. Without it `llama3.1` has no backend and cannot answer.

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
- `rewave-ai` model / connection / visibility / task-model changes: re-run
  `seed_model.ps1` (idempotent create-or-update).
- Wiki updates: re-run the Phase 12 `refresh_wiki.ps1` command.
- Prompt-preset, suggestion-card or Action-function changes: re-run
  `seed_prompts.ps1` / `seed_suggestions.ps1` / `seed_functions.ps1` (all
  idempotent — safe on every redeploy).
- Folder-backed KBs: re-run `sync_documenti.ps1` (incremental) after the source
  folder changes; schedule it (cron / Task Scheduler) to keep a KB up to date.
- Routing threshold change: re-run `seed_model.ps1 -RouterModelId router-bert-<new>`
  (updates the connection Model IDs **and** `rewave-ai`'s Base Model together).
  Manual equivalent: update the id in **both** the RouteLLM connection (Phase 9
  step 22) and `rewave-ai`'s Base Model (Phase 10 step 25).
- Full from-scratch model setup = one script chain: `seed_model.ps1` → `refresh_wiki.ps1`
  → `seed_prompts.ps1` → `seed_suggestions.ps1` → `seed_functions.ps1`.
- If the bundle outgrows Sonnet's context, switch the `claude-sonnet` mapping in
  `litellm-config.yaml` to an Opus 1M-context model, then `restart litellm`.
```
