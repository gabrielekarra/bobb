"""Constrained readout: one prefill, K forked single-step reads.

Every option, regardless of question kind, is presented behind an arbitrary
single letter (A, B, C, ...) and the readout only ever inspects logits at
that letter's tokens. This sidesteps the multi-token-option problem rather
than solving it: option text may tokenize to several tokens, or share a
first token with another option, but the model is never read off its own
generated text, only off the letter that precedes it in the prompt.

The letter is not one fixed token id. A real tokenizer represents "A" and
" A" (space-prefixed) as different ids, and after a suffix ending in ":" the
model's actual mass lands on the space-prefixed variant almost entirely.
`encode("A")` alone can land on a token holding near-zero probability,
turning `confidence` into renormalized noise. So the mapping from letter to
token ids is built the other way: scan the vocab once with `decode_text`,
keep every id whose decoded, stripped text equals that letter, and sum
softmax mass over the whole set. Cached per `engine.name`.

Layering, when `primed` is supplied (see `prime()`):
  L1 - the fixed system/schema prefix, prefilled once by the caller and
       reused across many calls via `primed`. Never reprocessed here.
  L2 - the per-call `context`, forked off `primed` and stepped once.
  L3 - each question's suffix, forked (or batched) off the L2 cache.
Without `primed`, L1 and L2 collapse into one `prefill(context)`.
"""

from __future__ import annotations

import string
import time
from collections.abc import Sequence

import numpy as np

from .engine import Cache, Engine
from .schema import Bool, Choice, Decision, Question, Score, decision_key

_LETTERS = string.ascii_uppercase

_LETTER_TABLE_CACHE: dict[str, dict[str, list[int]]] = {}


def _letter_table(engine: Engine) -> dict[str, list[int]]:
    cached = _LETTER_TABLE_CACHE.get(engine.name)
    if cached is not None:
        return cached
    table: dict[str, list[int]] = {letter: [] for letter in _LETTERS}
    for token_id in range(engine.vocab_size):
        text = engine.decode_text([token_id]).strip()
        if text in table:
            table[text].append(token_id)
    _LETTER_TABLE_CACHE[engine.name] = table
    return table


def _letter_id_sets(table: dict[str, list[int]], n: int) -> list[list[int]]:
    if n > len(_LETTERS):
        raise ValueError(f"cannot disambiguate {n} options with single-letter labels (max {len(_LETTERS)})")
    sets = []
    seen: set[int] = set()
    for letter in _LETTERS[:n]:
        ids = table.get(letter, [])
        if not ids:
            raise ValueError(
                f"letter {letter!r} has no matching token under this tokenizer; "
                "the letter-readout scheme cannot disambiguate this schema"
            )
        overlap = seen.intersection(ids)
        if overlap:
            raise ValueError(
                f"letter {letter!r} shares token ids {sorted(overlap)} with an earlier "
                "letter; cannot disambiguate"
            )
        seen.update(ids)
        sets.append(ids)
    return sets


def _cast_value(question: Question, label: str) -> str | int | bool:
    if isinstance(question, Choice):
        return label
    if isinstance(question, Score):
        return int(label)
    if isinstance(question, Bool):
        return label == "true"
    raise TypeError(f"unknown question type {type(question)!r}")


_FRAMES: dict[tuple[str, str], tuple[str, str]] = {}


def _chat_frame(engine: Engine, system: str) -> tuple[str, str]:
    key = (engine.name, system)
    if key not in _FRAMES:
        make = getattr(engine, "chat_frame", None)
        try:
            _FRAMES[key] = make(system) if make else ("", "")
        except NotImplementedError:
            _FRAMES[key] = ("", "")
    return _FRAMES[key]


_SYSTEM = "You classify inputs. Answer with a single letter and nothing else."


def _suffix_text(question: Question) -> str:
    lines = "\n".join(f"{_LETTERS[i]}. {label}" for i, label in enumerate(question.labels))
    return f"\n\n{question.prompt}\n{lines}\nAnswer with a single letter:"


def _softmax(x: np.ndarray) -> np.ndarray:
    shifted = x - np.max(x)
    exp = np.exp(shifted)
    return exp / exp.sum()


