"""Reply-draft generation: the one place in the daemon that generates text.

Everywhere else the resident model is read at a single logit position and
never sampled from. `draft_reply` is the exception, kept to this module on
purpose: it runs only after the user has explicitly approved a suggestion,
via `mlx_lm.generate`, autoregressively, against the model's own chat
template. The draft is handed back to the app for review; it is never sent
anywhere by the daemon itself.
"""

from __future__ import annotations

from typing import Protocol, runtime_checkable

from mlx_lm import generate as _mlx_generate

DEFAULT_MAX_TOKENS = 180

_SYSTEM = (
    "You draft a reply to an email on the user's behalf, to be reviewed before "
    "sending. Write only the reply body: no subject line, no headers, no "
    "placeholder text in brackets, no explanation of what you wrote. Reply in "
    "the same language as the original message. Keep it as short as the "
    "message warrants."
)


@runtime_checkable
class GenerativeEngine(Protocol):
    model: object
    tokenizer: object


def supports_generation(engine: object) -> bool:
    return hasattr(engine, "model") and hasattr(engine, "tokenizer")


def _payload(event: dict) -> dict:
    payload = event.get("payload")
    return payload if isinstance(payload, dict) else {}


def _prompt(engine: GenerativeEngine, event: dict) -> str:
    p = _payload(event)
    user = (
        f"From: {p.get('sender', 'unknown sender')}\n"
        f"Subject: {p.get('subject', '(no subject)')}\n\n"
        f"{p.get('body', '')}\n\n"
        "Write the reply."
    )
    messages = [
        {"role": "system", "content": _SYSTEM},
        {"role": "user", "content": user},
    ]
    return engine.tokenizer.apply_chat_template(
        messages, tokenize=False, add_generation_prompt=True
    )


def draft_reply(engine: GenerativeEngine, event: dict, *, max_tokens: int = DEFAULT_MAX_TOKENS) -> str:
    prompt = _prompt(engine, event)
    text = _mlx_generate(engine.model, engine.tokenizer, prompt, max_tokens=max_tokens)
    return text.strip()


__all__ = ["draft_reply", "supports_generation", "GenerativeEngine", "DEFAULT_MAX_TOKENS"]
