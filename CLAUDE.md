# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Self-hosted **Open WebUI** deployment for Rewave Srl (cartotecnica). Not a fork of Open WebUI source — this repo is the **orchestration layer**: a Docker Compose stack plus an LLM-maintained knowledge base (`llm_wiki/`) that is injected into the chat model as a full-context system prompt instead of RAG.

The whole product is configured through `docker-compose.yml` + `.env`. There is no application code to build; "deploying" means `docker compose up`.

## Stack architecture

Single Compose network (`openwebui-network`). Services:

- **openwebui** — chat frontend. Talks to LLMs through LiteLLM (`OPENAI_API_BASE_URL: http://litellm:4000/v1`) **and** the RouteLLM router (a second OpenAI connection at `http://routellm:6060/v1`); Ollama API disabled. Exposes a single model `rewave-ai` to users (`DEFAULT_MODELS`); `rewave-ai`'s **base model is the RouteLLM router** (`router-bert-<threshold>`), so every chat is routed weak/strong per request. Background tasks (title / tag / follow-up generation) use a fixed **Task Model = `claude-haiku`** (Admin → Settings → Interface) so they don't go through the router or hit the strong model. Auth is SSO-only (login form + signup disabled, Keycloak required).
- **litellm** (+ **litellm-db** postgres) — unified proxy for all model providers. Config in `litellm-config.yaml`. Maps friendly names to real provider models, holds provider API keys, retries, and Langfuse logging. Models: `claude-sonnet` (`anthropic/claude-sonnet-4-6`, **strong** tier) and `claude-haiku` (`anthropic/claude-haiku-4-5`, **weak** tier) — both carry `cache_control_injection_points` (wiki prompt caching) and `additional_drop_params: ["top_p"]` (RouteLLM always injects `top_p`, which Anthropic rejects together with `temperature`). Global `litellm_settings.drop_params: true` strips other unsupported params (e.g. `presence_penalty`/`frequency_penalty`). `general_settings.store_prompts_in_spend_logs: true` persists request/response in the spend-logs DB for debugging (privacy: stores chat content in litellm-db). An optional admin-only `gemma3-4b` (Ollama on the host via `host.docker.internal:11434`, outside Docker) may remain for testing but is **not** used for routing — a local CPU model can't prefill the full-context wiki fast enough (see **routellm**).
- **routellm** — complexity router (LM-SYS RouteLLM, built from `routellm/Dockerfile`, OpenAI-compatible on `:6060`, internal only). For each request the local **`bert`** classifier scores the **last user message** and routes simple ones to the weak model (`claude-haiku`) and complex ones to the strong model (`claude-sonnet`), both reached back **through LiteLLM** (so caching + param-drops apply). The threshold is baked into the model id `router-bert-<threshold>` (higher → more to weak); recalibrate with `routellm.calibrate_threshold` (needs the `[eval]` extra). Routing on the *last user message* means the full-context wiki in the system prompt does not skew classification. The weak tier is **cloud Haiku, not local**, because a CPU Ollama model needs minutes to prefill the wiki and has no prompt caching — making local routing slower and pricier than Haiku. Reaches LiteLLM via `OPENAI_API_BASE`/`OPENAI_API_KEY` env (the LiteLLM master key). **Two routing traps** (in DEPLOY.md Phase 9 + Phase 10): (1) `router-bert-<threshold>` must be **Public** in Open WebUI — it's `rewave-ai`'s base model and OWUI resolves the base with the *user's* permissions (Private → non-admins get `model not found`); the router's targets `claude-sonnet`/`claude-haiku` stay Private (called server-side via the master key). (2) **Web Search must not be a Default Feature** on `rewave-ai`: with it (or any retrieved context / citations) active, OWUI wraps every message in a long `### Task: … using the provided context …` template, which becomes `messages[-1]` — so RouteLLM scores every query as complex and routes everything to Sonnet. Keep web search as an on-demand capability (per-chat toggle); citations are fine (passive). `#kb`/file queries likewise get the template → Sonnet (appropriate).
- **keycloak** (+ **keycloak-db** postgres) — identity provider for SSO. Realm `openwebui-rewave`, client `openwebui`. Roles from `realm_access.roles` map to Open WebUI user/admin.
- **playwright** — headless browser backend for Open WebUI Web Search + web page loading (fallback when answer not in the wiki).
- **docling** — document text extraction (PDF, Office, scanned PDFs with Italian OCR) feeding Open WebUI in-chat file upload and Knowledge Bases (RAG). CPU image, self-hosted, local-only.
- **openwebui-vector-db** — pgvector (`pgvector/pgvector:pg16`) holding the RAG vector store (in-chat upload + Knowledge Base embeddings). Replaces Open WebUI's default embedded Chroma; selected via `VECTOR_DB=pgvector` + `PGVECTOR_DB_URL` on the `openwebui` service. Same postgres ops/backups as the other DBs.
- **caddy** — TLS reverse proxy. Terminates HTTPS for all `*.rewave.local` hostnames using an internal CA.

