# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Self-hosted **Open WebUI** deployment for Rewave Srl (cartotecnica). Not a fork of Open WebUI source — this repo is the **orchestration layer**: a Docker Compose stack plus an LLM-maintained knowledge base (`llm_wiki/`) that is injected into the chat model as a full-context system prompt instead of RAG.

The whole product is configured through `docker-compose.yml` + `.env`. There is no application code to build; "deploying" means `docker compose up`.

## Stack architecture

Single Compose network (`openwebui-network`). Services:

- **openwebui** — chat frontend. Talks to LLMs only through LiteLLM (`OPENAI_API_BASE_URL: http://litellm:4000/v1`); Ollama API disabled. Exposes a single model `rewave-ai` to users (`DEFAULT_MODELS`). Auth is SSO-only (login form + signup disabled, Keycloak required).
- **litellm** (+ **litellm-db** postgres) — unified proxy for all model providers. Config in `litellm-config.yaml`. Maps friendly names (`claude-sonnet`, `llama3.1`) to real provider models, holds provider API keys, does cost-based routing, retries, and Langfuse logging. `llama3.1` (Ollama) routes to the **host** machine via `host.docker.internal:11434` (Ollama runs outside Docker) and is kept **admin-only** in Open WebUI.
- **keycloak** (+ **keycloak-db** postgres) — identity provider for SSO. Realm `openwebui-rewave`, client `openwebui`. Roles from `realm_access.roles` map to Open WebUI user/admin.
- **n8n** (+ **n8n-db** postgres) — workflow automation (email ↔ chat). Runs for admin testing at `n8n.rewave.local`; the `send_email`/`mail_digest` chat tools are **admin-only** (not attached to `rewave-ai`). Reads mail accounts/topics from env.
- **playwright** — headless browser backend for Open WebUI Web Search + web page loading (fallback when answer not in the wiki).
- **docling** — document text extraction (PDF, Office, scanned PDFs with Italian OCR) feeding Open WebUI in-chat file upload and Knowledge Bases (RAG). CPU image, self-hosted, local-only.
- **openwebui-vector-db** — pgvector (`pgvector/pgvector:pg16`) holding the RAG vector store (in-chat upload + Knowledge Base embeddings). Replaces Open WebUI's default embedded Chroma; selected via `VECTOR_DB=pgvector` + `PGVECTOR_DB_URL` on the `openwebui` service. Same postgres ops/backups as the other DBs.
- **caddy** — TLS reverse proxy. Terminates HTTPS for all `*.rewave.local` hostnames using an internal CA.

### Networking / TLS

All services are reached over HTTPS at `*.rewave.local` hostnames (`oi`, `litellm`, `keycloak`, `n8n`), aliased on the Docker network by Caddy. The Caddy internal CA cert (`caddy/caddy-root.crt`) is mounted into openwebui and n8n and installed into their trust stores so internal service-to-service HTTPS calls (e.g. Open WebUI → Keycloak OIDC) validate. `*.rewave.local` must resolve to the host (hosts file / local DNS).

Port 80 is intentionally not published and HTTP→HTTPS auto-redirect is disabled in the `Caddyfile` because Windows often occupies port 80 — re-enable both when deploying on Ubuntu (see comments in `Caddyfile` and `docker-compose.yml`).

## llm_wiki — the knowledge base (this is the core product)

Open WebUI is configured for **full-context wiki**, not RAG: the entire wiki is concatenated into one bundle and pasted into the `rewave-ai` model's system prompt. Anthropic prompt caching (`cache_control_injection_points` in `litellm-config.yaml`) makes resending the large system prompt cheap.

`llm_wiki/` is an Obsidian-style vault maintained by an LLM. It has its **own `llm_wiki/CLAUDE.md`** describing page schema, ingest/query/lint workflows, and `[[wikilink]]` conventions — **read that file before touching anything under `llm_wiki/`**. Key invariant: never edit `llm_wiki/raw/` (immutable sources); the LLM owns only the `wiki/` layer, `index.md`, and `log.md`.

### Maintenance loop

When wiki content changes, push it to the live chat model:

```powershell
# Regenerate bundle AND patch the rewave-ai system prompt via Open WebUI API
pwsh -File .\scripts\refresh_wiki.ps1

# Just rebuild the bundle (llm_wiki/_bundle.md), no API call
pwsh -File .\scripts\bundle_wiki.ps1

# Patch the model when the bundle is already current
pwsh -File .\scripts\refresh_wiki.ps1 -SkipBundle
```

- `bundle_wiki.ps1` concatenates `CLAUDE.md` + `index.md` + `log.md` + `wiki/**` (path-sorted) into `llm_wiki/_bundle.md`, warning if it nears the ~180k-token Sonnet limit.
- `refresh_wiki.ps1` GETs model `rewave-ai`, replaces the text between `=====BEGIN WIKI=====` / `=====END WIKI=====` markers in its system prompt with the fresh bundle, and POSTs it back. Both scripts auto-load `.env` from repo root for `OPENWEBUI_URL` / `OPENWEBUI_API_KEY` / `OPENWEBUI_MODEL_ID`.

If the bundle outgrows Sonnet's context, switch the `claude-sonnet` mapping in `litellm-config.yaml` to an Opus 1M-context model.

