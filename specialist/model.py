"""The specialist architecture: byte-level embedding, a 2-layer transformer
encoder over a structured event context, and an attention head scoring a
fixed four-way action set.

Adapted from CUA-S1-FORMS's `TinyTransformerScorer`/`AttentionHead`
(`cua_s1/model.py`, MIT, Cua AI Inc.) at its default hyperparameters
(width=128, rank=128, layers=2, heads=4, context_tokens=224,
option_tokens=96), which is how this module reproduces its 706,048-parameter
target exactly. Their model has two branches: an entity-pointer branch for
"fill this field with that document entity" (variable option cardinality per
example) and a fixed-action branch for "check / click / skip" (constant
option cardinality). Leonard's action set (`ignore`, `wait`, `prepare`,
`suggest`) never changes size or membership, so this is the fixed-action
branch; there is no pointer mechanism here at all, `ACTIONS` is the whole
option set on every forward pass.

Context serialization format
-----------------------------
`serialize_context(event, history)` renders one event plus up to
`MAX_HISTORY_EVENTS` immediately preceding events into one deterministic
UTF-8 string. `SpecialistCollator` then byte-truncates it to `context_tokens`
(224 by default). Changing field order, a character cap, or the history
encoding changes what every existing checkpoint was trained to read, so this
format is versioned in spirit even though it carries no explicit version
field: treat any change to this function as invalidating stored checkpoints.

An `event` is a dict shaped like an `leonardd` event: `kind`, `app`,
`ts` (unix seconds), `user_state` (one of `typing`/`reading`/`idle`/
`meeting`, resolved by the caller — this module has no product-tracking
logic of its own), and `payload`, a kind-dependent dict. `history` is a
sequence of the same shape for events strictly before `event`, oldest first;
only the last `MAX_HISTORY_EVENTS` are used.

One line per field, most-discriminating-first, so byte truncation drops the
least useful information last:

    K <kind>
    A <app or ->
    T h<hour 0-23> d<weekday 0=Mon..6=Sun>
    U <user_state>
    F <actor>              sender / to / previous_app, kind-dependent
    J <title>               subject / window title, kind-dependent
    N <key>=<value> ...      numeric/boolean extras, sorted by key
    H <kind>:<action>;...    up to 5 preceding events, oldest to newest
    B <body excerpt>         body / draft / selected text / url, clipped

`F`, `J`, and `B` are populated from `_ACTOR_FIELDS`, `_TITLE_FIELDS`, and
`_BODY_FIELDS`: for each, the payload is checked for its known field names in
order and the first present one wins. `mail.arrived` (a message that landed
and has not been opened, `docs/CONTRACT.md`) maps to the same `sender`/
`subject`/`body` fields as `mail.opened`, on the assumption its payload
carries the same shape minus nothing — this is the anchor event for
`labels.rule_archived_unread` and `labels.rule_never_opened`, and without a
real sender/subject in its context those examples would train on an
almost-blank string. Free-text fields are clipped in Python
to a fixed character budget before serialization (actor 40, title 60, body
80, history 60 total), independent of the final byte-level truncation, so a
long body cannot silently push the actor or title out of the 224-byte
window.

`N` packs whichever of a small known extras vocabulary
(`thread_len`, `unread`, `idle_seconds`, `surrounding`) is present in the
payload, sorted by key for determinism; booleans render as `0`/`1`.

`hour`/`weekday` are read off `ts` in UTC, not the user's local time zone —
`event` carries no time-zone field today. This is a known simplification:
an "hour of day" signal is only useful for a day/night pattern if it tracks
the user's actual clock, so a caller that wants that signal to mean
anything should normalize `ts` to local time before calling this function,
or this module should grow a time-zone parameter. Not done here because no
caller in this package needs it to be correct yet.
"""

from __future__ import annotations

import json
import math
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import torch
from safetensors.torch import load_file, save_file
from torch import nn

ACTIONS: tuple[str, ...] = ("ignore", "wait", "prepare", "suggest")