### Networking / TLS

All services are reached over HTTPS at `*.rewave.local` hostnames (`oi`, `litellm`, `keycloak`), aliased on the Docker network by Caddy. The Caddy internal CA cert (`caddy/caddy-root.crt`) is mounted into openwebui and installed into its trust store so internal service-to-service HTTPS calls (e.g. Open WebUI → Keycloak OIDC) validate. `*.rewave.local` must resolve to the host (hosts file / local DNS).

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

### Removing the wiki from the model

The wiki is **not required** — it just lives between the `=====BEGIN WIKI=====` / `=====END WIKI=====` markers in the `rewave-ai` system prompt. To run the assistant without it (e.g. before the wiki is ready, or to fall back to RAG + web search only), an admin clears that block. There is no remove script — it is a manual edit:

- **Admin UI** (simplest): Open WebUI → **Admin Panel → Models → `rewave-ai` → System Prompt**. Delete everything from `=====BEGIN WIKI=====` to `=====END WIKI=====` (keep the rest of the prompt, including the 3-source instructions). Save. The change is live immediately — no restart.
- Optionally leave the two empty markers in place; the next `refresh_wiki.ps1` run will refill them, so this is the cleanest way to re-enable the wiki later (run the maintenance loop again).

Removing the wiki only affects the live model's system prompt; the `llm_wiki/` files and `_bundle.md` on disk are untouched and can be re-pushed any time.

## Documents, Knowledge Bases & functions

Beyond the full-context wiki, Open WebUI also does conventional RAG for user content:

- **In-chat upload** and **Knowledge Bases** ("Conoscenza") extract text via the **docling** service and index it with a local multilingual (Italian) embedding model; hybrid search (BM25 + vector) is on. Config is env on the `openwebui` service in `docker-compose.yml` (`CONTENT_EXTRACTION_ENGINE`, `DOCLING_SERVER_URL`, `RAG_EMBEDDING_MODEL`, `RAG_TOP_K`, `ENABLE_RAG_HYBRID_SEARCH`, `USER_PERMISSIONS_WORKSPACE_KNOWLEDGE_*`). These are **PersistentConfig**: env seeds a fresh DB only; change them in the Admin UI afterwards. Embeddings persist in **pgvector** (`openwebui-vector-db` service, `VECTOR_DB=pgvector`), not the default embedded Chroma. Switching the vector backend or `RAG_EMBEDDING_MODEL` does **not** migrate existing vectors — content must be re-indexed (re-upload).
- **New-chat prompt suggestions** (the "Suggerito" cards on an empty chat) are a global admin config. The `DEFAULT_PROMPT_SUGGESTIONS` env on the `openwebui` service is **PersistentConfig** so it only seeds a fresh DB; on an existing DB set them with `scripts/seed_suggestions.ps1` (idempotent, overwrites the whole list via `POST /api/v1/configs/suggestions`; same `.env` auto-load).
- **Custom functions** live in `functions/` (Python) and are also DB rows — install/update them with `scripts/seed_functions.ps1` (idempotent: creates/refreshes code, sets `is_active` + `is_global` so they apply to `rewave-ai` without per-model assignment; OWUI loads the code live, no restart). Current: `functions/esporta_pdf.py`, a global **outlet filter** that triggers on any reply containing a reveal.js deck (`<div class="reveal">`), renders it to a branded landscape PDF via the **playwright** service (`ws://playwright:3000`; `playwright` is already in the openwebui image, no extra deps), stores it via the Files API, and **replaces the message** with just the title + a download link. Ask for a presentation in natural language — no slash command needed. So a redeploy needs only the seed scripts — no Admin UI clicks.
- **Model bootstrap** — `rewave-ai` is set up manually via Admin Panel (DEPLOY.md Phase 10, steps 25–31): RouteLLM connection, model creation with 3-source system prompt + empty wiki markers, params (`temp 0.2`, `max_tokens 4096`, **`function_calling=native`** — required for tool calling, do not remove), capabilities, Default Features off (web_search-as-default stays off — routing trap), visibility (`rewave-ai` + router Public; claude-sonnet/haiku/gemma3-4b Private via `access_grant` table). After: `refresh_wiki.ps1` injects the bundle between the markers.
- **Client PC setup** — `scripts/provision_user_pc.ps1` configures a Windows user PC to reach Open WebUI: updates the hosts file (`*.rewave.local` → server IP) and installs the Caddy CA cert into the Windows Trusted Root store. Run once per PC, elevated. See DEPLOY.md Phase 2 (Option A1) and Phase 6.
- Full from-scratch model setup: Phase 10 (Admin UI) → `refresh_wiki.ps1` → `seed_suggestions.ps1` → `seed_functions.ps1`.
- Full Ubuntu procedure: `DEPLOY.md`. End-user guide (Italian): `GUIDA_UTENTI.md`.

