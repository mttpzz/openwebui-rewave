# routellm — per-request complexity router

Routes each `rewave-ai` chat to a **weak** or **strong** model based on how hard
the request looks, so simple questions don't pay for the strong model.

- **Engine**: [LM-SYS RouteLLM](https://github.com/lm-sys/RouteLLM), OpenAI-compatible
  server on port `6060` (internal only — no host port). Built from `Dockerfile`
  (pinned `routellm[serve]==0.2.0`).
- **Router**: `bert` — a fine-tuned classifier that runs **fully locally on CPU**
  (downloaded from Hugging Face on first start, cached in the `routellm-hf-cache`
  volume). The `mf`/`sw_ranking` routers are avoided: they require an
  `OPENAI_API_KEY` and send the prompt out for embeddings.
- **Weak** = `claude-haiku` · **Strong** = `claude-sonnet` (set via `--weak-model` /
  `--strong-model` in the `Dockerfile`). Both are LiteLLM model names; RouteLLM
  calls them back **through the LiteLLM proxy** (`OPENAI_API_BASE` /
  `OPENAI_API_KEY` env → the LiteLLM master key), so prompt caching and the
  per-model `additional_drop_params` still apply.

## How a request flows

```
Open WebUI (rewave-ai, base model = router-bert-<threshold>)
  → routellm:6060   (bert scores the LAST user message)
      score ≥ threshold → strong (claude-sonnet)
      score <  threshold → weak   (claude-haiku)
  → litellm:4000 → Anthropic
```

Routing looks only at `messages[-1].content` (see `routellm/controller.py`), so the
full-context wiki sitting in the system prompt does **not** affect classification.

## The threshold

The threshold is encoded in the model id: `router-bert-0.6` = cutoff `0.6`.
**Higher threshold → more requests to the weak model** (cheaper); lower → more to
strong (higher quality). It is set in **two** Open WebUI places (must match
exactly): the RouteLLM connection's *Model IDs* list, and `rewave-ai`'s *Base
Model*. Current value: `router-bert-0.6`.

### Recalibrate

`calibrate_threshold` picks the cutoff for a target % of traffic to the strong
model. The `[eval]` deps aren't in the runtime image — install them just for the
run (ephemeral):

```bash
docker compose exec routellm pip install "routellm[eval]==0.2.0"
docker compose exec routellm python -m routellm.calibrate_threshold \
  --task calibrate --routers bert --strong-model-pct 0.5
# → prints e.g. "threshold = 0.4066"; use it as router-bert-0.4066
```

Lower `--strong-model-pct` (e.g. `0.3`) → fewer to strong → cheaper.
The bert router is trained on English data, so the % is a starting point — tune
the threshold empirically against real (Italian, cartotecnica) queries.

## Why the weak tier is cloud Haiku, not a local model

A local CPU model (gemma 3 4B was tried) must prefill the full-context wiki
(~16.5k tokens) on every cold request — **~100s+ on CPU**, and Ollama's default
`num_ctx` even truncates the wiki. Local models have no prompt caching, so this
cost repeats. Cloud Haiku is cheap (\$1/\$5 per 1M), fast, and **cached**, so the
wiki is near-free on the weak path too — making routing actually worthwhile.

## Open WebUI wiring gotchas

Two non-obvious things that break routing if you get them wrong (full steps in
`DEPLOY.md` Phase 9 + Phase 10):

1. **The router model must be Public.** `router-bert-<threshold>` is `rewave-ai`'s
   *base model*, and Open WebUI resolves the base with the **requesting user's**
   permissions — not server-side. If it's Private, non-admin users get
   `model not found`. Keep `router-bert-*` **Public**; keep its targets
   (`claude-sonnet`, `claude-haiku`, `gemma3-4b`) **Private** — `routellm` calls
   those through LiteLLM with the master key, so users never resolve them.

2. **Do not enable Web Search as a Default Feature on `rewave-ai`.** With web search
   (or any retrieved context / citations) active, Open WebUI replaces the user's
   message with a long `### Task: Respond to the user query using the provided
   context, incorporating inline citations …` template. RouteLLM routes on
   `messages[-1]` — that template, not the real question — so it scores **every**
   query as complex and sends **everything to Sonnet**, silently defeating the
   router. Keep web search as an **on-demand capability** (per-chat toggle), not a
   default. Citations can stay on (passive — they only wrap when there's retrieved
   context). `#kb` / uploaded-file queries also get the template → Sonnet, which is
   appropriate for document Q&A.

   Symptom: everything answers as Sonnet even trivial greetings; a raw API call
   (`{"model":"rewave-ai","messages":[{"role":"user","content":"ciao"}]}`) routes to
   Haiku but the chat UI routes to Sonnet — the difference is the UI's context
   template.

## Common operations

```bash
docker compose up -d --build routellm     # rebuild after editing the Dockerfile
docker compose logs -f routellm           # tail
docker compose restart litellm            # after litellm-config.yaml changes
```

Test routing without Open WebUI (from inside the container):

```bash
docker compose exec -T routellm python - <<'PY'
import urllib.request, json
def ask(model, text):
    body=json.dumps({"model":model,"messages":[{"role":"user","content":text}]}).encode()
    r=urllib.request.urlopen(urllib.request.Request(
        "http://localhost:6060/v1/chat/completions", data=body,
        headers={"Content-Type":"application/json"}), timeout=120)
    print(text, "->", json.loads(r.read()).get("model"))
ask("router-bert-0.6", "salutami")                 # expect claude-haiku
ask("router-bert-0.6", "confronta offset e flexo per packaging FSC, motiva")  # expect claude-sonnet
PY
```