ACTION_DESCRIPTIONS: dict[str, str] = {
    "ignore": "ignore: nothing here needs attention",
    "wait": "wait: something might need attention, but not enough is known "
    "yet, or the user is mid-task and an interruption would cost more than "
    "it is worth right now",
    "prepare": "prepare: it is worth doing background work now, but "
    "nothing should be shown to the user yet",
    "suggest": "suggest: Leonard should offer to help right now",
}

DEFAULT_CONFIG: dict[str, Any] = {
    "encoder": "tinyx",
    "width": 128,
    "rank": 128,
    "layers": 2,
    "heads": 4,
    "context_tokens": 224,
    "option_tokens": 96,
    "dropout": 0.1,
}

MAX_HISTORY_EVENTS = 5
_MAX_ACTOR_CHARS = 40
_MAX_TITLE_CHARS = 60
_MAX_BODY_CHARS = 80
_MAX_HISTORY_CHARS = 60

_ACTOR_FIELDS: dict[str, tuple[str, ...]] = {
    "mail.opened": ("sender",),
    "mail.arrived": ("sender",),
    "mail.composing": ("to",),
    "app.activated": ("previous_app",),
}
_TITLE_FIELDS: dict[str, tuple[str, ...]] = {
    "mail.opened": ("subject",),
    "mail.arrived": ("subject",),
    "mail.composing": ("subject",),
    "app.activated": ("title",),
    "window.changed": ("title",),
}
_BODY_FIELDS: dict[str, tuple[str, ...]] = {
    "mail.opened": ("body",),
    "mail.arrived": ("body",),
    "mail.composing": ("draft",),
    "text.selected": ("text",),
    "window.changed": ("url",),
}
_EXTRA_KEYS: tuple[str, ...] = ("idle_seconds", "surrounding", "thread_len", "unread")


def _clip(text: str, limit: int) -> str:
    text = " ".join(str(text).split())
    return text if len(text) <= limit else text[: limit - 1] + "…"


def _payload(event: Mapping[str, Any]) -> dict:
    payload = event.get("payload")
    return payload if isinstance(payload, dict) else {}


def _first_present(payload: Mapping[str, Any], keys: tuple[str, ...]) -> str:
    for key in keys:
        value = payload.get(key)
        if value not in (None, ""):
            return str(value)
    return ""


def _extras(payload: Mapping[str, Any]) -> str:
    parts = []
    for key in _EXTRA_KEYS:
        if key not in payload or payload[key] is None:
            continue
        value = payload[key]
        if isinstance(value, bool):
            value = int(value)
        parts.append(f"{key}={value}")
    return " ".join(parts)


def _history_token(event: Mapping[str, Any]) -> str:
    action = event.get("action") or "?"
    return f"{event.get('kind', '?')}:{action}"


def _local_hour_weekday(ts: float) -> tuple[int, int]:
    when = datetime.fromtimestamp(ts, tz=timezone.utc)
    return when.hour, when.weekday()


def serialize_context(event: Mapping[str, Any], history: Sequence[Mapping[str, Any]] = ()) -> str:
    kind = str(event.get("kind", ""))
    app = event.get("app") or "-"
    hour, weekday = _local_hour_weekday(float(event.get("ts", 0.0)))
    user_state = event.get("user_state") or "reading"
    payload = _payload(event)

    actor = _clip(_first_present(payload, _ACTOR_FIELDS.get(kind, ())), _MAX_ACTOR_CHARS)
    title = _clip(_first_present(payload, _TITLE_FIELDS.get(kind, ())), _MAX_TITLE_CHARS)
    body = _clip(_first_present(payload, _BODY_FIELDS.get(kind, ())), _MAX_BODY_CHARS)
    extras = _extras(payload)

    recent = list(history)[-MAX_HISTORY_EVENTS:]
    history_text = _clip(";".join(_history_token(item) for item in recent), _MAX_HISTORY_CHARS)

    lines = [
        f"K {kind}",
        f"A {app}",
        f"T h{hour} d{weekday}",
        f"U {user_state}",
    ]
    if actor:
        lines.append(f"F {actor}")
    if title:
        lines.append(f"J {title}")
    if extras:
        lines.append(f"N {extras}")
    if history_text:
        lines.append(f"H {history_text}")
    if body:
        lines.append(f"B {body}")
    return "\n".join(lines)