## Local file access (optional, currently OFF)

Beyond in-chat upload and Knowledge Bases, the assistant can be given access to a **shared host folder** (a company directory) so it can browse, read, and answer about the files in it. Two approaches were built and evaluated; **neither is enabled now** — both were removed after testing. The `LOCAL_FILES_PATH` var in `.env` (host folder to expose) is the shared input to either; it is unused until one is re-enabled. Docling stays regardless (it serves KB/RAG).

- **Open Terminal** (`ghcr.io/open-webui/open-terminal`) — gives the model a **real shell + sidebar file browser**. It can read **and write/compute** on files: modern Office (openpyxl/python-docx/python-pptx), PDF (pypdf), legacy Office (libreoffice), scans/images (tesseract OCR-ita) — all baked into a custom image. Connected via Admin → Integrations → Open Terminal; needs the model's `terminal` capability ON. **Most powerful, but the model has arbitrary code execution on real files**, so it must be hardened (non-root, isolated `internal` network with no DB/internet reach, `cap_drop`, resource limits). System-prompt guidance: extract text via the shell, reason over it with the LLM, but do exact math (totals/counts) with a script, not LLM arithmetic. Downsides: the file/terminal panel and the per-chat terminal selector (☁) cannot be hidden or auto-attached per role (no native setting).
- **mcpo** (MCPO proxy + `@modelcontextprotocol/server-filesystem`) — exposes a **fixed, bounded set of file tools** (list/read/write/search) as an OWUI **Tool Server** (URL must be `http://mcpo:8000/filesystem` — tools live under the server prefix). Binary docs (PDF/Office) need a companion OWUI Tool (`read_document`) that pipes the file to **docling** for extraction. **Safer and deterministic, no shell, no UI panel**, but weak at *writing/editing* Office files.

Rule of thumb: **read + Q&A → mcpo** (bounded, safe); **the model must also edit/compute on files → Open Terminal** (powerful, needs hardening). Shared gotchas for either (tool calling through RouteLLM): RouteLLM 0.2.0 rejects nested tool schemas → patched in `routellm/Dockerfile`; `rewave-ai` must keep `function_calling=native` (saving the model in Workspace UI reverts it and the system prompt — reload the page first); and the system prompt must tell the model it *has* file access or it refuses.

## Common operations

```powershell
docker compose up -d                      # start whole stack
docker compose logs -f openwebui          # tail one service
docker compose restart litellm            # reload after editing litellm-config.yaml
docker compose down                        # stop (volumes persist)
```

- After editing `litellm-config.yaml` → restart `litellm`.
- After editing `routellm/Dockerfile` (router type, weak/strong model, default threshold) → `docker compose up -d --build routellm`.
- After editing `caddy/Caddyfile` → restart `caddy`.
- Most `docker-compose.yml` env changes → `docker compose up -d` re-creates only changed containers.
- Ollama model residency: how long a local model stays in host RAM after the last request is controlled by `keep_alive` (per-model in `litellm-config.yaml` under `litellm_params`, preferred) or the host `OLLAMA_KEEP_ALIVE` env. Raise it to skip the weight reload + system-prompt prefill on each cold start (slower the larger the wiki) on CPU-only hosts; lower it (or keep the `5m` default) under memory pressure. See DEPLOY.md Phase 14.

## Conventions

- All config + secrets live in `.env` (gitignored) and are interpolated into `docker-compose.yml`. There is no other config source. `.env` holds **live production secrets** (provider API keys, Keycloak/DB passwords) — handle accordingly.
- All comments in every file (code, config, `.env`, `.gitignore`, READMEs, commit messages) must be written in **English**. When you edit an area that still has old Italian comments, translate them to English. Only the end-user guide (`GUIDA_UTENTI.md`) stays Italian.
- Critical config files (`docker-compose.yml`, `litellm-config.yaml`, `Caddyfile`, `.env`): propose changes as diffs for the user to apply rather than editing directly.
