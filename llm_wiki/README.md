# llm_wiki

This folder holds the LLM-maintained knowledge base (Obsidian-style vault)
injected into the `rewave-ai` model as a full-context system prompt.

**Its content is intentionally excluded from the repo** (see `.gitignore`):
proprietary company KB plus copyrighted third-party PDF sources. The vault is
**recreated per deployment** — populate this folder manually (see `DEPLOY.md`).

Expected layout once populated:

```
llm_wiki/
├── CLAUDE.md     # vault schema / ingest-query-lint workflow / wikilink conventions
├── index.md      # page catalog
├── log.md        # maintenance log
├── raw/          # immutable source documents (never edited)
└── wiki/         # derived pages: concepts/ entities/ topics/ decisions/ queries/
```

Only this `README.md` is tracked, so the empty folder ships with the repo.