TensorBatch = dict[str, torch.Tensor]


@dataclass(frozen=True)
class SpecialistExample:
    """One serialized context and its gold action index into `ACTIONS`."""

    context: str
    label: int

    def __post_init__(self) -> None:
        if not 0 <= self.label < len(ACTIONS):
            raise ValueError(f"label must index ACTIONS, got {self.label}")


def _byte_ids(text: str, length: int) -> list[int]:
    return [byte + 1 for byte in text.encode("utf-8", errors="replace")[:length]]


class SpecialistCollator:
    """Collate serialized contexts against the fixed `ACTIONS` option set."""

    def __init__(self, context_tokens: int, option_tokens: int) -> None:
        if context_tokens <= 0 or option_tokens <= 0:
            raise ValueError("token limits must be positive")
        self.context_tokens = context_tokens
        self.option_tokens = option_tokens
        self._option_ids = [_byte_ids(ACTION_DESCRIPTIONS[a], option_tokens) for a in ACTIONS]

    def __call__(self, examples: Sequence[SpecialistExample]) -> TensorBatch:
        if not examples:
            raise ValueError("cannot collate an empty batch")
        batch = len(examples)
        contexts = [_byte_ids(item.context, self.context_tokens) for item in examples]
        max_context = max(1, max(map(len, contexts)))
        max_option = max(1, max(map(len, self._option_ids)))

        context_ids = torch.zeros((batch, max_context), dtype=torch.long)
        for row, tokens in enumerate(contexts):
            if tokens:
                context_ids[row, : len(tokens)] = torch.tensor(tokens, dtype=torch.long)

        option_ids = torch.zeros((len(ACTIONS), max_option), dtype=torch.long)
        for row, tokens in enumerate(self._option_ids):
            option_ids[row, : len(tokens)] = torch.tensor(tokens, dtype=torch.long)
        option_ids = option_ids.unsqueeze(0).expand(batch, -1, -1).contiguous()

        return {
            "context_ids": context_ids,
            "context_mask": context_ids.ne(0),
            "option_ids": option_ids,
            "option_token_mask": option_ids.ne(0),
            "option_mask": torch.ones((batch, len(ACTIONS)), dtype=torch.bool),
            "labels": torch.tensor([item.label for item in examples], dtype=torch.long),
        }


class AttentionHead(nn.Module):
    """Turn context tokens and option vectors into one score per option."""

    def __init__(self, input_width: int, rank: int) -> None:
        super().__init__()
        if input_width <= 0 or rank <= 0:
            raise ValueError("input width and attention rank must be positive")
        self.context_norm = nn.LayerNorm(input_width)
        self.option_norm = nn.LayerNorm(input_width)
        self.query = nn.Linear(input_width, rank, bias=False)
        self.key = nn.Linear(input_width, rank, bias=False)
        self.value = nn.Linear(input_width, rank, bias=False)
        self.rank = rank

    def forward(
        self,
        context: torch.Tensor,
        context_mask: torch.Tensor,
        options: torch.Tensor,
        option_mask: torch.Tensor,
    ) -> torch.Tensor:
        context = self.context_norm(context.float())
        options = self.option_norm(options.float())
        query = self.query(options)
        key = self.key(context)
        value = self.value(context)
        scores = torch.einsum("bnr,blr->bnl", query, key) / math.sqrt(self.rank)
        scores = scores.masked_fill(~context_mask[:, None, :], torch.finfo(scores.dtype).min)
        attended = torch.einsum("bnl,blr->bnr", scores.softmax(-1), value)
        logits = (query * attended).sum(-1) / math.sqrt(self.rank)
        return logits.masked_fill(~option_mask, torch.finfo(logits.dtype).min)


