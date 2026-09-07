# Open WebUI — Rewave Srl

Self-hosted **Open WebUI** deployment for Rewave Srl (cartotecnica).

This repo is **not a fork** of the Open WebUI source: it is the **orchestration layer** — a Docker Compose stack plus an LLM-maintained knowledge base (`llm_wiki/`) injected into the model as a full-context system prompt instead of RAG.

There is no application code to build: "deploying" means `docker compose up`.

## Stack architecture

Single Compose network (`openwebui-network`). Services:

- **openwebui** — chat frontend. Talks to LLMs through LiteLLM and the RouteLLM router. Exposes a single model `rewave-ai` (whose base model is the router). Auth is SSO-only (Keycloak).
- **litellm** (+ **litellm-db**) — unified proxy for all providers. Config in `litellm-config.yaml`. Holds API keys, retries, Langfuse logging. Exposes `claude-sonnet` (strong) and `claude-haiku` (weak) — the two tiers RouteLLM picks between — plus an optional admin-only local `gemma3-4b` (Ollama on the host via `host.docker.internal:11434`, not used for routing).
- **routellm** — per-request complexity router (LM-SYS RouteLLM). `rewave-ai`'s base model; sends simple queries to `claude-haiku` and complex ones to `claude-sonnet`, both via LiteLLM. See `routellm/README.md`.
- **keycloak** (+ **keycloak-db**) — SSO identity provider. Realm `openwebui-rewave`, client `openwebui`.
- **playwright** — headless browser for Web Search / web loading.
- **docling** — document text extraction (PDF, Office, scans with Italian OCR) for in-chat file upload and Knowledge Bases. CPU image, self-hosted, local-only.
- **caddy** — TLS reverse proxy. Terminates HTTPS for `*.rewave.local` hostnames with an internal CA.

### Networking / TLS

All services are reached over HTTPS at `*.rewave.local` (`oi`, `litellm`, `keycloak`), aliased on the Docker network by Caddy. The Caddy internal CA is mounted into openwebui to validate internal service-to-service HTTPS calls. `*.rewave.local` must resolve to the host (hosts file / local DNS).

On Windows, port 80 is not published and the HTTP→HTTPS redirect is disabled (Windows often occupies port 80) — re-enable both on Ubuntu (see comments in `Caddyfile` and `docker-compose.yml`).

## Features

What users get in the chat. Disabled / admin-only features are listed last.

| Feature | Status | Notes |
|---|---|---|
| Assistant `rewave-ai` (routed Haiku/Sonnet) | ✅ active | the single model exposed to users; RouteLLM picks weak (Haiku) or strong (Sonnet) per request |
| `llm_wiki` full-context knowledge | ✅ active | core product; injected into the system prompt |
| Documents in chat (upload) | ✅ active | docling extraction + Italian OCR |
| Knowledge Bases / RAG (hybrid search) | ✅ active | user-created, shareable to groups |
| PDF presentations | ✅ active | `esporta_pdf` filter: whenever a reply contains a reveal.js deck, auto-renders to PDF and appends a download link; seeded via `seed_functions.ps1` |
| Web search | ✅ active | DuckDuckGo + Playwright |
| Vision (image analysis) | ✅ active | model capability |
| Calculations & dates | ✅ active | `Time & Calculation` builtin tool — reliable math / date arithmetic |
| Citations / sources | ✅ active | shown for wiki / web / documents |
| SSO login (Keycloak) | ✅ active | only authentication method |
| Request routing (RouteLLM) | ✅ active | weak/strong per request; threshold in the `router-bert-<n>` model id. **Web Search must stay off as a Default Feature** or every query gets wrapped in a context template and routes to Sonnet (see DEPLOY Phase 14) |
| `router-bert-<n>` (router) | Public | `rewave-ai`'s base model — must be Public so non-admins can resolve it |
| `claude-sonnet` / `claude-haiku` | 🔒 admin-only | router targets; called server-side via the master key, kept Private |
| `gemma3-4b` local model | 🔒 admin-only | needs Ollama on the host (optional; not used for routing) |

How to change these: see *Optional & disabled features* in [DEPLOY.md](DEPLOY.md).

## Setup

**Prerequisite:** create a `.env` file in the repo root (gitignored — never committed).
It must contain at minimum:

