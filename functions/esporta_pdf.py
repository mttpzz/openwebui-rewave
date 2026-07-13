"""
title: Presentation PDF
description: When any assistant reply contains a reveal.js presentation, auto-renders the slides to a PDF and appends a download link to the message (no button click).
author: rewave
version: 0.2.0
required_open_webui_version: 0.9.0
"""

# Open WebUI Filter function (global outlet).
# Runs automatically after every assistant reply. When the message contains a
# reveal.js presentation (any <div class="reveal"> block), it re-lays each
# <section> as a landscape print page, renders it to PDF via the shared Playwright
# server (ws://playwright:3000), stores the file, and appends a download link
# to the message — visible immediately, no click.
#
# Non-presentation messages are a cheap no-op (regex miss → return unchanged).
# No extra pip requirements: the openwebui image already ships playwright==1.58.0,
# the exact version of the playwright service in docker-compose.yml.

import io
import re
import uuid
import inspect

from pydantic import BaseModel, Field

from open_webui.models.files import Files, FileForm
from open_webui.storage.provider import Storage

# Idempotency guards: the appended block is recognised by these literals, so the
# outlet never processes the same message twice (no hidden marker that would show
# up in the rendered chat). Strings stay Italian — they are shown to end users.
_LINK_LABEL = "Scarica la presentazione (PDF)"
_ERR_LABEL = "PDF non generato"


# ── Print template ──────────────────────────────────────────────────
# Sober palette suited to a paper-converting company: navy headings, kraft accent rule.
PRINT_CSS = """
@page { size: A4 landscape; margin: 0; }
* { box-sizing: border-box; }
html, body { margin: 0; padding: 0; font-family: 'Segoe UI', Arial, Helvetica, sans-serif; color: #1f2933; }
.slide {
  width: 297mm; height: 209mm; padding: 22mm 26mm;
  page-break-after: always; position: relative;
  display: flex; flex-direction: column; justify-content: center;
  border-top: 6mm solid #1b3a5b;
}
.slide:last-child { page-break-after: auto; }
.slide h1 { font-size: 34pt; color: #1b3a5b; margin: 0 0 8mm 0; line-height: 1.1; }
.slide h2 { font-size: 24pt; color: #1b3a5b; margin: 0 0 6mm 0; }
.slide h3 { font-size: 18pt; color: #b5651d; margin: 0 0 4mm 0; }
.slide p  { font-size: 16pt; line-height: 1.4; margin: 2mm 0; }
.slide ul, .slide ol { font-size: 16pt; line-height: 1.5; margin: 2mm 0 2mm 6mm; }
.slide li { margin: 3mm 0; }
.slide strong { color: #1b3a5b; }
.slide table { border-collapse: collapse; font-size: 13pt; margin: 4mm 0; width: 100%; }
.slide th, .slide td { border: 1px solid #c7ccd1; padding: 3mm 4mm; text-align: left; }
.slide th { background: #eef2f6; color: #1b3a5b; }
.slide img, .slide svg { max-width: 100%; max-height: 110mm; }
.slide .pagefoot {
  position: absolute; bottom: 10mm; right: 26mm;
  font-size: 10pt; color: #8a949e; letter-spacing: .5px;
}
"""


def _maybe(x):
    """Await if coroutine, else wrap (OWUI mixes sync/async model APIs)."""
    if inspect.isawaitable(x):
        return x
    async def _wrap():
        return x
    return _wrap()


def _extract_html(content: str) -> str | None:
    """Pull the reveal.js document out of a ```html fenced block, or a raw <html>/<div class=reveal>."""
    if not content:
        return None
    m = re.search(r"```html\s*(.*?)```", content, re.DOTALL | re.IGNORECASE)
    if m:
        return m.group(1).strip()
    m = re.search(r"<!doctype html.*?</html>", content, re.DOTALL | re.IGNORECASE)
    if m:
        return m.group(0)
    m = re.search(r'<div\s+class="reveal".*?</div>\s*</div>', content, re.DOTALL | re.IGNORECASE)
    if m:
        return m.group(0)
    return None


