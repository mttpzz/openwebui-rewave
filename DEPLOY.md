# Deploy on a local Ubuntu server — full step-by-step guide

Complete, reusable procedure to bring the stack to production on a fresh Ubuntu
host (tested on a VirtualBox VM). The repo only contains **configuration**:
`.env`, the `llm_wiki/` content and `caddy/caddy-root.crt` are gitignored and
handled separately. The Caddy CA is **regenerated** on the host, not copied.

Phases run in order. Steps are numbered continuously across phases. Don't skip the
"gotcha" notes — each cost real time. Phases 14–15 are optional. n8n runs by
default (admins use it at `n8n.rewave.local`), but its chat **tools are not exposed
to base users** — see *Optional & disabled features* near the end.

---

## What carries over vs what you recreate

A fresh Ubuntu deploy reuses the **repo config** but starts Open WebUI with an
**empty database**. So:

**Carried over automatically** (committed to the repo):
- `docker-compose.yml` env — all default user permissions, RAG tuning, docling,
  Arena-off, single-model exposure, upload limits. → the **default permissions come
  out identical** to the source with no manual work.
- `litellm-config.yaml`, `caddy/Caddyfile`, `scripts/`.

**Migrated by hand** in the phases below: `.env`, `llm_wiki/`, the Keycloak realm,
n8n workflows/credentials, and the Open WebUI tools.

**Recreated on the fresh instance** (the Open WebUI DB is empty — not migrated):

| Item | Where |
|---|---|
| `rewave-ai` model + system prompt | Phase 9 + Phase 13 |
| `llama3.1` visibility = Private | Phase 9 |
| Prompt presets (`/commands`) | Phase 13 (`seed_prompts.ps1`) |
| New-chat prompt suggestions ("Suggerito" cards) | Phase 13 (`seed_suggestions.ps1`) |
| Functions (`Presentazione PDF`) | Phase 13 (`seed_functions.ps1`) |
| Department **groups** + user→group assignment | see below |
| Knowledge Base contents | users re-upload; folder-backed KBs via `sync_documenti.ps1` (Phase 10) |
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
    > The embedding model is downloaded once at first boot — it powers the document
    > / Knowledge Base RAG (in-chat upload + collections). The `docling` image is
    > large (~GB): first `up` pulls it, and the first document conversion downloads
    > OCR/layout models. Both are one-off.

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
    - **Description**: `Assistente aziendale ReWave (wiki full-context + RAG documenti/KB)`.
20. **System Prompt** — the 3-source instructions + the wiki markers (the bundle
    is injected between the markers in Phase 13):
    ```
    Sei assistente Rewave Srl (cartotecnica, italiano).
    [... 3-source rules: WIKI / WEB SEARCH RESULTS / GENERAL KNOWLEDGE ...]

    =====BEGIN WIKI=====
    =====END WIKI=====
    ```
21. **Advanced Params**: `temperature = 0.2`, `max_tokens = 4096`.
22. **Capabilities** — ON: `file_context`, `vision`, `file_upload`, `web_search`,
    `citations`, `status_updates`, `builtin_tools`. OFF: `image_generation`,
    `code_interpreter`, `terminal`, `usage`.
23. **Default Features**: only `web_search` ON. **Builtin Tools**: enable only
    **Time & Calculation** (reliable math + date arithmetic); leave all others OFF.
24. Test: new chat → `rewave-ai` → "ciao". Errors → `docker compose logs --tail 30 litellm` (check `ANTHROPIC_API_KEY`).
    > **Model visibility.** Users only need `rewave-ai`. The LiteLLM base model
    > `llama3.1` (Ollama, Phase 15) also appears in the model list — keep it
    > **admin-only**: Admin Panel → Settings → Models → `llama3.1` → visibility
    > **Private**. To expose it to everyone later, set it **Public** (see *Optional
    > & disabled features*).
    > The built-in **Arena Model** entry is hidden via
    > `ENABLE_EVALUATION_ARENA_MODELS=false` (in `docker-compose.yml`). On an
    > already-initialized DB, disable it instead at Admin Panel → Settings →
    > Evaluation (turn Arena Models off).

## Phase 10 — Documents & Knowledge Bases

In-chat file upload and Knowledge Bases (Open WebUI "Knowledge" / "Conoscenza")
run through the `docling` service (extraction + OCR) and a local multilingual
embedding model. On a fresh DB the `docker-compose.yml` env seeds all of this, so
no manual setup is normally needed. These keys are **PersistentConfig**: env seeds
a new DB only; on an already-initialized DB change them in the UI instead.

25. Verify extraction + embedding — Admin Panel → Settings → **Documents**:
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
26. Verify retrieval tuning (same Documents page): Top K = 5, Top K Reranker = 5,
    Hybrid Search ON, Reranking Model **empty**. From env `RAG_TOP_K=5`,
    `ENABLE_RAG_HYBRID_SEARCH=true`, `RAG_TOP_K_RERANKER=5`,
    `RAG_HYBRID_BM25_WEIGHT=0.5`. Hybrid = semantic + keyword (good for exact
    codes/sigle); with no reranking model it falls back to embedding similarity.