```
ANTHROPIC_API_KEY=...
LITELLM_MASTER_KEY=...
WEBUI_SECRET_KEY=...
OAUTH_CLIENT_ID=...
OAUTH_CLIENT_SECRET=...
OPENID_PROVIDER_URL=...
OPENID_REDIRECT_URI=...
KEYCLOAK_ADMIN=...
KEYCLOAK_ADMIN_PASSWORD=...
KEYCLOAK_DB_PASSWORD=...
LITELLM_DB_PASSWORD=...
OWUI_VECTOR_DB_PASSWORD=...   # hex only — must be URL-safe
OPENWEBUI_URL=...             # for maintenance scripts (refresh_wiki, seed_*)
OPENWEBUI_API_KEY=...         # admin API key, minted after first boot
```

Then start the stack:

```powershell
docker compose up -d
```

> All config is interpolated from `.env` into `docker-compose.yml`. The file holds live production secrets — handle accordingly.

> The entire `llm_wiki/` directory (proprietary KB, third-party PDF sources, and the vault's own `CLAUDE.md`) is excluded from the repo — the vault is recreated per deployment.

## Deploying on a new instance

See **[DEPLOY.md](DEPLOY.md)** for the full step-by-step guide. The first section
("Exporting from an existing instance") covers how to export the `rewave-ai` model,
functions, prompt presets, and the Keycloak realm from the current instance before
migrating.

## Client PC setup

Each user PC needs two things before the browser can reach Open WebUI:
1. **Hostname resolution** — `*.rewave.local` must point to the server IP
2. **CA certificate** — the Caddy internal CA must be trusted so HTTPS works without warnings

Run once per PC from an elevated PowerShell (Administrator):
```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\provision_user_pc.ps1 -ServerIP <server-ip>
```
The script is idempotent (safe to re-run) and handles both steps. It requires
`caddy\caddy-root.crt` — copy it from the server first (`scp admin@<server>:~/openwebui-rewave/caddy/caddy-root.crt .\caddy\`).
For manual steps and Firefox notes see DEPLOY.md Phase 2 (Option A) and Phase 6.

## Common operations

```powershell
docker compose up -d                      # start the whole stack
docker compose logs -f openwebui          # tail one service
docker compose restart litellm            # reload after editing litellm-config.yaml
docker compose down                       # stop (volumes persist)
```

- After editing `litellm-config.yaml` → `docker compose restart litellm`
- After editing `routellm/Dockerfile` → `docker compose up -d --build routellm`
- After editing `caddy/Caddyfile` → `docker compose restart caddy`
- Env changes in `docker-compose.yml` → `docker compose up -d` re-creates only changed containers

## Document and knowledge management

The assistant draws on company knowledge in three complementary ways. Choose based
on how permanent and how broadly the information needs to be available:

| Method | Scope | Always in context? | Owner | When to use |
|---|---|---|---|---|
| **In-chat upload** | One chat session | No — only that chat | Any user, ad hoc | One-off questions on a specific document |
| **Knowledge Bases (RAG)** | One department / group | No — retrieved on demand with `#name` | Department users | Many documents, volatile, department-specific |
| **`llm_wiki`** (full-context) | Whole company | Yes — always in the system prompt | Admin + Claude Code | Stable, curated knowledge every answer should know |

In-chat upload and Knowledge Bases both go through **docling** (PDF / Office /
scanned PDFs with Italian OCR) and a local multilingual embedding model, with
embeddings stored in **pgvector**. Changing the embedding model or vector backend
after documents are indexed requires re-uploading everything.

End-user guide (Italian): **[GUIDA_UTENTI.md](GUIDA_UTENTI.md)**.

---

### 1. In-chat document upload

Upload a document directly into a chat session. The model reads its content for
the duration of that conversation only — nothing is stored permanently in a
Knowledge Base.

**How to upload:**
1. Open a new chat with `rewave-ai`.
2. Click the **paperclip / `+` icon** in the message input area.
3. Select one or more files from your PC.
4. The file is uploaded, sent to docling for text extraction, and attached to your
   message. A file icon appears in the input box.
5. Write your question and send. The model answers using the document content.

**Supported formats:** PDF (native text or scanned), Word (.docx), Excel (.xlsx),
PowerPoint (.pptx), plain text (.txt, .md, .csv). Docling runs OCR automatically
on scanned PDFs (Italian + Latin text optimized).

**Not supported for text extraction:** PNG, JPG, and other image formats are
accepted for **vision** (the model can look at them) but are **not** OCR'd for
RAG/extraction. For scanned documents always use PDF, not images.

**Limits:** 50 MB per file, up to 10 files per chat (configured in
`docker-compose.yml` via `RAG_FILE_MAX_SIZE` / `RAG_FILE_MAX_COUNT`).

**Scope:** the document is available only for that chat. It is not indexed into
any Knowledge Base and cannot be searched or shared. When you close the chat, the
content is no longer in context.

**When to use:** extracting data from a specific invoice or contract, summarizing
a one-off report, asking questions about a document you received today.

---

### 2. Knowledge Bases (RAG)

A Knowledge Base ("Conoscenza" in the UI) is a persistent, searchable collection
of documents. When a user references a KB in a chat with `#name`, Open WebUI
retrieves the most relevant chunks (hybrid BM25 + semantic search, top 5) and
injects them into the model's context as citations.

#### Create a Knowledge Base

1. **Workspace → Knowledge → +**
2. Fill in **Name** (this becomes the `#name` you type in chat — keep it short,
   no spaces) and an optional **Description**.
3. Click **Create**.

#### Add documents

1. Open the Knowledge Base → click **+** or drag and drop files.
2. Each file is sent to docling for extraction and then embedded. Wait until the
   status indicator shows **Indexed** before using the KB in a chat.
3. To add more files later, open the KB and repeat.

> Extraction can take a minute per document depending on file size and whether
> OCR is needed. Large batches: add a few at a time and wait between batches.

**Supported formats:** same as in-chat upload (PDF, Office, text). PNG/JPG are
not accepted for RAG.

#### Use a Knowledge Base in a chat

In the message input box type `#` followed by the KB name (e.g. `#fatture`).
Open WebUI shows a dropdown — select the KB. Then type your question and send.
The model answers with citations from the KB content.

You can reference multiple KBs in the same message (`#fatture #contratti`).

#### Share a Knowledge Base

By default a KB is private (only the creator can see it).

1. Open the KB → **Access** (top-right or in the KB settings).
2. Choose **Private** (only you), or share with specific **users** or **groups**.
   Groups must exist first (Admin Panel → Users → Groups).
3. Users with access can see and query the KB; they cannot add or remove documents
   unless you also give them write access.

> Public sharing is disabled by default (`USER_PERMISSIONS_WORKSPACE_KNOWLEDGE_ALLOW_PUBLIC_SHARING=false`).
> Enable it in Admin Panel → Users → Groups → Default Permissions → Workspace if needed.

#### Re-indexing

If the server is migrated to a new embedding model or vector backend, all
existing KB content must be re-uploaded — embeddings are not portable across
models. Delete the documents in the KB and re-add them.

**When to use:** department invoice archive, product catalog, recurring reference
material that multiple users need to query on demand.

---

### 3. LLM wiki (full-context)

The `llm_wiki/` folder is an Obsidian-style vault maintained by an LLM (Claude
Code). Its entire content is concatenated into a single bundle and injected into
the `rewave-ai` system prompt on every request — it is **always in context**,
with no retrieval step. Anthropic prompt caching makes resending the large prompt
cheap.

This is the core product: the wiki is what makes `rewave-ai` knowledgeable about
Rewave specifically, without users having to attach documents to every chat.

#### Folder structure

```
llm_wiki/
  CLAUDE.md        # schema and conventions (read before touching anything)
  index.md         # catalog of all wiki pages — one line per page
  log.md           # append-only record of changes
  raw/             # immutable source documents (PDFs, exports) — NEVER edited
  wiki/            # LLM-maintained knowledge pages — the actual content
  _bundle.md       # GENERATED — never edit by hand
```

**Rule:** `raw/` is read-only. The LLM reads sources from there and writes
synthesized knowledge into `wiki/`. Never edit `raw/` files; never hand-edit
`_bundle.md`.

#### Add source documents

1. Copy the source file (PDF, Word, export, etc.) into `llm_wiki/raw/`. Use a
   descriptive filename, e.g. `listino-prezzi-2025.pdf`.
2. Open Claude Code in the repo root.
3. Ask Claude to ingest the document: _"Aggiungi `llm_wiki/raw/listino-prezzi-2025.pdf`
   alla wiki. Leggi prima `llm_wiki/CLAUDE.md` per le convenzioni."_
4. Claude reads the source, creates or updates pages in `wiki/`, updates
   `index.md` and `log.md`.
5. Review the changes (git diff), then sync to the live model (see below).

#### Sync wiki changes to the live model

After any content change in `llm_wiki/`, run:

```powershell
# Regenerate bundle AND push to the rewave-ai system prompt via API
pwsh -File .\scripts\refresh_wiki.ps1

# Rebuild bundle only (llm_wiki/_bundle.md) — no API call
pwsh -File .\scripts\bundle_wiki.ps1

# Push to model when bundle is already current (skip rebuild)
pwsh -File .\scripts\refresh_wiki.ps1 -SkipBundle
```

`bundle_wiki.ps1` concatenates `CLAUDE.md` + `index.md` + `log.md` + all
`wiki/**` pages (path-sorted) into `_bundle.md`. `refresh_wiki.ps1` then GETs
the `rewave-ai` model, replaces everything between the `=====BEGIN WIKI=====` /
`=====END WIKI=====` markers in its system prompt with the new bundle, and POSTs
it back. The change is live immediately — no restart needed.

Both scripts auto-load `.env` for `OPENWEBUI_URL` / `OPENWEBUI_API_KEY`.

#### Size limit

The bundle must stay under ~180k tokens (Sonnet context limit). `bundle_wiki.ps1`
warns when approaching it. If it exceeds the limit, switch the `claude-sonnet`
mapping in `litellm-config.yaml` to `anthropic/claude-opus-4-8` (1M context) and
restart litellm.

#### Remove the wiki from the model

To run the assistant without the wiki (e.g. before it is ready, or to fall back
to RAG + web search only):

**Admin UI:** Admin Panel → Models → `rewave-ai` → System Prompt → delete
everything between `=====BEGIN WIKI=====` and `=====END WIKI=====` (leave the
rest of the prompt). Save. Effective immediately.

Leave the two empty markers in place so the next `refresh_wiki.ps1` run refills
them automatically.

**When to use:** stable, curated company knowledge — client names and contacts,
products and pricing, internal processes, decisions, market context. Anything
that should be in every answer without users having to remember to attach it.

## Custom functions

Python functions in `functions/` are DB rows — install/update via the API script
(idempotent; sets `is_active` + `is_global` so they apply to `rewave-ai` with no
per-model assignment, loaded live without a restart):

```powershell
pwsh -File .\scripts\seed_functions.ps1
```

### `esporta_pdf` — Presentazione PDF

Global **outlet filter** (`functions/esporta_pdf.py`). Triggers on any assistant
reply containing a reveal.js deck (`<div class="reveal">`). Renders each
`<section>` as a landscape A4 page to PDF via the `playwright` service
(`ws://playwright:3000`), stores the file via the Files API, and **replaces the
entire message** with just the deck title + a "📄 Scarica la presentazione (PDF)"
download link. No button, no click — fires automatically at the end of the reply.

Ask for a presentation in natural language (e.g. "genera una presentazione su X in 5 slide") — no slash command needed.

**Manual import on a new instance** (alternative to `seed_functions.ps1`):
1. Open WebUI → **Admin Panel → Functions → +**
2. Paste the contents of `functions/esporta_pdf.py`
3. Save → toggle **Active** ON → toggle **Global** ON

Global = the filter runs for every model, not just `rewave-ai`. If you only want it
for `rewave-ai`, skip Global and attach it under Admin Panel → Models → `rewave-ai`
→ Functions tab.

**Requirements:** the `playwright` service must be running (`docker compose ps playwright`).
No extra Python deps — the openwebui image already ships the matching `playwright` version.

## Prompt presets (slash commands)

Prompt presets are reusable templates that appear in the `/` menu when typing in
the chat box. Users pick one and the text is pre-filled into the input. They are
stored as DB rows — not version-controlled — and are created/managed entirely
from the UI.

### Create a preset

**Workspace → Prompts → +**

| Field | Notes |
|---|---|
| **Command** | the slash trigger, e.g. `riassumi` (no `/` prefix, lowercase, no spaces) |
| **Title** | display name shown in the `/` menu |
| **Content** | the template text pre-filled into the input box |

In the content, use `{{placeholder}}` for parts the user fills in — OWUI renders
these as editable fields before submitting. Example:

```
Riassumi il seguente testo in massimo {{numero}} punti:

{{testo}}
```

**Visibility:** set to **Public** so all users see it; Private = only you.

### Edit / delete

Workspace → Prompts → click the preset → edit inline or delete.
Admins can see and manage all public presets.

### Notes
- Presets are global config, not per-model — they appear for every model the user
  has access to.
- They are **not migrated** when redeploying on a new instance (empty DB). Re-create
  them manually after a fresh deploy, or re-add them via the
  `POST /api/v1/prompts/create` API if you want to script it.
- Deleting a preset via UI calls `DELETE /api/v1/prompts/id/{command}/delete` — there
  is no bulk-delete; remove them one at a time.

## License

Source-available under the [PolyForm Strict License 1.0.0](LICENSE) — viewing and personal/noncommercial evaluation only. Any other use requires permission from Rewave Srl.