def _split_sections(html: str) -> list[str]:
    """Return inner HTML of each top-level <section> (reveal slide), flattening vertical stacks."""
    sm = re.search(r'<div\s+class="slides"[^>]*>(.*)</div>', html, re.DOTALL | re.IGNORECASE)
    scope = sm.group(1) if sm else html

    sections, depth, buf = [], 0, None
    for tok in re.split(r'(<section\b[^>]*>|</section\s*>)', scope, flags=re.IGNORECASE):
        if re.match(r'<section\b', tok, re.IGNORECASE):
            if depth == 0:
                buf = []
            else:
                buf.append(tok)
            depth += 1
        elif re.match(r'</section', tok, re.IGNORECASE):
            depth -= 1
            if depth == 0 and buf is not None:
                sections.append(''.join(buf))
                buf = None
            elif buf is not None:
                buf.append(tok)
        elif depth > 0 and buf is not None:
            buf.append(tok)

    cleaned = [re.sub(r'</?section\b[^>]*>', '', s, flags=re.IGNORECASE).strip() for s in sections]
    return [c for c in cleaned if c]


def _build_print_html(sections: list[str]) -> str:
    pages = "\n".join(
        f'<div class="slide">{inner}<div class="pagefoot">Rewave Srl</div></div>'
        for inner in sections
    )
    return (
        "<!doctype html><html lang='it'><head><meta charset='utf-8'>"
        f"<style>{PRINT_CSS}</style></head><body>{pages}</body></html>"
    )


def _title(sections: list[str]) -> str:
    """Plain-text title from the first slide heading, fallback 'Presentazione' (Italian, user-facing)."""
    if sections:
        h = re.search(r'<h[1-3][^>]*>(.*?)</h[1-3]>', sections[0], re.DOTALL | re.IGNORECASE)
        if h:
            text = re.sub(r'<[^>]+>', '', h.group(1)).strip()
            if text:
                return text
    return "Presentazione"


def _slug(sections: list[str]) -> str:
    """Filename from the title, fallback 'presentazione'."""
    slug = re.sub(r'[^a-z0-9]+', '-', _title(sections).lower()).strip('-')
    return slug[:60] if slug else "presentazione"


async def _render_pdf(print_html: str, ws: str) -> bytes:
    from playwright.async_api import async_playwright

    async with async_playwright() as p:
        browser = await p.chromium.connect(ws)
        try:
            page = await browser.new_page()
            await page.set_content(print_html, wait_until="networkidle")
            return await page.pdf(prefer_css_page_size=True, print_background=True)
        finally:
            await browser.close()


class Filter:
    class Valves(BaseModel):
        playwright_ws: str = Field(
            default="ws://playwright:3000",
            description="Playwright server websocket endpoint (matches PLAYWRIGHT_WS_URI).",
        )

    def __init__(self):
        self.valves = self.Valves()

    async def outlet(self, body: dict, __user__=None, **kwargs) -> dict:
        messages = body.get("messages", []) or []
        if not messages:
            return body

        # Only the freshly generated last message; must be an assistant reply.
        msg = messages[-1]
        if msg.get("role") != "assistant":
            return body
        content = msg.get("content", "") or ""
        if _LINK_LABEL in content or _ERR_LABEL in content:  # already processed
            return body

        html = _extract_html(content)
        if not html:
            return body
        sections = _split_sections(html)
        if not sections:
            return body

        try:
            pdf = await _render_pdf(_build_print_html(sections), self.valves.playwright_ws)

            file_id = str(uuid.uuid4())
            filename = f"{_slug(sections)}.pdf"
            user_id = (__user__ or {}).get("id")
            _, path = Storage.upload_file(io.BytesIO(pdf), f"{file_id}_{filename}", {"OpenWebUI": "true"})
            form = FileForm(
                id=file_id,
                filename=filename,
                path=path,
                data={},
                meta={"name": filename, "content_type": "application/pdf", "size": len(pdf)},
            )
            await _maybe(Files.insert_new_file(user_id, form))

            link = f"/api/v1/files/{file_id}/content?attachment=true"
            # Replace the whole reply: drop the reveal.js HTML block + artifact preview,
            # leave only the title and the PDF download link (the PDF is what's used).
            msg["content"] = f"### {_title(sections)}\n\n📄 **[{_LINK_LABEL}]({link})**"
        except Exception as e:
            # On failure keep the original HTML as a fallback and surface the error.
            msg["content"] = f"{content}\n\n---\n_⚠️ {_ERR_LABEL}: {e}_"

        return body
