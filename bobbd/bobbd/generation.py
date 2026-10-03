"""The one place the daemon generates text.

Everywhere else the resident model is read at a single logit position and
never sampled from. Generation happens only after an explicit request from
the user — "Prepare", or a question typed into the command bar — and the
result is handed back to the app for review. The daemon never sends,
posts or submits anything it wrote.

Streaming is the product: a draft that appears word by word in 300 ms feels
like a colleague typing; the same draft appearing all at once after four
seconds feels like a hung app. `stream_text` calls `on_delta` with each
decoded piece and checks `cancel` between tokens, so a closed panel stops
the work instead of finishing it for nobody.
"""

from __future__ import annotations

import re
import threading
import time
from collections.abc import Callable
from dataclasses import dataclass
from typing import Protocol, runtime_checkable

DEFAULT_TEMPERATURE = 0.3
DEFAULT_TOP_P = 0.9


@runtime_checkable
class GenerativeEngine(Protocol):
    model: object
    tokenizer: object


def supports_generation(engine: object) -> bool:
    return hasattr(engine, "model") and hasattr(engine, "tokenizer")


@dataclass(frozen=True)
class Generated:
    text: str
    tokens: int
    latency_ms: float
    first_token_ms: float | None
    cancelled: bool
    finish_reason: str | None


class GenerationUnavailable(RuntimeError):
    """The engine cannot generate (a test double, or no model loaded)."""


class _GenerationCancelled(Exception):
    """Stop MLX at a prompt-processing boundary before the first output token."""


def render_prompt(engine: GenerativeEngine, messages: list[dict]) -> str:
    try:
        return engine.tokenizer.apply_chat_template(messages, tokenize=False, add_generation_prompt=True, enable_thinking=False)
    except Exception:
        # A template that rejects a system role gets it folded into the
        # first user turn instead, the same fallback `ResidentMLX.chat_frame`
        # uses for readouts.
        if messages and messages[0]["role"] == "system":
            system, rest = messages[0]["content"], messages[1:]
            if rest and rest[0]["role"] == "user":
                rest = [{"role": "user", "content": system + "\n\n" + rest[0]["content"]}] + rest[1:]
            return engine.tokenizer.apply_chat_template(rest, tokenize=False, add_generation_prompt=True, enable_thinking=False)
        raise


def stream_text(
    engine: object,
    messages: list[dict],
    *,
    max_tokens: int = 400,
    on_delta: Callable[[str], None] | None = None,
    cancel: threading.Event | None = None,
    temperature: float = DEFAULT_TEMPERATURE,
    prefix: str = "",
    interruptible_prefill: bool = False,
) -> Generated:
    """Generate a reply to `messages`. A non-empty `prefix` is placed at the
    start of the assistant turn before generation, streamed first, and is
    part of the returned text."""
    if not supports_generation(engine):
        raise GenerationUnavailable("this engine cannot generate text")
    if cancel is not None and cancel.is_set():
        return Generated("", 0, 0.0, None, True, "cancelled")
    from mlx_lm import stream_generate
    from mlx_lm.sample_utils import make_logits_processors, make_sampler

    prompt = render_prompt(engine, messages)  # type: ignore[arg-type]
    if prefix:
        prompt += prefix
    sampler = make_sampler(temp=temperature, top_p=DEFAULT_TOP_P if temperature > 0 else 0.0)
    processors = make_logits_processors(repetition_penalty=1.1)
    started = time.perf_counter()
    first_token_ms = None
    pieces: list[str] = []
    if prefix:
        pieces.append(prefix)
        if on_delta is not None:
            on_delta(prefix)
    tokens = 0
    finish_reason = None
    cancelled = False
    def prompt_progress(processed: int, total: int) -> None:
        if cancel is not None and cancel.is_set():
            raise _GenerationCancelled

    # Foreground work retains MLX's normal large prefill for throughput.
    # Background preparation yields between small chunks so a new request
    # does not wait for an entire screen context to reach its first token.
    responses = stream_generate(
        engine.model,  # type: ignore[attr-defined]
        engine.tokenizer,  # type: ignore[attr-defined]
        prompt,
        max_tokens=max_tokens,
        sampler=sampler,
        logits_processors=processors,
        prefill_step_size=128 if interruptible_prefill else 2048,
        prompt_progress_callback=prompt_progress,
    )
    try:
        for response in responses:
            if cancel is not None and cancel.is_set():
                cancelled = True
                break
            tokens += 1
            if response.text:
                if first_token_ms is None:
                    first_token_ms = (time.perf_counter() - started) * 1000
                pieces.append(response.text)
                if on_delta is not None:
                    on_delta(response.text)
            finish_reason = response.finish_reason
    except _GenerationCancelled:
        cancelled = True
        finish_reason = "cancelled"
    finally:
        responses.close()
    return Generated(
        text=clean("".join(pieces)),
        tokens=tokens,
        latency_ms=(time.perf_counter() - started) * 1000,
        first_token_ms=first_token_ms,
        cancelled=cancelled,
        finish_reason=finish_reason,
    )


_PREAMBLES = (
    "here is the reply:",
    "here's the reply:",
    "here is a draft:",
    "here's a draft:",
    "here is the rewritten draft:",
    "ecco la risposta:",
    "ecco una bozza:",
    "ecco la bozza:",
)


_LEAD_IN = re.compile(r"(?i)^(ecco|here is|here's|here are|sure|certo|certamente)\b[^\n]{0,80}:\s*\n")
_SUBJECT_LINE = re.compile(r"(?i)^(subject|oggetto)\s*:[^\n]*\n+")


def clean(text: str) -> str:
    """Strip what small models like to add around the thing asked for: a
    lead-in line ("Here is the reply:"), a subject line nobody asked for,
    and wrapping quotes."""
    text = text.strip()
    lowered = text.lower()
    for preamble in _PREAMBLES:
        if lowered.startswith(preamble):
            text = text[len(preamble) :].lstrip()
            break
    text = _LEAD_IN.sub("", text, count=1).lstrip()
    text = _SUBJECT_LINE.sub("", text, count=1).lstrip()
    if len(text) >= 2 and text[0] == text[-1] == '"':
        text = text[1:-1].strip()
    return text


__all__ = [
    "GenerativeEngine",
    "Generated",
    "GenerationUnavailable",
    "supports_generation",
    "stream_text",
    "render_prompt",
    "clean",
]
