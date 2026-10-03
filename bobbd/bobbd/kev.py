"""Kev's trained pointer decisions on a local, merged 8-bit MLX checkpoint.

No server, client SDK, API key or generation is involved. The encoder, hybrid
backbone and pointer head are Kev's upstream inference code (vendored with its
license). Qwen's chat model is used only by generation.py. Bobb's confidence
contract remains the selected answer's probability, rather than TypeSafe's
separate relative-to-uniform confidence metric.
"""
from __future__ import annotations

import hashlib
import json
import time
from pathlib import Path

import numpy as np

from .schema import Bool, Choice, Decision, Score

DEFAULT_DECISION_MODEL = "RoderickQiu/kev-4b-mlx-8bit"
HEAD_SHA256 = "dd633435998ecc751ac538717a3742e32149500fabf7d7276287dbf0693f347c"
MAX_STATE_TOKENS = 4096
MAX_ROW_TOKENS = 8192


def _softmax(logits):
    logits = np.asarray(logits, dtype=np.float64)
    values = np.exp(logits - logits.max())
    return values / values.sum()


def _value(question, label):
    if isinstance(question, Bool):
        return label == "true"
    if isinstance(question, Score):
        return int(label)
    if isinstance(question, Choice):
        return label
    raise TypeError(f"unsupported question type: {type(question).__name__}")


def record_for(context, questions, *, system=""):
    records, owners = [], []
    for index, question in enumerate(questions):
        # Kev Noul uses no/yes in this order. Score labels are kept at Bobb's
        # actual lo..hi values; the head points to options, not label tokens.
        options = ["no", "yes"] if isinstance(question, Bool) else list(question.labels)
        if not 1 <= len(options) <= 255:
            raise ValueError("Kev supports 1..255 options per question")
        records.append({"instr": question.prompt, "options": options, "label": 0})
        owners.append((index, False))
        if getattr(question, "debias", False):
            records.append({"instr": question.prompt, "options": options[::-1], "label": 0})
            owners.append((index, True))
    return {"state": context if not system else system + "\n\n" + context, "questions": records}, owners


def decisions_from_logits(questions, owners, logits, *, temperature, calibrators, elapsed_ms):
    grouped = {}
    for (index, reversed_order), row in zip(owners, logits, strict=True):
        raw = _softmax(row * temperature)
        calibrated = _softmax(row)
        if reversed_order:
            raw, calibrated = raw[::-1], calibrated[::-1]
        grouped.setdefault(index, []).append((raw, calibrated))
    decisions = []
    for index, (question, calibrator) in enumerate(zip(questions, calibrators, strict=True)):
        labels = question.labels
        raw = np.mean([r for r, _ in grouped[index]], axis=0)
        probabilities = np.mean([p for _, p in grouped[index]], axis=0)
        if calibrator is not None:
            probabilities = np.asarray(calibrator.transform(probabilities[None]), dtype=np.float64).reshape(-1)
        if len(probabilities) != len(labels) or not np.isfinite(probabilities).all() or np.any(probabilities < 0) or probabilities.sum() <= 0:
            raise ValueError("invalid Kev probability distribution")
        probabilities = probabilities / probabilities.sum()
        raw = raw / raw.sum()
        best = int(np.argmax(probabilities))
        decisions.append(Decision(
            name=question.name, kind=question.kind, value=_value(question, labels[best]),
            probabilities=dict(zip(labels, map(float, probabilities), strict=True)),
            raw_probabilities=dict(zip(labels, map(float, raw), strict=True)),
            confidence=float(probabilities[best]),
            # The pointer head is structurally restricted to these options.
            schema_mass=1.0, latency_ms=elapsed_ms / len(questions),
        ))
    return decisions


class KevDecisionBackend:
    name = DEFAULT_DECISION_MODEL

    def __init__(self, model_id=DEFAULT_DECISION_MODEL):
        from .engine import resolve_local
        import mlx.core as mx
        import torch
        from mlx_lm.utils import load_model
        from transformers import AutoTokenizer
        from .vendor.kev import mlx_model
        from .vendor.kev.model import PointerHead, pad_id

        path = Path(resolve_local(model_id))
        if not path.is_dir():
            raise FileNotFoundError(f"Kev is not installed: {model_id}")
        head_path = path / "head.pt"
        with head_path.open("rb") as source:
            if hashlib.file_digest(source, "sha256").hexdigest() != HEAD_SHA256:
                raise ValueError("Kev pointer head checksum mismatch")
        metadata = torch.load(head_path, map_location="cpu", weights_only=True)
        config = json.loads((path / "config.json").read_text())
        if config.get("quantization", {}).get("bits") != 8:
            raise ValueError("Bobb's default Kev checkpoint must be the merged 8-bit model")
        self.tokenizer = AutoTokenizer.from_pretrained(path, local_files_only=True)
        lm = load_model(path)[0]
        # Consumer memory budget: bounded prefill and one question branch at
        # a time, rather than duplicating the recurrent cache across a batch.
        mlx_model.PREFILL_CHUNK = 512
        mx.set_cache_limit(256 << 20)
        self.model = mlx_model.MLXDecisionModel(lm, pad_id(self.tokenizer), head_dim=metadata["head_dim"])
        # Quantized embeddings pack their second dimension. Size the head
        # from the architecture, preserving the trained fp32 head exactly.
        self.model.head = PointerHead(config["text_config"]["hidden_size"], dp=metadata["head_dim"]).eval()
        self.model.head.load_state_dict(metadata["head"], strict=True)
        self.model.head.temperature = float(metadata.get("temperature", 1.0))
        if not np.isfinite(self.model.head.temperature) or self.model.head.temperature <= 0:
            raise ValueError("invalid Kev calibration temperature")
        self._state_ids = None
        self._prefix = None

    def clear_prefix(self):
        self._state_ids = self._prefix = None

    def decide_many(self, context, questions, *, calibrators, system=""):
        import mlx.core as mx
        from .vendor.kev.model import rows_of

        started = time.perf_counter()
        record, owners = record_for(context, questions, system=system)
        encoded = self.model.encode(self.tokenizer, record, max_state=MAX_STATE_TOKENS,
                                    max_branch=MAX_ROW_TOKENS, strict=True)
        state_ids, _, rows = rows_of(encoded)
        if self._prefix is None or state_ids != self._state_ids:
            self.clear_prefix()
            self._prefix = self.model.prefix(encoded)
            self._state_ids = state_ids
        cache = self._prefix[1]
        logits = []
        for row in rows:
            # Kev's cache.merge copies both attention and recurrent states.
            branch = [type(entry).merge([entry]) for entry in cache]
            hidden = self.model._hidden([row["ids"]], branch)
            logits.append(self.model._logits(hidden[0], row["decide"], row["opts"]).numpy())
            del hidden, branch
        mx.clear_cache()
        return decisions_from_logits(questions, owners, logits, temperature=self.model.head.temperature,
                                     calibrators=calibrators, elapsed_ms=(time.perf_counter() - started) * 1000)
