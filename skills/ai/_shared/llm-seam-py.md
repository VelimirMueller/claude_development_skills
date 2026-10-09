# LLM Seam, Python

The canonical `src/app/platform/llm/` module for FastAPI services (`app` stands for your package name, see [service-layout.md](../../backend/_shared/service-layout.md)). Same contract and behaviour as [llm-seam-ts.md](llm-seam-ts.md); the reasons are in [seam-patterns.md](../build-llm-seam/seam-patterns.md).

Tested: `pyright` (standard mode) clean and `pytest` green with Python 3.14, `anthropic` 1.12.1, `pydantic` 2.14.0, `opentelemetry-api` 1.45.1. The Anthropic adapter was type-checked, not called: no API key was available when this was written.

```bash
uv add anthropic pydantic opentelemetry-api
uv add --dev pytest pytest-asyncio pyright
```

`pyproject.toml`: `[tool.pytest.ini_options] asyncio_mode = "auto"`. Use the same `config/llm.models.json` and `prompts/*.md` files as the TypeScript seam; they are language-neutral.

## Contract (`types.py`)

```python
# src/app/platform/llm/types.py
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Callable, Literal, Protocol

Tier = Literal["quality", "balanced", "fast"]
ErrorKind = Literal[
    "rate_limit", "overloaded", "server", "timeout", "connection",
    "bad_request", "auth", "refusal", "truncated", "invalid_output",
]
_RETRYABLE: set[str] = {"rate_limit", "overloaded", "server", "timeout", "connection"}


class LlmError(Exception):
    def __init__(self, kind: ErrorKind, message: str, retry_after_s: float | None = None):
        super().__init__(message)
        self.kind = kind
        self.retry_after_s = retry_after_s

    @property
    def retryable(self) -> bool:
        return self.kind in _RETRYABLE


@dataclass(frozen=True)
class Usage:
    """input_tokens includes cached tokens (OTel gen_ai convention; Anthropic reports them separately)."""
    input_tokens: int
    output_tokens: int
    cache_read_tokens: int = 0
    cache_write_tokens: int = 0


@dataclass(frozen=True)
class ResolvedPrompt:
    name: str
    version: str
    system: str
    cacheable: bool


@dataclass(frozen=True)
class AdapterCall:
    model: str
    effort: str
    prompt: ResolvedPrompt
    messages: list[dict[str, str]]
    schema: type | None
    max_tokens: int
    timeout_s: float
    on_text: Callable[[str], None] | None = None


@dataclass(frozen=True)
class AdapterResult:
    output: Any
    usage: Usage
    model: str
    stop_reason: str


class LlmAdapter(Protocol):
    provider: str

    async def call(self, c: AdapterCall) -> AdapterResult: ...

    async def count_tokens(self, model: str, system: str, messages: list[dict[str, str]]) -> int:
        """Input tokens from the provider's own counter. Used for budget checks before a call."""
        ...
```

## Prompts as files, redaction

```python
# src/app/platform/llm/prompts.py
from __future__ import annotations

import re
from pathlib import Path

from .types import ResolvedPrompt


def load_prompt(prompts_dir: Path, name: str, vars: dict[str, str] | None = None) -> ResolvedPrompt:
    """prompts/<name>.md, read from an explicit directory (never derive it from __file__: packaging moves files).
    Format: '---\\nversion: 3\\ncache: true\\n---\\n<body with {{vars}}>'"""
    vars = vars or {}
    if not re.fullmatch(r"[a-z0-9-]+", name):
        raise ValueError(f"Invalid prompt name: {name}")
    m = re.match(r"^---\n(.*?)\n---\n(.*)$", (prompts_dir / f"{name}.md").read_text(), re.S)
    if not m:
        raise ValueError(f"Prompt {name}: missing frontmatter")
    meta = dict(line.split(": ", 1) for line in m.group(1).splitlines())
    if "version" not in meta:
        raise ValueError(f"Prompt {name}: frontmatter needs 'version'")
    cacheable = meta.get("cache") == "true"
    if cacheable and vars:
        raise ValueError(f"Prompt {name}: a cacheable prompt cannot take vars; move variable content to the user turn")

    def sub(match: re.Match[str]) -> str:
        key = match.group(1)
        if key not in vars:
            raise ValueError(f"Prompt {name}: missing var '{key}'")
        return vars[key]

    return ResolvedPrompt(name, meta["version"], re.sub(r"\{\{(\w+)\}\}", sub, m.group(2)), cacheable)
```