## Documents, Knowledge Bases, prompt presets & functions

Beyond the full-context wiki, Open WebUI also does conventional RAG for user content:

- **In-chat upload** and **Knowledge Bases** ("Conoscenza") extract text via the **docling** service and index it with a local multilingual (Italian) embedding model; hybrid search (BM25 + vector) is on. Config is env on the `openwebui` service in `docker-compose.yml` (`CONTENT_EXTRACTION_ENGINE`, `DOCLING_SERVER_URL`, `RAG_EMBEDDING_MODEL`, `RAG_TOP_K`, `ENABLE_RAG_HYBRID_SEARCH`, `USER_PERMISSIONS_WORKSPACE_KNOWLEDGE_*`). These are **PersistentConfig**: env seeds a fresh DB only; change them in the Admin UI afterwards. Embeddings persist in **pgvector** (`openwebui-vector-db` service, `VECTOR_DB=pgvector`), not the default embedded Chroma. Switching the vector backend or `RAG_EMBEDDING_MODEL` does **not** migrate existing vectors — content must be re-indexed (re-upload).
- **Folder → Knowledge Base sync** mirrors local folders into KBs so users can ask questions over a whole document set and search it by content. `scripts/sync_documenti.ps1` reads two positionally-paired lists from `.env` (`SYNC_FOLDERS=path1;path2`, `SYNC_KB_NAMES=kb1;kb2`), and for each pair uploads every file (extensions in `SYNC_EXTENSIONS`, default PDF/Office/images) to the KB via API — creating the KB if missing. Uploads are **synchronous** (`POST /api/v1/files/?process_in_background=false`) so docling extraction finishes before `knowledge/{id}/file/add` (otherwise "content empty"). Incremental: a per-KB state file under `.sync_state/` (gitignored) maps each local file → uploaded `file_id` + SHA256; re-runs skip unchanged, re-upload changed (old copy removed first), and remove files deleted locally. Note: `knowledge/{id}/file/remove` also deletes the underlying file, and in OWUI v0.9.6 `GET /knowledge/{id}` returns `files=null`, so the script trusts the local state, not the live KB. **KBs are deliberately not attached to any model** — users pull a KB into a chat on demand with `#kbname` (keeps per-KB access control enforced); set KB access in the UI (Knowledge > Access). Same `.env` auto-load as `refresh_wiki.ps1`. Flags: `-WhatIf`, `-Full` (ignore state), `-Only <kb>`.
- **Prompt presets** are shared `/command` prompts (public). They are DB rows, not env-seeded — create/update them with `scripts/seed_prompts.ps1` (idempotent; same `.env` auto-load as `refresh_wiki.ps1`). Includes `/presentazione`, which has the model emit a self-contained reveal.js HTML deck.
- **New-chat prompt suggestions** (the "Suggerito" cards on an empty chat) are a global admin config. The `DEFAULT_PROMPT_SUGGESTIONS` env on the `openwebui` service is **PersistentConfig** so it only seeds a fresh DB; on an existing DB set them with `scripts/seed_suggestions.ps1` (idempotent, overwrites the whole list via `POST /api/v1/configs/suggestions`; same `.env` auto-load).
- **Custom functions** live in `functions/` (Python) and are also DB rows — install/update them with `scripts/seed_functions.ps1` (idempotent: creates/refreshes code, sets `is_active` + `is_global` so they apply to `rewave-ai` without per-model assignment; OWUI loads the code live, no restart). Current: `functions/esporta_pdf.py`, a global **outlet filter** that auto-renders a `/presentazione` reveal.js reply to a branded landscape PDF via the **playwright** service (`ws://playwright:3000`; `playwright` is already in the openwebui image, no extra deps), stores it via the Files API, and **replaces the message** with just the title + a download link. So a redeploy needs only the four seed scripts (`refresh_wiki` + `seed_prompts` + `seed_suggestions` + `seed_functions`) — no Admin UI clicks.
- Full Ubuntu procedure: `DEPLOY.md`. End-user guide (Italian): `GUIDA_UTENTI.md`.

## Common operations

```powershell
docker compose up -d                      # start whole stack
docker compose logs -f openwebui          # tail one service
docker compose restart litellm            # reload after editing litellm-config.yaml
docker compose down                        # stop (volumes persist)
```

- After editing `litellm-config.yaml` → restart `litellm`.
- After editing `caddy/Caddyfile` → restart `caddy`.
- Most `docker-compose.yml` env changes → `docker compose up -d` re-creates only changed containers.

## Conventions

- All config + secrets live in `.env` (gitignored) and are interpolated into `docker-compose.yml`. There is no other config source. `.env` holds **live production secrets** (provider API keys, Keycloak/DB passwords, mail credentials) — handle accordingly.
- All comments in every file (code, config, `.env`, `.gitignore`, READMEs, commit messages) must be written in **English**. When you edit an area that still has old Italian comments, translate them to English. Only the end-user guide (`GUIDA_UTENTI.md`) stays Italian.
- Critical config files (`docker-compose.yml`, `litellm-config.yaml`, `Caddyfile`, `.env`): propose changes as diffs for the user to apply rather than editing directly.