27. Let users create & share Knowledge. On a fresh DB the env seeds it
    (`USER_PERMISSIONS_WORKSPACE_KNOWLEDGE_ACCESS=true`,
    `..._ALLOW_SHARING=true`, `..._ALLOW_PUBLIC_SHARING=false`). On an existing DB
    set it in the UI: Admin Panel → Users → Groups → **Default Permissions** →
    **Workspace Permissions** → Knowledge Access ON, Knowledge Sharing ON,
    Public Sharing OFF.
28. (optional) **Department groups** — sharing a collection "to a department"
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
> the Phase 13 scripts.

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

## Phase 11 — Tools (n8n clients: `send_email`, `mail_digest`)

> **The chat tools are kept private to admins, not attached to `rewave-ai`.** n8n
> runs, and admins build/test workflows at `n8n.rewave.local`. Import the tools
> (steps 30–32) so admins can enable them per chat; **skip step 33** (attaching to
> `rewave-ai`) unless you want all users to have them — to do that, see *Optional &
> disabled features* (make the tools public **and** attach them). Step 29 (Enable
> API Key) is still needed for Phase 13.

29. Enable the API Key feature (needed in Phase 13): Admin Panel → Settings →
    General → **Enable API Key** ON → Save (or `ENABLE_API_KEY: "true"` in compose).
30. **Export** from the source: Workspace → Tools → each tool → Export `.json`.
31. **Import** on Ubuntu: Workspace → Tools → Import → select the `.json` files.
32. **Set Valves** (not exported) on each tool: `N8N_AUTH_SECRET` = the shared
    secret of the n8n webhooks. (`N8N_WEBHOOK_URL` defaults are already correct;
    `send_email` VERIFY_TLS=false, `mail_digest`=true.)
33. Attach them to the model: `rewave-ai` → edit → **Tools** tab → check
    `send_email` + `mail_digest` → Save.

## Phase 12 — Migrate n8n (workflows + credentials)

n8n runs by default; do this phase to bring the admin's workflows over. n8n has its
own login at `n8n.rewave.local` — base Open WebUI users have no n8n account, so it
is effectively admin-only.

Workflow JSON does **not** contain credentials. Credentials are portable only if
the Ubuntu n8n uses the **same `N8N_ENCRYPTION_KEY`** (same `.env`).

34. **Export** from the source (Windows):
    ```powershell
    docker exec n8n n8n export:workflow --all --output=/tmp/workflows.json
    docker exec n8n n8n export:credentials --all --output=/tmp/credentials.json
    docker cp n8n:/tmp/workflows.json .\n8n-workflows.json
    docker cp n8n:/tmp/credentials.json .\n8n-credentials.json
    ```
35. **Copy** to the server: `scp .\n8n-workflows.json .\n8n-credentials.json admin@<server>:~/openwebui-rewave/`
36. **Import** on Ubuntu (use absolute paths + explicit dest filename — a failed
    `docker cp` is what causes `ENOENT /tmp/...json`):
    ```bash
    docker cp ~/openwebui-rewave/n8n-credentials.json n8n:/tmp/credentials.json
    docker cp ~/openwebui-rewave/n8n-workflows.json   n8n:/tmp/workflows.json
    docker exec n8n ls -l /tmp/credentials.json /tmp/workflows.json   # confirm
    docker exec n8n n8n import:credentials --input=/tmp/credentials.json
    docker exec n8n n8n import:workflow   --input=/tmp/workflows.json
    docker compose restart n8n
    ```
37. In `https://n8n.rewave.local`: verify workflows + credentials, toggle each
    webhook workflow **Active** ON.
38. **Cleanup** (credentials file holds encrypted secrets):
    ```bash
    rm ~/openwebui-rewave/n8n-credentials.json
    docker exec n8n rm /tmp/credentials.json /tmp/workflows.json
    ```

## Phase 13 — Push the wiki bundle and prompt presets

39. Create an API key on the **server** Open WebUI: Settings (user avatar) →
    Account → API Keys → **+** → copy `sk-...`. (This key is per-instance — the
    one in `.env` belongs to the source instance.)
40. From the maintenance machine (Windows, where `llm_wiki/` + `pwsh` live),
    push to the server. `refresh_wiki.ps1` auto-loads `.env` (which points at the
    source) so **override via parameters** — params take precedence:
    ```powershell
    pwsh -File .\scripts\refresh_wiki.ps1 -BaseUrl "https://oi.rewave.local" -ApiKey "sk-<server-key>" -ModelId "rewave-ai"
    ```
    It regenerates the bundle, GETs the model, replaces the text between
    `=====BEGIN WIKI=====` / `=====END WIKI=====`, and PATCHes it back. (TLS works
    because the client trusts the Caddy CA from Phase 6.)
41. Test in chat: ask something covered by the vault — the answer must cite real
    `[[slug]]` pages from `index.md` and respect the 3-source rules.
