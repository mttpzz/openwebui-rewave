# llm_wiki — creating the knowledge base

This folder holds the LLM-maintained knowledge base (an Obsidian-style vault)
that is concatenated into a single bundle and injected into the `rewave-ai`
model as a **full-context system prompt** (not RAG).

**Its content is intentionally excluded from the repo** (see `.gitignore`):
proprietary company KB plus copyrighted third-party PDF sources. Only this
`README.md` is tracked, so the empty folder ships with the repo. The vault is
**recreated per deployment** following the steps below.

Target layout once populated:

```
llm_wiki/
├── CLAUDE.md     # vault schema / ingest-query-lint workflow / wikilink conventions
├── index.md      # page catalog — one line per page
├── log.md        # append-only event log
├── raw/          # immutable source documents (PDFs, .md clippings, notes) — never edited
└── wiki/         # LLM-owned pages: sources/ entities/ concepts/ topics/ decisions/ queries/
```

> All work below is done with an LLM agent (Claude Code) **opened inside this
> `llm_wiki/` folder**. The agent owns the `wiki/` layer, `index.md` and
> `log.md`; the human owns `raw/` and the questions.

---

## Step 0 — Prerequisites

- Claude Code (or equivalent agent) able to read/write files in this folder.
- The source documents you want to ingest (PDFs, web clippings, notes).
- The Docker stack running, if you intend to push the result live (see the
  repo root `README.md` / `DEPLOY.md`).

## Step 1 — Bootstrap the vault (initial prompt)

This vault was bootstrapped from Andrej Karpathy's **"LLM Wiki"** pattern. Open
the agent (Claude Code) in the empty `llm_wiki/` folder and paste **two parts**
as the initial prompt:

**Part 1 — the instruction (verbatim):**

```
I want you to read this idea file by Andrej Karpathy and help me set up an LLM
Wiki in the directory "llm_wiki". Before you do anything, ask me what this wiki
will be about, and what sources I plan to feed it. Once I answer, write me a
CLAUDE.md schema file based on my answer
```

**Part 2 — Karpathy's "LLM Wiki" idea file**, pasted immediately after Part 1.
Get the full text from the gist:

> https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f#file-llm-wiki-md

The agent then asks what the wiki is about and which sources you'll feed it. Your
answer drives the `CLAUDE.md` schema it writes — tailor it to your own domain and
sources.

The resulting `CLAUDE.md` is the source of truth for everything afterwards. Read
it before running any ingest/query/lint — the steps below summarise it.

## Step 2 — Add source documents to `raw/`

Copy the source files into `raw/` (flat — PDFs, `.md` clippings, `.txt` notes):

```powershell
# from wherever the sources are
Copy-Item C:\path\to\sources\*.pdf .\raw\
```

`raw/` is **immutable** — the agent reads it but never edits it. File-type is
detected by extension: `.pdf` → paper/report flow; `.md` with `url:` frontmatter
→ web clipping; `.md`/`.txt` without → personal/meeting note.

## Step 3 — Ingest

Tell the agent to ingest. **Single source (supervised, default):**

```
ingest raw/<your-source-file>.pdf
```

The agent will: read the source end-to-end → discuss 5–8 key takeaways and wait
for your direction → write `wiki/sources/<slug>.md` → create/update the
`entities/` and `concepts/` pages it touches (flagging contradictions inline as
`> [!warning] Contradicts [[other-source]]: ...`) → update relevant `topics/`
→ update `index.md` → append an entry to `log.md` → report pages
created/updated/flagged. One source typically touches 5–15 pages.

**Batch (less supervised), when you have many sources at once:**

```
batch ingest
```

Same per-source flow but skips the discussion step and produces one consolidated
report at the end. Use this to ingest everything dropped in `raw/` in one pass.

## Step 4 — Lint (optional, recommended after a batch)

```
lint wiki
```

Health-check pass — reports an actionable checklist of: contradictions, stale
pages (`updated:` > 60 days with newer sources), orphans (no inbound
`[[links]]`), missing pages (entities/concepts mentioned ≥2× with no page of
their own), missing cross-refs, and open-question gaps. Append a summary line to
`log.md`. Apply the fixes you agree with, then optionally lint again.

## Step 5 — Push the vault live to Open WebUI

Once the vault is in good shape, bundle it and patch the `rewave-ai` system
prompt (scripts live in the repo root `scripts/`):

```powershell
# from the repo root
# Regenerate bundle AND patch the rewave-ai system prompt via the Open WebUI API
pwsh -File .\scripts\refresh_wiki.ps1

# Rebuild the bundle only (llm_wiki/_bundle.md), no API call
pwsh -File .\scripts\bundle_wiki.ps1

# Patch the model when the bundle is already current
pwsh -File .\scripts\refresh_wiki.ps1 -SkipBundle
```

`bundle_wiki.ps1` concatenates `CLAUDE.md` + `index.md` + `log.md` + `wiki/**`
(path-sorted) into `_bundle.md`, warning if it nears the ~180k-token Sonnet
limit. `refresh_wiki.ps1` replaces the text between the
`=====BEGIN WIKI=====` / `=====END WIKI=====` markers in the model's system
prompt with the fresh bundle. (The `rewave-ai` model must already exist in Open
WebUI with those markers in its system prompt — see `DEPLOY.md` step 7.)

## Maintenance loop

Whenever the wiki changes (new ingest, lint fixes), re-run `refresh_wiki.ps1` to
push it to the live model. If the bundle outgrows Sonnet's context, switch the
`claude-sonnet` mapping in `litellm-config.yaml` to an Opus 1M-context model.
