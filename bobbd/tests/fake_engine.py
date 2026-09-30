"""Deterministic Engine doubles for model-free tests. No MLX anywhere here."""

from __future__ import annotations

import itertools
import string

import numpy as np

_LETTERS = string.ascii_uppercase
_name_counter = itertools.count()


class FakeEngine:
    """Whitespace-tokenizing Engine double with scripted logits.

    Bare letters "A".."Z" get reserved ids 0-25, space-prefixed letters
    " A".." Z" get ids 100-125 (mirroring a real BPE vocab, where the two
    forms are different token ids and a real model's mass after a suffix
    ending in ":" lands almost entirely on the spaced form). Everything else
    is a lazily assigned id >= 1000. `decode_text` inverts all three ranges.
    """

    def __init__(self, logits_fn, vocab_size: int = 4096):
        self.name = f"fake-{next(_name_counter)}"
        self.vocab_size = vocab_size
        self._vocab: dict[str, int] = {}
        self._reverse: dict[int, str] = {}
        self._next_id = 1000
        self._bos = 999
        self.prefill_calls = 0
        self.fork_calls = 0
        self.step_calls: list[list[int]] = []
        self._logits_fn = logits_fn

    def _token_id(self, token: str) -> int:
        if token not in self._vocab:
            token_id = self._next_id
            self._next_id += 1
            self._vocab[token] = token_id
            self._reverse[token_id] = token
        return self._vocab[token]

    def encode(self, text, *, add_special: bool = False):
        ids = [self._token_id(tok) for tok in text.split()]
        if add_special:
            ids = [self._bos] + ids
        return ids

    def decode_text(self, ids):
        parts = []
        for i in ids:
            if 0 <= i < 26:
                parts.append(_LETTERS[i])
            elif 100 <= i < 126:
                parts.append(" " + _LETTERS[i - 100])
            else:
                parts.append(self._reverse.get(i, f"<{i}>"))
        return "".join(parts)

    def prefill(self, ids):
        self.prefill_calls += 1
        return list(ids)

    def fork(self, cache):
        self.fork_calls += 1
        return list(cache)

    def step(self, cache, ids):
        cache.extend(ids)
        self.step_calls.append(list(cache))
        return self._logits_fn(list(cache))


class BatchedFakeEngine(FakeEngine):
    """A FakeEngine that answers K branches in one call, like ResidentMLX."""

    def __init__(self, logits_fn, vocab_size: int = 4096):
        super().__init__(logits_fn, vocab_size)
        self.step_many_calls: list[list[list[int]]] = []

    def step_many(self, cache, id_lists):
        self.step_many_calls.append([list(ids) for ids in id_lists])
        return np.stack([self._logits_fn(list(cache) + list(ids)) for ids in id_lists])


class TrivialEngine:
    """The minimum viable Engine: fixed encoding, all-zero logits.

    Used where the test replaces `decide_many` itself and only needs `prime`
    (encode + prefill) to succeed without asserting anything about content.
    """

    def __init__(self, vocab_size: int = 64):
        self.name = f"trivial-{next(_name_counter)}"
        self.vocab_size = vocab_size

    def encode(self, text, *, add_special: bool = False):
        return [1, 2, 3]

    def decode_text(self, ids):
        return ""

    def prefill(self, ids):
        return list(ids)

    def fork(self, cache):
        return list(cache)

    def step(self, cache, ids):
        return np.zeros(self.vocab_size, dtype=np.float32)


def peaked_logits(vocab_size: int, high_index: int, high: float = 10.0, low: float = -10.0) -> np.ndarray:
    logits = np.full(vocab_size, low, dtype=np.float32)
    logits[high_index] = high
    return logits


def logits_at(vocab_size: int, values: dict, baseline: float = -10.0) -> np.ndarray:
    logits = np.full(vocab_size, baseline, dtype=np.float32)
    for index, value in values.items():
        logits[index] = value
    return logits


def queued(*arrays):
    it = iter(arrays)
    return lambda cache: next(it)