42. Seed the shared `/command` prompt presets (public — visible to all users).
    They are DB rows, not seeded by env, so create them via the API script (uses
    the same server API key as step 39):
    ```powershell
    pwsh -File .\scripts\seed_prompts.ps1 -BaseUrl "https://oi.rewave.local" -ApiKey "sk-<server-key>"
    ```
    Idempotent: re-run to update the presets or add new ones (edit the `$presets`
    array in the script). Verify in chat: type `/` → the preset menu appears.
42a. Seed the new-chat prompt suggestion cards (the "Suggerito" cards on an empty
    chat). The `DEFAULT_PROMPT_SUGGESTIONS` env (Phase 8) only seeds a fresh DB, so
    on a re-seeded or existing DB set them via the API script (same server API key
    as step 39):
    ```powershell
    pwsh -File .\scripts\seed_suggestions.ps1 -BaseUrl "https://oi.rewave.local" -ApiKey "sk-<server-key>"
    ```
    Idempotent: overwrites the whole list via `POST /api/v1/configs/suggestions`
    (edit the `$suggestions` array in the script). Verify: open a new chat → the
    cards appear under "Suggerito".
42b. Install the custom **Functions** (the `Presentazione PDF` filter: after a
    `/presentazione` reply it renders the reveal.js slides to a PDF via the
    playwright container and appends a download link to the message — no button,
    fully automatic). DB rows like presets, so push them via the API script (same
    server API key as step 39):
    ```powershell
    pwsh -File .\scripts\seed_functions.ps1 -BaseUrl "https://oi.rewave.local" -ApiKey "sk-<server-key>"
    ```
    Idempotent: creates missing functions, refreshes existing code, and sets
    `is_active` + `is_global` so they apply to `rewave-ai` with no per-model
    assignment. No restart needed (Open WebUI loads the code live). Verify in chat:
    run `/presentazione` → under the slides a **📄 Scarica la presentazione (PDF)**
    link appears within a second or two. (No extra pip deps: the openwebui image
    already ships `playwright`, the exact version of the `playwright` service.)

## Phase 14 — (optional) Mirror `llm_wiki/` files onto the server

The chat works without this (the bundle lives in the model's system prompt). Copy
the files only to keep the server self-consistent or to maintain the vault there.

43. ```powershell
    scp -r llm_wiki/raw llm_wiki/wiki llm_wiki/CLAUDE.md llm_wiki/index.md `
        llm_wiki/log.md llm_wiki/_bundle.md admin@<server>:~/openwebui-rewave/llm_wiki/
    ```
    To maintain the vault from the server: install pwsh
    (`sudo snap install powershell --classic`), put the server API key in the
    server `.env` as `OPENWEBUI_API_KEY`, then run `refresh_wiki.ps1` there.

---

## Phase 15 — (optional) Local models via Ollama on the server

Ollama installed via the official script runs as a systemd service bound to
`127.0.0.1:11434` — safe by default, but unreachable from containers. Do **not**
"fix" it with a plain `OLLAMA_HOST=0.0.0.0`: that exposes an unauthenticated
LLM API to the whole LAN. Pick one of these instead:

44. **Option A (preferred) — bind to the Docker bridge only.** Containers reach
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

45. **Option B — bind everywhere, firewall the LAN out.** Only if ufw is active
    (`sudo ufw status` → active, default deny incoming):
    ```bash
    sudo systemctl edit ollama   # [Service] Environment="OLLAMA_HOST=0.0.0.0:11434"
    sudo ufw allow from 172.16.0.0/12 to any port 11434 proto tcp
    sudo systemctl restart ollama
    ```

46. The `litellm` service has no `extra_hosts` in `docker-compose.yml` (only
    `openwebui` does), so `host.docker.internal` does not resolve from it. Add:
    ```yaml
    # docker-compose.yml → litellm service
    extra_hosts:
      - "host.docker.internal:host-gateway"
    ```

47. Uncomment the `llama3.1` block in `litellm-config.yaml`, then
    `docker compose up -d litellm`.

48. Verify reachability from the container, and that the LAN is locked out:
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
Visible only to admins by default; needs Ollama on the host (Phase 15).
- **Show to all users:** Admin Panel → Settings → Models → `llama3.1` →
  visibility **Public**.
- **Hide again:** same screen → **Private**.

### Local models via Ollama — not installed by default
See Phase 15. Without it `llama3.1` has no backend and cannot answer.

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
- Wiki updates: re-run the Phase 13 `refresh_wiki.ps1` command.
- Prompt-preset, suggestion-card or Action-function changes: re-run
  `seed_prompts.ps1` / `seed_suggestions.ps1` / `seed_functions.ps1` (all
  idempotent — safe on every redeploy).
- Folder-backed KBs: re-run `sync_documenti.ps1` (incremental) after the source
  folder changes; schedule it (cron / Task Scheduler) to keep a KB up to date.
- If the bundle outgrows Sonnet's context, switch the `claude-sonnet` mapping in
  `litellm-config.yaml` to an Opus 1M-context model, then `restart litellm`.
```
