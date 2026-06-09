# LLM Wiki — Business/Project Intelligence

This wiki is a persistent, LLM-maintained knowledge base for **business and project intelligence**: customers, competitors, market, product domain, internal decisions. Sources are PDFs/papers, web articles (clipped to markdown), and personal notes / meeting transcripts. The LLM owns the wiki layer; the human owns sourcing and questions.

## Directory Layout

```
llm_wiki/
├── CLAUDE.md              # this schema (co-evolves with use)
├── index.md               # content catalog — every page, one line each
├── log.md                 # chronological append-only event log
├── raw/                   # immutable source documents — never edit (flat: PDFs, .md clippings, notes, assets)
└── wiki/                  # LLM-owned page layer
    ├── sources/           # one summary page per raw source
    ├── entities/          # companies, people, products, teams
    ├── concepts/          # frameworks, methodologies, market terms
    ├── topics/            # cross-cutting themes, theses, analyses
    ├── decisions/         # internal decisions, rationale, status
    └── queries/           # filed-back answers worth keeping
```

Paths in links: `[[slug]]` still works (Obsidian resolves by basename across vault). When writing/reading from CLI, use `wiki/<category>/<slug>.md`.

## Page Conventions

Every wiki page starts with YAML frontmatter (Dataview-compatible):

```yaml
---
type: entity | concept | topic | source | decision | query
title: <human-readable title>
created: YYYY-MM-DD
updated: YYYY-MM-DD
sources: [<source-page-slug>, ...]   # which sources back this page
tags: [<tag>, ...]
status: draft | stable | stale       # for topics/decisions
---
```

Body structure (vary by type, keep consistent):

- **sources/**: TL;DR (3–5 bullets), Key Claims, Numbers/Data, Quotes, Open Questions, Cross-refs.
- **entities/**: One-line description, Profile (key facts), Relationships ([[other-entity]] links), Timeline, Open Questions.
- **concepts/**: Definition, Why it matters, How it applies here, Related concepts, Sources.
- **topics/**: Thesis (current best guess), Evidence For, Evidence Against, Open Questions, Sources.
- **decisions/**: Context, Options considered, Decision, Rationale, Status, Revisit-by date.
- **queries/**: Question, Answer, Method, Confidence, Sources cited.

Link liberally with `[[wiki-link]]` syntax. Slugs are kebab-case (`acme-corp.md`, `unit-economics.md`).

> Schema artifact note: the index format string `[[<slug>]]` in this CLAUDE.md is intentional pseudo-syntax, not a real link. Lint should ignore literal `<slug>` placeholder.

## Workflows

### Ingest (single source, supervised — default)

When user says "ingest <path>" or drops a file in `raw/`:

1. Read the source end-to-end. For PDFs, extract text; for meetings, identify speakers/topics.
2. Discuss key takeaways with user in 5–8 bullets. Wait for direction on emphasis.
3. Write `sources/<slug>.md` summary page.
4. Identify entities (companies, people, products) and concepts touched. For each:
   - If page exists: update it. Note new facts, flag contradictions inline as `> [!warning] Contradicts [[other-source]]: ...`.
   - If page missing: create stub with what's known + `status: draft`.
5. Update `topics/` pages where the source moves a thesis. Adjust Evidence For/Against.
6. Update `index.md` (add new pages, bump `updated:` on touched ones).
7. Append to `log.md`: `## [YYYY-MM-DD] ingest | <source title>` + 2-line summary + list of pages touched.
8. Report back: pages created, pages updated, contradictions flagged.

Single source typically touches 5–15 pages. Stay involved.

### Ingest (batch, less supervised)

User says "batch ingest". Same flow per source but skip discussion step. Produce one consolidated report at end.

### Query

When user asks a question:

1. Read `index.md` first. Identify candidate pages.
2. Read those pages (and their linked pages 1 hop deep if needed).
3. Synthesize answer with `[[page]]` citations. Quote source claims when load-bearing.
4. Note confidence and gaps. Suggest what new sources would tighten the answer.
5. Ask user: "File this back as `queries/<slug>.md`?" If yes, save with frontmatter + append to `log.md`.

Output formats by request: markdown (default), comparison table, Marp slide deck (`.md` with Marp frontmatter), chart (matplotlib via script). Filed-back answers always live in `queries/`.

### Lint

User says "lint wiki". Health-check pass:

- **Contradictions**: pages whose claims conflict. Group and propose resolution.
- **Stale**: pages with `updated:` > 60 days old AND newer sources exist that touch them.
- **Orphans**: pages with no inbound `[[links]]` (check via grep).
- **Missing pages**: entities/concepts mentioned ≥2 times across wiki but no own page.
- **Missing cross-refs**: pages that *should* link to each other but don't.
- **Gaps**: open questions across `topics/` that could be filled by targeted source hunting or web search.

Report as actionable checklist. Append summary to `log.md`: `## [YYYY-MM-DD] lint | <N issues>`.

## index.md Format

Grouped by category. Each line: `- [[<slug>]] — <one-line summary> (<source-count> sources, updated YYYY-MM-DD)`. LLM updates on every ingest. Keep tight; this file is read on every query.

## log.md Format

Append-only. One H2 per event, prefix-parseable:

```
## [2026-05-14] ingest | Acme Q1 earnings call
Touched: [[acme-corp]], [[unit-economics]], [[topics/saas-margins]]. 1 contradiction flagged.

## [2026-05-14] query | "How does Acme compare to Beta on retention?"
Filed as [[queries/acme-vs-beta-retention]].

## [2026-05-15] lint | 3 orphans, 1 stale topic
```

Last-5-events check: `grep "^## \[" log.md | tail -5`.

## Source-Type Specifics

- **PDFs/papers**: extract metadata (authors, year, venue) into frontmatter. Page-cite quotes (`p.12`).
- **Web articles**: preserve original URL in frontmatter as `url:`. If clipped via Obsidian Web Clipper, keep clipper metadata.
- **Meeting notes / personal notes**: identify participants → entity pages. Decisions made → `decisions/`. Action items → flag but don't track (not a task manager).

File-type detection by extension in `raw/`: `.pdf` → paper/report flow; `.md` with `url:` frontmatter → web clipping; `.md`/`.txt` without → personal/meeting note. LLM picks flow from content if ambiguous.

## Rules of Engagement

- Never edit `raw/`. Read-only.
- Never invent facts. If unsure, write "unclear" or "not in sources" — don't paper over gaps.
- Contradictions are valuable signal, not errors. Flag them, don't silently pick one.
- Prefer updating an existing page over creating a near-duplicate. Check `index.md` first.
- When user asks an exploratory question, *answer first*, then offer to file it.
- Keep frontmatter `updated:` honest — bump on every real change.
- This schema is mutable. When a convention isn't working, propose a CLAUDE.md change.

## Open Schema Questions (to resolve with user as we go)

- Confidentiality tier on pages (public / internal / sensitive)?
- Auto-pull web search to fill gaps during lint, or only on explicit ask?
- When to spin out a `decisions/` page vs leaving rationale in a meeting note summary?
