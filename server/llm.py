"""LLM providers shared by the dictation polish, meeting notes and Scratchpad transforms.

  - Claude (ANTHROPIC_API_KEY), through the Anthropic SDK.
  - DeepSeek (DEEPSEEK_API_KEY), through its OpenAI-compatible chat API (stdlib HTTP, no extra deps).

`ai_provider` in the settings file picks the preferred one; when its key is missing, the other one
is used if configured. Every call returns None on failure so callers fall back to local rules.
"""

from __future__ import annotations

import json
import logging
import os
import urllib.error
import urllib.request
from typing import Optional

log = logging.getLogger("rustle.llm")

CLAUDE_MODEL = os.environ.get("RUSTLE_CLAUDE_MODEL", "claude-opus-5-5")
DEEPSEEK_MODEL = os.environ.get("RUSTLE_DEEPSEEK_MODEL", "deepseek-chat")
DEEPSEEK_URL = os.environ.get("RUSTLE_DEEPSEEK_URL", "https://api.deepseek.com/chat/completions")
PROVIDERS = ("claude", "deepseek")


def claude_configured() -> bool:
    return bool(os.environ.get("ANTHROPIC_API_KEY"))


def deepseek_configured() -> bool:
    return bool(os.environ.get("DEEPSEEK_API_KEY"))


def configured(provider: str) -> bool:
    return claude_configured() if provider == "claude" else deepseek_configured() if provider == "deepseek" else False


def pick_provider(preferred: str) -> Optional[str]:
    """The preferred provider when its key is set, otherwise the other one, otherwise None."""
    preferred = preferred if preferred in PROVIDERS else "claude"
    for p in (preferred, *[p for p in PROVIDERS if p != preferred]):
        if configured(p):
            return p
    return None


def deepseek_complete(system: str, user: str, *, max_tokens: int, timeout: float,
                      schema: Optional[dict] = None, label: str = "DeepSeek",
                      temperature: Optional[float] = None) -> Optional[str]:
    """One chat completion. With `schema`, asks for a JSON object shaped like it (DeepSeek's JSON
    mode does not enforce a schema, so the schema goes in the system prompt)."""
    key = os.environ.get("DEEPSEEK_API_KEY")
    if not key:
        return None
    if schema is not None:
        system += ("\n\nRespond with a single JSON object (no code fences) that matches this JSON schema:\n"
                   + json.dumps(schema, ensure_ascii=False))
    body = {
        "model": DEEPSEEK_MODEL,
        "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
        "max_tokens": min(max_tokens, 8000),
        "stream": False,
    }
    if temperature is not None:
        body["temperature"] = temperature
    if schema is not None:
        body["response_format"] = {"type": "json_object"}
    req = urllib.request.Request(
        DEEPSEEK_URL,
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json", "Authorization": f"Bearer {key}"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            data = json.loads(resp.read())
    except urllib.error.HTTPError as e:
        log.warning("%s failed (%s); using local fallback", label, e.code)
        return None
    except (urllib.error.URLError, TimeoutError, OSError) as e:
        log.warning("%s unreachable (%s); using local fallback", label, e)
        return None
    except json.JSONDecodeError:
        log.warning("%s returned an invalid response; using local fallback", label)
        return None
    try:
        choice = data["choices"][0]
        text = (choice["message"].get("content") or "").strip()
    except (KeyError, IndexError, TypeError):
        log.warning("%s returned an unexpected response; using local fallback", label)
        return None
    if choice.get("finish_reason") in ("length", "content_filter"):
        log.warning("%s stopped: %s", label, choice.get("finish_reason"))
        return None
    return text or None