```python
# src/app/platform/llm/redact.py
from __future__ import annotations

import re
from dataclasses import dataclass

_RULES = [
    ("EMAIL", re.compile(r"[\w.+-]+@[\w-]+(?:\.[\w-]+)+")),
    ("IBAN", re.compile(r"\b[A-Z]{2}\d{2}(?: ?[A-Z0-9]{4}){3,7}(?: ?[A-Z0-9]{1,3})?\b")),
    ("SECRET", re.compile(r"\b(?:sk-[\w-]{16,}|ghp_\w{20,}|AKIA[0-9A-Z]{16}|Bearer\s+[\w.~+/=-]{16,})")),
    ("PHONE", re.compile(r"(?<!\w)\+?\d[\d ()/-]{8,}\d(?!\w)")),
]
_CARD = re.compile(r"\b(?:\d[ -]?){13,19}\b")


def _luhn(digits: str) -> bool:
    total = 0
    for i, ch in enumerate(reversed(digits)):
        n = int(ch) * (2 if i % 2 else 1)
        total += n - 9 if n > 9 else n
    return total % 10 == 0


@dataclass
class Redacted:
    text: str
    _map: dict[str, str]

    def restore(self, output: str) -> str:
        for key, value in self._map.items():
            output = output.replace(key, value)
        return output


def redact(text: str) -> Redacted:
    """Best-effort pattern redaction. It does NOT find names or addresses; see seam-patterns.md."""
    mapping: dict[str, str] = {}

    def swap(name: str):
        def inner(m: re.Match[str]) -> str:
            key = f"[{name}_{len(mapping) + 1}]"
            mapping[key] = m.group(0)
            return key
        return inner

    text = _CARD.sub(lambda m: swap("CARD")(m) if _luhn(re.sub(r"\D", "", m.group(0))) else m.group(0), text)
    for name, rx in _RULES:
        text = rx.sub(swap(name), text)
    return Redacted(text, mapping)
```

## Anthropic adapter

