# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Self-hosted **Open WebUI** deployment for Rewave Srl (cartotecnica). Not a fork of Open WebUI source — this repo is the **orchestration layer**: a Docker Compose stack plus an LLM-maintained knowledge base (`llm_wiki/`) that is injected into the chat model as a full-context system prompt instead of RAG.

The whole product is configured through `docker-compose.yml` + `.env`. There is no application code to build; "deploying" means `docker compose up`.

## Stack architecture

Single Compose network (`openwebui-network`). Services:

- **openwebui** — chat frontend. Talks to LLMs only through LiteLLM (`OPENAI_API_BASE_URL: http://litellm:4000/v1`); Ollama API disabled. Exposes a single model `rewave-ai` to users (`DEFAULT_MODELS`). Auth is SSO-only (login form + signup disabled, Keycloak required).
- **litellm** (+ **litellm-db** postgres) — unified proxy for all model providers. Config in `litellm-config.yaml`. Maps friendly names (`claude-sonnet`, `gpt-4o`, `llama3.1`) to real provider models, holds provider API keys, does cost-based routing, retries, and Langfuse logging. Ollama models route to the **host** Windows machine via `host.docker.internal:11434` (Ollama runs outside Docker).
- **keycloak** (+ **keycloak-db** postgres) — identity provider for SSO. Realm `openwebui-rewave`, client `openwebui`. Roles from `realm_access.roles` map to Open WebUI user/admin.
- **n8n** (+ **n8n-db** postgres) — workflow automation (email ↔ chat integrations). Reads mail accounts/topics from env.
- **playwright** — headless browser backend for Open WebUI Web Search + web page loading (fallback when answer not in the wiki).
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
- Comments and operational notes throughout the stack are in Italian; keep that style when editing config.
- Critical config files (`docker-compose.yml`, `litellm-config.yaml`, `Caddyfile`, `.env`): propose changes as diffs for the user to apply rather than editing directly.