def _length_buckets(suffixes: list[list[int]], slack: float = 4.0) -> list[list[int]]:
    """Group suffix indices so one batched forward doesn't pad pathologically.

    Measured on the resident model on an M4: `step_many` batching a
    same-width row K times costs ~96% of K sequential single-row calls, not
    the ~1/K a memory-bound decode would predict, because prefill at these
    context lengths is compute- not bandwidth-bound on this GPU (cost tracks
    total tokens processed, batched or not; see `leonardd/results/`). So a
    tight `slack` buys nothing worth protecting — the questions Leonard asks
    (2 to ~8 options) pad to single digits of wasted tokens either way, and
    splitting them into more forward calls only adds call overhead. `slack`
    is loose enough to keep everything in one bucket for any realistic
    schema and only splits a pathologically wide outlier.
    """
    order = sorted(range(len(suffixes)), key=lambda i: len(suffixes[i]))
    buckets: list[list[int]] = []
    for index in order:
        if buckets:
            current = buckets[-1]
            widest = max(len(suffixes[i]) for i in current + [index])
            total = sum(len(suffixes[i]) for i in current) + len(suffixes[index])
            if widest * (len(current) + 1) <= slack * total:
                current.append(index)
                continue
        buckets.append([index])
    return buckets


def prime(engine: Engine, system_prefix: str) -> Cache:
    """Prefill the fixed system/schema prefix once, reused via `primed`."""
    head, _ = _chat_frame(engine, system_prefix)
    if head:
        return engine.prefill(engine.encode(head, add_special=False))
    return engine.prefill(engine.encode(system_prefix, add_special=True))


def decide(
    engine: Engine,
    context: str,
    question: Question,
    *,
    calibrator=None,
    primed: Cache | None = None,
) -> Decision:
    return decide_many(engine, context, [question], calibrators=[calibrator], primed=primed)[0]


def decide_many(
    engine: Engine,
    context: str,
    questions: Sequence[Question],
    *,
    calibrators: Sequence | None = None,
    primed: Cache | None = None,
) -> list[Decision]:
    if not questions:
        return []
    if calibrators is None:
        calibrators = [None] * len(questions)
    elif len(calibrators) != len(questions):
        raise ValueError("calibrators must have the same length as questions")

    table = _letter_table(engine)
    letter_sets = [_letter_id_sets(table, len(q.labels)) for q in questions]

    if primed is None:
        head, _ = _chat_frame(engine, _SYSTEM)
        if head:
            context_ids = engine.encode(head + context, add_special=False)
        else:
            context_ids = engine.encode(context, add_special=True)
        base_cache = engine.prefill(context_ids)
    else:
        context_ids = engine.encode(context, add_special=False)
        base_cache = engine.fork(primed)
        engine.step(base_cache, context_ids)

    _, tail = _chat_frame(engine, _SYSTEM)
    suffixes = [engine.encode(_suffix_text(q) + tail, add_special=False) for q in questions]

    batched = getattr(engine, "step_many", None)
    started = time.perf_counter()
    if batched is not None and len(questions) > 1:
        all_logits: list[np.ndarray | None] = [None] * len(suffixes)
        for bucket in _length_buckets(suffixes):
            rows = batched(base_cache, [suffixes[i] for i in bucket])
            for slot, index in enumerate(bucket):
                all_logits[index] = rows[slot]
        stacked = np.stack(all_logits)
    else:
        stacked = np.stack([engine.step(engine.fork(base_cache), ids) for ids in suffixes])
    shared_ms = (time.perf_counter() - started) * 1000 / len(questions)

    decisions = []
    for index, (question, calibrator) in enumerate(zip(questions, calibrators)):
        start = time.perf_counter()

        labels = question.labels
        letter_id_sets = letter_sets[index]
        logits = np.asarray(stacked[index])

        full_probs = _softmax(logits.astype(np.float64))
        group_mass = np.array([full_probs[ids].sum() for ids in letter_id_sets], dtype=np.float64)
        schema_mass = float(group_mass.sum())
        if schema_mass <= 0.0:
            raise ValueError(f"no probability mass landed on any option letter for {question.name!r}")
        raw_probs = group_mass / schema_mass
        raw_probabilities = dict(zip(labels, (float(p) for p in raw_probs)))

        best = int(np.argmax(raw_probs))
        value = _cast_value(question, labels[best])

        if calibrator is None:
            calibrated = raw_probs
        else:
            calibrated = np.asarray(
                calibrator.transform(raw_probs.reshape(1, -1)), dtype=np.float64
            ).reshape(-1)
            if calibrated.shape != raw_probs.shape:
                raise ValueError("calibrator.transform must preserve the option count")
            calibrated = calibrated / calibrated.sum()
        probabilities = dict(zip(labels, (float(p) for p in calibrated)))

        latency_ms = shared_ms + (time.perf_counter() - start) * 1000
        decisions.append(
            Decision(
                name=question.name,
                kind=question.kind,
                value=value,
                probabilities=probabilities,
                raw_probabilities=raw_probabilities,
                confidence=probabilities[decision_key(question.kind, value)],
                schema_mass=schema_mass,
                latency_ms=latency_ms,
            )
        )
    return decisions


__all__ = ["decide", "decide_many", "prime"]
