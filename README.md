# Open WebUI — Rewave Srl

Self-hosted **Open WebUI** deployment for Rewave Srl (cartotecnica).

This repo is **not a fork** of the Open WebUI source: it is the **orchestration layer** — a Docker Compose stack plus an LLM-maintained knowledge base (`llm_wiki/`) injected into the model as a full-context system prompt instead of RAG.

There is no application code to build: "deploying" means `docker compose up`.

## Stack architecture

Single Compose network (`openwebui-network`). Services:

- **openwebui** — chat frontend. Talks to LLMs only through LiteLLM. Exposes a single model `rewave-ai`. Auth is SSO-only (Keycloak).
- **litellm** (+ **litellm-db**) — unified proxy for all providers. Config in `litellm-config.yaml`. Holds API keys, cost-based routing, retries, Langfuse logging. Exposes `claude-sonnet` (active, base model of `rewave-ai`) and `llama3.1` (local Ollama, admin-only, optional). Ollama routes to the host via `host.docker.internal:11434`.
- **keycloak** (+ **keycloak-db**) — SSO identity provider. Realm `openwebui-rewave`, client `openwebui`.
- **n8n** (+ **n8n-db**) — workflow automation (email ↔ chat). Runs by default; **admins** reach it at `n8n.rewave.local` (own login) to build/test workflows. The n8n-backed chat tools (`send_email`, `mail_digest`) are **not exposed to base users**.
- **playwright** — headless browser for Web Search / web loading.
- **docling** — document text extraction (PDF, Office, scans with Italian OCR) for in-chat file upload and Knowledge Bases. CPU image, self-hosted, local-only.
- **caddy** — TLS reverse proxy. Terminates HTTPS for `*.rewave.local` hostnames with an internal CA.

### Networking / TLS

All services are reached over HTTPS at `*.rewave.local` (`oi`, `litellm`, `keycloak`, `n8n`), aliased on the Docker network by Caddy. The Caddy internal CA is mounted into openwebui and n8n to validate internal service-to-service HTTPS calls. `*.rewave.local` must resolve to the host (hosts file / local DNS).

On Windows, port 80 is not published and the HTTP→HTTPS redirect is disabled (Windows often occupies port 80) — re-enable both on Ubuntu (see comments in `Caddyfile` and `docker-compose.yml`).

## Features

What users get in the chat. Disabled / admin-only features are listed last.

| Feature | Status | Notes |
|---|---|---|
| Assistant `rewave-ai` (Claude Sonnet) | ✅ active | the single model exposed to users |
| `llm_wiki` full-context knowledge | ✅ active | core product; injected into the system prompt |
| Documents in chat (upload) | ✅ active | docling extraction + Italian OCR |
| Knowledge Bases / RAG (hybrid search) | ✅ active | user-created, shareable to groups |
| Prompt presets (`/commands`) | ✅ active | public; seeded via `seed_prompts.ps1` |
| PDF presentations (`/presentazione`) | ✅ active | `esporta_pdf` filter renders the deck to PDF via Playwright; seeded via `seed_functions.ps1` |
| Web search | ✅ active | DuckDuckGo + Playwright |
| Vision (image analysis) | ✅ active | model capability |
| Calculations & dates | ✅ active | `Time & Calculation` builtin tool — reliable math / date arithmetic |
| Citations / sources | ✅ active | shown for wiki / web / documents |
| SSO login (Keycloak) | ✅ active | only authentication method |
| `llama3.1` local model | 🔒 admin-only | needs Ollama on the host (optional) |
| n8n workflow automation | 🔒 admin-only | admin builds/tests workflows at `n8n.rewave.local` |
| n8n email tools (`send_email`, `mail_digest`) | 🔒 admin-only | admin enables them per chat (tools selector); not exposed to base users |

How to change these: see *Optional & disabled features* in [DEPLOY.md](DEPLOY.md).

## Setup

```powershell
# Start the stack (requires a populated .env in the repo root)
docker compose up -d
```

> `.env` holds **production secrets** (provider API keys, Keycloak/DB passwords, mail credentials) and is gitignored. All config is interpolated from `.env` into `docker-compose.yml`.

> The entire `llm_wiki/` directory (proprietary KB, third-party PDF sources, and the vault's own `CLAUDE.md`) is excluded from the repo — the vault is recreated per deployment.

## Common operations

```powershell
docker compose up -d                      # start the whole stack
docker compose logs -f openwebui          # tail one service
docker compose restart litellm            # reload after editing litellm-config.yaml
docker compose down                       # stop (volumes persist)
```

- After editing `litellm-config.yaml` → `docker compose restart litellm`
- After editing `caddy/Caddyfile` → `docker compose restart caddy`
- Env changes in `docker-compose.yml` → `docker compose up -d` re-creates only changed containers

## Knowledge methods

The assistant draws on company knowledge in three complementary ways:

| Method | Scope | Always in context? | Owner | When to use |
|---|---|---|---|---|
| **`llm_wiki`** (full-context) | Whole company / cartotecnica domain | Yes — pasted into the `rewave-ai` system prompt | Maintained centrally (LLM + admin) | Stable, curated knowledge every answer should know |
| **In-chat upload** | A single chat | No — only that chat | The user, ad hoc | One-off questions on a specific document (extract, summarize) |
| **Knowledge Bases** | A department | No — queried on demand with `#collection` | Department users | Many / volatile / department-specific docs (RAG) |

- **`llm_wiki`** is the core product: an Obsidian-style vault concatenated into one bundle and injected as the system prompt (Anthropic prompt caching keeps it cheap). See the maintenance loop below.
- **In-chat upload** and **Knowledge Bases** run through **docling** (extraction + Italian OCR) and a local multilingual embedding model, with embeddings stored in **pgvector** (`openwebui-vector-db` service) instead of the default embedded Chroma — configured via env on the `openwebui` service in `docker-compose.yml`. Changing `RAG_EMBEDDING_MODEL` (or the vector backend) after documents are indexed requires re-indexing.

End-user guide (Italian): **[GUIDA_UTENTI.md](GUIDA_UTENTI.md)**.

## Wiki maintenance loop

When wiki content changes, push it to the live chat model:

```powershell
# Regenerate bundle AND patch the rewave-ai system prompt via the Open WebUI API
pwsh -File .\scripts\refresh_wiki.ps1

# Rebuild the bundle only (llm_wiki/_bundle.md), no API call
pwsh -File .\scripts\bundle_wiki.ps1

# Patch the model when the bundle is already current
pwsh -File .\scripts\refresh_wiki.ps1 -SkipBundle
```

## Prompt presets

Shared `/command` prompts (e.g. `/riassumi`, `/estrai-fattura`, `/traduci-it`)
are created via the API as **public** (visible to every user). They are DB rows,
not env-seeded — run the script once per instance (idempotent, edit the `$presets`
array to change them):

```powershell
pwsh -File .\scripts\seed_prompts.ps1
```

## Custom functions

Python functions in `functions/` are DB rows too — install/update them via the API
(idempotent; sets `is_active` + `is_global` so they apply to `rewave-ai` with no
per-model assignment, loaded live without a restart):

```powershell
pwsh -File .\scripts\seed_functions.ps1
```

Current: `esporta_pdf` — a global outlet filter that, after a `/presentazione`
reply, renders the reveal.js slides to a branded landscape PDF (via the Playwright
service, no extra deps) and replaces the message with a download link.