```python
# src/app/platform/llm/adapter_anthropic.py
from __future__ import annotations

import anthropic

from .types import AdapterCall, AdapterResult, LlmError, Usage


def _to_llm_error(err: Exception) -> LlmError:
    if isinstance(err, LlmError):
        return err
    if isinstance(err, anthropic.APITimeoutError):
        return LlmError("timeout", "Request timed out")
    if isinstance(err, anthropic.APIConnectionError):
        return LlmError("connection", "Connection failed")
    if isinstance(err, anthropic.APIStatusError):
        raw = err.response.headers.get("retry-after")
        retry_after = float(raw) if raw and raw.replace(".", "", 1).isdigit() else None
        if err.status_code == 429:
            return LlmError("rate_limit", "Rate limited", retry_after)
        if err.status_code == 529:
            return LlmError("overloaded", "Provider overloaded", retry_after)
        if err.status_code >= 500:
            return LlmError("server", f"Provider error {err.status_code}", retry_after)
        if err.status_code in (401, 403):
            return LlmError("auth", "Provider rejected credentials")
        return LlmError("bad_request", f"Provider rejected request ({err.status_code})")
    return LlmError("server", "Unknown provider failure")


class AnthropicAdapter:
    provider = "anthropic"

    def __init__(self, api_key: str) -> None:
        # max_retries=0: the seam owns retries so every provider shares one policy.
        self._client = anthropic.AsyncAnthropic(api_key=api_key, max_retries=0)

    async def count_tokens(self, model: str, system: str, messages: list[dict[str, str]]) -> int:
        try:
            r = await self._client.messages.count_tokens(model=model, system=system, messages=messages)  # type: ignore[arg-type]
        except Exception as err:  # noqa: BLE001 - mapped to the provider-neutral taxonomy
            raise _to_llm_error(err) from err
        return r.input_tokens

    async def call(self, c: AdapterCall) -> AdapterResult:
        system = [{"type": "text", "text": c.prompt.system,
                   **({"cache_control": {"type": "ephemeral"}} if c.prompt.cacheable else {})}]
        try:
            # Streaming for deltas or large budgets; parse() validates against the Pydantic model.
            if c.on_text is not None or c.max_tokens > 16_000:
                async with self._client.messages.stream(
                    model=c.model, max_tokens=c.max_tokens, system=system, messages=c.messages,  # type: ignore[arg-type]
                    output_config={"effort": c.effort},  # type: ignore[typeddict-item]
                    output_format=c.schema, timeout=c.timeout_s,  # type: ignore[arg-type]
                ) as stream:
                    if c.on_text is not None:
                        async for delta in stream.text_stream:
                            c.on_text(delta)
                    message = await stream.get_final_message()
                parsed = getattr(message, "parsed_output", None)
            else:
                message = await self._client.messages.parse(
                    model=c.model, max_tokens=c.max_tokens, system=system, messages=c.messages,  # type: ignore[arg-type]
                    output_config={"effort": c.effort},  # type: ignore[typeddict-item]
                    output_format=c.schema, timeout=c.timeout_s,  # type: ignore[arg-type]
                )
                parsed = message.parsed_output
        except Exception as err:  # noqa: BLE001 - mapped to the provider-neutral taxonomy
            raise _to_llm_error(err) from err

        if message.stop_reason == "refusal":
            raise LlmError("refusal", "Model refused the request")
        if message.stop_reason == "max_tokens":
            raise LlmError("truncated", "Output hit max_tokens")
        if c.schema is not None and parsed is None:
            raise LlmError("invalid_output", "Output did not match the schema")
        text = "".join(b.text for b in message.content if b.type == "text")
        u = message.usage
        read, write = u.cache_read_input_tokens or 0, u.cache_creation_input_tokens or 0
        return AdapterResult(
            output=parsed if c.schema is not None else text,
            model=message.model,
            stop_reason=message.stop_reason or "unknown",
            usage=Usage(u.input_tokens + read + write, u.output_tokens, read, write),
        )
```

## The seam (`seam.py`: retries, telemetry, cost, `count_tokens`)

