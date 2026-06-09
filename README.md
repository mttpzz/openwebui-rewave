# Open WebUI — Rewave Srl

Self-hosted **Open WebUI** deployment for Rewave Srl (cartotecnica).

This repo is **not a fork** of the Open WebUI source: it is the **orchestration layer** — a Docker Compose stack plus an LLM-maintained knowledge base (`llm_wiki/`) injected into the model as a full-context system prompt instead of RAG.

There is no application code to build: "deploying" means `docker compose up`.

## Stack architecture

Single Compose network (`openwebui-network`). Services:

- **openwebui** — chat frontend. Talks to LLMs only through LiteLLM. Exposes a single model `rewave-ai`. Auth is SSO-only (Keycloak).
- **litellm** (+ **litellm-db**) — unified proxy for all providers. Config in `litellm-config.yaml`. Maps friendly names to real models, holds API keys, cost-based routing, retries, Langfuse logging. Ollama models route to the Windows host via `host.docker.internal:11434`.
- **keycloak** (+ **keycloak-db**) — SSO identity provider. Realm `openwebui-rewave`, client `openwebui`.
- **n8n** (+ **n8n-db**) — workflow automation (email ↔ chat integrations).
- **playwright** — headless browser for Web Search / web loading.
- **caddy** — TLS reverse proxy. Terminates HTTPS for `*.rewave.local` hostnames with an internal CA.

### Networking / TLS

All services are reached over HTTPS at `*.rewave.local` (`oi`, `litellm`, `keycloak`, `n8n`), aliased on the Docker network by Caddy. The Caddy internal CA is mounted into openwebui and n8n to validate internal service-to-service HTTPS calls. `*.rewave.local` must resolve to the host (hosts file / local DNS).

On Windows, port 80 is not published and the HTTP→HTTPS redirect is disabled (Windows often occupies port 80) — re-enable both on Ubuntu (see comments in `Caddyfile` and `docker-compose.yml`).

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
