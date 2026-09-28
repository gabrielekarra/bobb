"""A resident causal LM exposed for constrained single-position readout.

`decide.py` branches off one `prefill`: fork the cache per question, `step`
once, read logits. No token is ever generated or decoded back to text; the
model's output surface here is a probability distribution, not a string.

`HF_HUB_OFFLINE` is forced before `huggingface_hub` is imported anywhere in
the process, so loading a checkpoint already in the local cache touches no
network, and a checkpoint that is not cached fails loudly instead of
fetching one. This is the daemon's only contact with model weights and it
must never phone home.
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Protocol, runtime_checkable

import numpy as np

os.environ.setdefault("HF_HUB_OFFLINE", "1")
os.environ.setdefault("TRANSFORMERS_OFFLINE", "1")
os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")

import mlx.core as mx  # noqa: E402
from mlx_lm.models.cache import make_prompt_cache  # noqa: E402
from mlx_lm.utils import load  # noqa: E402

Cache = Any

DEFAULT_MODELS_DIR = Path(
    os.environ.get(
        "LEONARD_MODELS_DIR",
        Path(__file__).resolve().parents[2] / ".runtime" / "models",
    )
)


def resolve_local(model_id: str, models_dir: Path = DEFAULT_MODELS_DIR) -> str:
    """A checkpoint directory for `model_id`, or `model_id` unchanged.

    Weights fetched with `local_dir` leave only a ref stub in the Hugging Face
    hub cache, so an offline `load()` of the repo id fails even though the
    files are on disk. Checkpoints are resolved from the project's own
    `.runtime/models` first for that reason, and so that the daemon does not
    depend on any other tree for its weights.
    """
    if Path(model_id).is_dir():
        return model_id
    local = models_dir / model_id.split("/")[-1]
    if (local / "config.json").is_file():
        return str(local)
    return model_id


@runtime_checkable
class Engine(Protocol):
    name: str
    vocab_size: int

    def encode(self, text: str, *, add_special: bool = False) -> list[int]:
        """Tokenize `text`. `add_special` adds BOS/template markers."""

    def decode_text(self, ids: list[int]) -> str:
        """Inverse of `encode`, used only to build the letter->token table."""

    def prefill(self, ids: list[int]) -> Cache:
        """Run `ids` once and return a cache positioned after them."""

    def fork(self, cache: Cache) -> Cache:
        """Independent copy of `cache`; must not alias the parent's buffers."""

    def chat_frame(self, system: str) -> tuple[str, str]:
        """(head, tail) this model's chat template wraps around user content."""

    def step_many(self, cache: Cache, id_lists: list[list[int]]) -> np.ndarray:
        """Advance K branches of one shared `cache` together; float32 logits
        of shape (K, vocab_size), each row read at its own last real token."""

    def step(self, cache: Cache, ids: list[int]) -> np.ndarray:
        """Advance `cache` by `ids`; float32 logits of shape (vocab_size,)."""


def _clone_cache_entry(entry: Any) -> Any:
    clone = entry.__class__.__new__(entry.__class__)
    for key, value in vars(entry).items():
        clone.__dict__[key] = mx.array(value) if isinstance(value, mx.array) else value
    return clone


@dataclass
class _State:
    kv: list[Any]
    logits: mx.array


class ResidentMLX:
    """A 4-bit MLX checkpoint held fully in unified memory.

    Resolved by `resolve_local`, then loaded offline; see the module docstring
    for the offline guarantee.
    """

    def __init__(self, model_id: str):
        self.model, self.tokenizer, config = load(
            resolve_local(model_id), return_config=True
        )
        self.name = model_id
        self.vocab_size = int(config["vocab_size"])

    def encode(self, text: str, *, add_special: bool = False) -> list[int]:
        return self.tokenizer.encode(text, add_special_tokens=add_special)

    def decode_text(self, ids: list[int]) -> str:
        return self.tokenizer.decode(ids)

    def prefill(self, ids: list[int]) -> _State:
        kv = make_prompt_cache(self.model)
        logits = self.model(mx.array(ids, dtype=mx.int32)[None], cache=kv)
        last = logits[0, -1].astype(mx.float32)
        mx.eval(last, [c.state for c in kv])
        return _State(kv=kv, logits=last)

    def chat_frame(self, system: str) -> tuple[str, str]:
        sentinel = "\x00LEONARD_CONTENT\x00"
        user = {"role": "user", "content": sentinel}
        attempts: list[list[dict]] = []
        if system:
            attempts.append([{"role": "system", "content": system}, user])
            attempts.append([{"role": "user", "content": system + "\n\n" + sentinel}])
        else:
            attempts.append([user])
        for messages in attempts:
            for extra in ({"enable_thinking": False}, {}):
                try:
                    rendered = self.tokenizer.apply_chat_template(
                        messages, tokenize=False, add_generation_prompt=True, **extra
                    )
                except Exception:
                    continue
                head, found, tail = rendered.partition(sentinel)
                if found:
                    return head, tail
        raise NotImplementedError(f"{self.name} has no usable chat template")

    def fork(self, cache: _State) -> _State:
        return _State(
            kv=[_clone_cache_entry(c) for c in cache.kv],
            logits=mx.array(cache.logits),
        )

    def step_many(self, cache: _State, id_lists: list[list[int]]) -> np.ndarray:
        if not id_lists:
            return np.empty((0, self.vocab_size), dtype=np.float32)
        rows = len(id_lists)
        width = max(len(ids) for ids in id_lists)
        if width == 0:
            raise ValueError("step_many needs at least one token per branch")
        padded = [list(ids) + [0] * (width - len(ids)) for ids in id_lists]
        batched = []
        for entry in cache.kv:
            clone = entry.__class__.__new__(entry.__class__)
            for key, value in vars(entry).items():
                clone.__dict__[key] = (
                    mx.repeat(value, rows, axis=0)
                    if isinstance(value, mx.array) and value.ndim == 4
                    else (mx.array(value) if isinstance(value, mx.array) else value)
                )
            batched.append(clone)
        out = self.model(mx.array(padded, dtype=mx.int32), cache=batched)
        logits = out.logits if hasattr(out, "logits") else out
        picked = mx.stack(
            [logits[i, len(ids) - 1] for i, ids in enumerate(id_lists)]
        ).astype(mx.float32)
        mx.eval(picked)
        return np.array(picked, copy=True)

    def step(self, cache: _State, ids: list[int]) -> np.ndarray:
        if ids:
            logits = self.model(mx.array(ids, dtype=mx.int32)[None], cache=cache.kv)
            cache.logits = logits[0, -1].astype(mx.float32)
            mx.eval(cache.logits, [c.state for c in cache.kv])
        return np.array(cache.logits, copy=True)


__all__ = ["Cache", "Engine", "ResidentMLX"]