class SpecialistScorer(nn.Module):
    """Byte-level context and option transformer encoders sharing one
    `AttentionHead`, scoring the fixed `ACTIONS` set for one event."""

    def __init__(
        self,
        width: int = 128,
        rank: int = 128,
        context_tokens: int = 224,
        option_tokens: int = 96,
        layers: int = 2,
        heads: int = 4,
        dropout: float = 0.1,
    ) -> None:
        super().__init__()
        if min(width, rank, context_tokens, option_tokens, layers, heads) <= 0:
            raise ValueError("model dimensions and layer counts must be positive")
        if width % heads:
            raise ValueError("model width must be divisible by attention heads")
        if not 0.0 <= dropout < 1.0:
            raise ValueError("dropout must be in [0, 1)")
        self.embedding = nn.Embedding(257, width, padding_idx=0)
        self.position = nn.Embedding(max(context_tokens, option_tokens), width)
        context_layer = nn.TransformerEncoderLayer(
            width, heads, width * 4, dropout, batch_first=True, norm_first=True
        )
        self.encoder = nn.TransformerEncoder(context_layer, layers, enable_nested_tensor=False)
        option_layer = nn.TransformerEncoderLayer(
            width, heads, width * 4, dropout, batch_first=True, norm_first=True
        )
        self.option_encoder = nn.TransformerEncoder(option_layer, 1, enable_nested_tensor=False)
        self.head = AttentionHead(width, rank)

    def _embed(self, ids: torch.Tensor) -> torch.Tensor:
        positions = torch.arange(ids.shape[-1], device=ids.device)
        return self.embedding(ids) + self.position(positions)

    def forward(self, batch: TensorBatch) -> torch.Tensor:
        context_mask = batch["context_mask"]
        safe_context_mask = context_mask.clone()
        safe_context_mask[:, 0] = True
        context = self.encoder(
            self._embed(batch["context_ids"]), src_key_padding_mask=~safe_context_mask
        )

        option_ids = batch["option_ids"]
        batch_size, option_count, token_count = option_ids.shape
        flat_ids = option_ids.reshape(batch_size * option_count, token_count)
        flat_mask = batch["option_token_mask"].reshape(batch_size * option_count, token_count)
        safe_mask = flat_mask.clone()
        safe_mask[:, 0] = True
        hidden = self.option_encoder(self._embed(flat_ids), src_key_padding_mask=~safe_mask)
        weights = flat_mask.unsqueeze(-1).float()
        pooled = (hidden * weights).sum(1) / weights.sum(1).clamp_min(1)
        options = pooled.reshape(batch_size, option_count, -1)

        return self.head(context, context_mask, options, batch["option_mask"])


def make_model(config: Mapping[str, Any] = DEFAULT_CONFIG) -> tuple[SpecialistScorer, SpecialistCollator]:
    model = SpecialistScorer(
        width=int(config.get("width", 128)),
        rank=int(config.get("rank", 128)),
        context_tokens=int(config.get("context_tokens", 224)),
        option_tokens=int(config.get("option_tokens", 96)),
        layers=int(config.get("layers", 2)),
        heads=int(config.get("heads", 4)),
        dropout=float(config.get("dropout", 0.1)),
    )
    collator = SpecialistCollator(
        int(config.get("context_tokens", 224)), int(config.get("option_tokens", 96))
    )
    return model, collator


def parameter_count(model: nn.Module) -> int:
    return sum(p.numel() for p in model.parameters() if p.requires_grad)


def save_checkpoint(path: str | Path, model: nn.Module, config: Mapping[str, Any]) -> None:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    state = {name: p.detach().cpu().contiguous() for name, p in model.state_dict().items()}
    save_file(state, str(path))
    path.with_suffix(".json").write_text(json.dumps(dict(config), indent=2, sort_keys=True))


def load_checkpoint(path: str | Path) -> tuple[SpecialistScorer, SpecialistCollator, dict[str, Any]]:
    path = Path(path)
    config = json.loads(path.with_suffix(".json").read_text())
    model, collator = make_model(config)
    state = load_file(str(path))
    model.load_state_dict(state)
    model.eval()
    return model, collator, config


__all__ = [
    "ACTIONS",
    "ACTION_DESCRIPTIONS",
    "DEFAULT_CONFIG",
    "MAX_HISTORY_EVENTS",
    "serialize_context",
    "SpecialistExample",
    "SpecialistCollator",
    "AttentionHead",
    "SpecialistScorer",
    "make_model",
    "parameter_count",
    "save_checkpoint",
    "load_checkpoint",
]
