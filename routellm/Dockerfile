# RouteLLM — complexity-based router between the weak model (claude-haiku) and
# the strong model (claude-sonnet). Exposes an OpenAI-compatible server and
# calls both backends back through the LiteLLM proxy (OPENAI_API_BASE / _KEY env).
#
# Both weak and strong are cloud Anthropic models: prompt caching keeps the
# full-context wiki cheap and fast on either path. (A local CPU weak model was
# tried but the wiki prefill — ~16.5k tokens, no caching — took minutes per cold
# request, making it slower and pricier than just routing to Haiku.)
#
# Router "bert" runs fully locally on CPU (a fine-tuned classifier pulled from
# Hugging Face at first start) — no external embedding calls, unlike the
# "mf"/"sw_ranking" routers which require an OPENAI_API_KEY and leak the prompt.
#
# Version is pinned for reproducibility — bump deliberately and re-test.
FROM python:3.11-slim

RUN pip install --no-cache-dir "routellm[serve]==0.2.0"

# RouteLLM 0.2.0 declares tools as List[Dict[str, Union[str, int, float]]],
# which rejects nested dicts in OpenAI tool definitions (parameters, properties,
# etc.). Patch it to List[Any] so tool calls from Open WebUI pass through.
RUN python3 - <<'EOF'
import os, routellm
path = os.path.join(os.path.dirname(routellm.__file__), 'openai_server.py')
content = open(path).read()
content = 'from typing import Any\n' + content
content = content.replace(
    'Optional[List[Dict[str, Union[str, int, float]]]]',
    'Optional[List[Any]]'
)
open(path, 'w').write(content)
print('Patch applied:', path)
EOF

EXPOSE 6060

# Routing uses only the last user message (routellm/controller.py:
# `prompt = messages[-1]["content"]`), so the full-context wiki in the system
# prompt does not affect classification.
CMD ["python", "-m", "routellm.openai_server", \
     "--routers", "bert", \
     "--strong-model", "openai/claude-sonnet", \
     "--weak-model", "openai/claude-haiku", \
     "--port", "6060"]