```python
# src/app/platform/llm/seam.py
from __future__ import annotations

import asyncio
import json
import random
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Generic, Literal, TypeVar

from opentelemetry import metrics, trace
from opentelemetry.trace import SpanKind, Status, StatusCode
from pydantic import BaseModel

from .prompts import load_prompt
from .redact import redact
from .types import AdapterCall, LlmAdapter, LlmError, Tier, Usage

T = TypeVar("T")
_tracer = trace.get_tracer("app.llm")
_cost_counter = metrics.get_meter("app.llm").create_counter("app.llm.cost", unit="USD")


@dataclass(frozen=True)
class LlmRequest(Generic[T]):
    task: str
    tier: Tier
    prompt_name: str
    messages: list[dict[str, str]]
    max_tokens: int
    pii: Literal["redact", "allow"]  # required: forgetting it must not type-check
    schema: type[BaseModel] | None = None
    prompt_vars: dict[str, str] = field(default_factory=dict)


@dataclass(frozen=True)
class LlmResult(Generic[T]):
    output: Any
    usage: Usage
    cost_usd: float
    latency_ms: int
    model: str
    stop_reason: str


def load_llm_config(path: Path) -> dict[str, Any]:
    """Called once by main. Fail fast at startup, not on the first request."""
    cfg = json.loads(path.read_text())
    missing = {"quality", "balanced", "fast"} - cfg["tiers"].keys()
    if missing:
        raise ValueError(f"llm config missing tiers: {sorted(missing)}")
    return cfg


def _cost(u: Usage, p: dict[str, float]) -> float:
    fresh = u.input_tokens - u.cache_read_tokens - u.cache_write_tokens
    return (fresh * p["inputPerMTok"] + u.cache_read_tokens * p["cacheReadPerMTok"]
            + u.cache_write_tokens * p["cacheWritePerMTok"] + u.output_tokens * p["outputPerMTok"]) / 1_000_000


class Llm:
    def __init__(self, cfg: dict[str, Any], adapter: LlmAdapter, prompts_dir: Path):
        self._cfg, self._adapter, self._prompts_dir = cfg, adapter, prompts_dir

    async def generate(self, req: LlmRequest[T], on_text: Callable[[str], None] | None = None) -> LlmResult[T]:
        tier = self._cfg["tiers"][req.tier]
        prompt = load_prompt(self._prompts_dir, req.prompt_name, req.prompt_vars)
        reds = [redact(m["content"]) if req.pii == "redact" else None for m in req.messages]
        messages = [{"role": m["role"], "content": r.text if r else m["content"]} for m, r in zip(req.messages, reds)]
        timeout_s = self._cfg["timeoutMs"] / 1000
        deadline = timeout_s * (self._cfg["maxRetries"] + 1)  # one deadline for the logical call, retries included

        with _tracer.start_as_current_span(f"chat {tier['model']}", kind=SpanKind.CLIENT) as span:
            span.set_attributes({
                "gen_ai.operation.name": "chat", "gen_ai.provider.name": self._adapter.provider,
                "gen_ai.request.model": tier["model"], "gen_ai.request.max_tokens": req.max_tokens,
                "gen_ai.request.stream": on_text is not None,
                "gen_ai.prompt.name": prompt.name, "gen_ai.prompt.version": prompt.version,
                "app.llm.task": req.task, "app.llm.tier": req.tier,
            })
            started = time.perf_counter()
            try:
                async with asyncio.timeout(deadline):
                    res = await self._with_retry(
                        lambda: self._adapter.call(AdapterCall(
                            tier["model"], tier["effort"], prompt, messages, req.schema, req.max_tokens, timeout_s, on_text)),
                        span,
                    )
            except TimeoutError as err:
                span.set_attribute("error.type", "timeout")
                span.set_status(Status(StatusCode.ERROR, "timeout"))
                raise LlmError("timeout", "Deadline exceeded") from err
            except LlmError as err:
                span.set_attribute("error.type", err.kind)
                span.set_status(Status(StatusCode.ERROR, err.kind))  # kind only: messages may echo content
                raise
            cost = _cost(res.usage, tier["price"])
            span.set_attributes({
                "gen_ai.response.model": res.model, "gen_ai.response.finish_reasons": [res.stop_reason],
                "gen_ai.usage.input_tokens": res.usage.input_tokens, "gen_ai.usage.output_tokens": res.usage.output_tokens,
                "gen_ai.usage.cache_read.input_tokens": res.usage.cache_read_tokens,
                "gen_ai.usage.cache_write.input_tokens": res.usage.cache_write_tokens, "app.llm.cost_usd": cost,
            })
            _cost_counter.add(cost, {"app.llm.task": req.task})
            out = res.output
            if isinstance(out, str):
                for r in reds:
                    out = r.restore(out) if r else out
            return LlmResult(out, res.usage, cost, round((time.perf_counter() - started) * 1000), res.model, res.stop_reason)

    async def count_tokens(self, req: LlmRequest[T]) -> int:
        """Input tokens the request would use (redaction applied, as in generate). For worst-case budget checks."""
        prompt = load_prompt(self._prompts_dir, req.prompt_name, req.prompt_vars)
        messages = [{"role": m["role"], "content": redact(m["content"]).text if req.pii == "redact" else m["content"]}
                    for m in req.messages]
        return await self._adapter.count_tokens(self._cfg["tiers"][req.tier]["model"], prompt.system, messages)

    async def _with_retry(self, fn: Callable[[], Any], span: trace.Span) -> Any:
        for attempt in range(self._cfg["maxRetries"] + 1):
            try:
                return await fn()
            except LlmError as err:
                if not err.retryable or attempt >= self._cfg["maxRetries"]:
                    raise
                delay = max(random.random() * min(20.0, 0.5 * 2**attempt), err.retry_after_s or 0)
                span.add_event("retry", {"attempt": attempt + 1, "error.type": err.kind, "delay_ms": round(delay * 1000)})
                await asyncio.sleep(delay)


def create_llm(cfg: dict[str, Any], adapter: LlmAdapter, prompts_dir: Path) -> Llm:
    """Composition root: create_llm(load_llm_config(path), AnthropicAdapter(settings.anthropic_api_key), prompts_dir)."""
    if cfg["provider"] != adapter.provider:
        raise ValueError(f"llm config is for {cfg['provider']!r} but the adapter is {adapter.provider!r}")
    return Llm(cfg, adapter, prompts_dir)
```

```python
# src/app/platform/llm/__init__.py
from .seam import Llm, LlmRequest, LlmResult, create_llm, load_llm_config
from .types import LlmError

__all__ = ["Llm", "LlmError", "LlmRequest", "LlmResult", "create_llm", "load_llm_config"]
```

## Composition root

```python
# src/app/main.py (excerpt)
from pathlib import Path

from app.platform.llm import create_llm, load_llm_config
from app.platform.llm.adapter_anthropic import AnthropicAdapter

root = Path(settings.project_root)  # from config.py, resolved once
llm = create_llm(
    load_llm_config(root / "config" / "llm.models.json"),
    AnthropicAdapter(settings.anthropic_api_key.get_secret_value()),
    root / "prompts",
)
```

## Tests

```python
# tests/test_llm.py
from pathlib import Path

import pytest
from pydantic import BaseModel

from app.platform.llm import LlmError, LlmRequest, create_llm
from app.platform.llm.redact import redact
from app.platform.llm import load_llm_config
from app.platform.llm.types import AdapterCall, AdapterResult, Usage


ROOT = Path(__file__).parents[1]
CFG = {**load_llm_config(ROOT / "config" / "llm.models.json"), "provider": "fake"}


def make(adapter, cfg=CFG):
    return create_llm(cfg, adapter, ROOT / "prompts")


class Summary(BaseModel):
    summary: str
    priority: int


class Fake:
    provider = "fake"

    def __init__(self, responses: list):
        self.responses, self.calls = responses, []

    async def count_tokens(self, model, system, messages):
        return (len(system) + sum(len(m["content"]) for m in messages)) // 4

    async def call(self, c: AdapterCall) -> AdapterResult:
        self.calls.append(c)
        nxt = self.responses.pop(0)
        if isinstance(nxt, Exception):
            raise nxt
        return AdapterResult(nxt, Usage(100, 20), c.model, "end_turn")


def req(**kw):
    base = dict(task="t", tier="fast", prompt_name="summarize-ticket", max_tokens=300, pii="redact", schema=Summary,
                messages=[{"role": "user", "content": "Mail jane@example.com"}])
    return LlmRequest(**{**base, **kw})


async def test_redacts_prices_and_validates():
    fake = Fake([Summary(summary="x", priority=2)])
    r = await make(fake).generate(req())
    assert "jane@example.com" not in fake.calls[0].messages[0]["content"]
    assert fake.calls[0].model == "claude-haiku-5-5"
    assert r.cost_usd == pytest.approx((100 * 0.1 + 20 * 0.5) / 1e6)


async def test_counts_tokens_on_redacted_text():
    assert await make(Fake([])).count_tokens(req()) > 0


async def test_retries_then_gives_up():
    cfg = {**CFG, "maxRetries": 2}
    ok = Fake([LlmError("overloaded", "x", 0.001), Summary(summary="x", priority=1)])
    assert (await make(ok, cfg).generate(req())).output.priority == 1
    bad = Fake([LlmError("bad_request", "x")])
    with pytest.raises(LlmError):
        await make(bad, cfg).generate(req())
    assert len(bad.calls) == 1


def test_redact_card():
    assert redact("4111 1111 1111 1111").text == "[CARD_1]"
```
