"""Two-stage training: distil from the resident model's stored distribution,
then fit on real labels. AdamW, cosine schedule with linear warmup, gradient
clipping at norm 1.0 — CUA-S1's own recipe (`training/train.py`), reused
as-is per `CUA-INVESTIGATION.md` section 2.3 ("training loop... reuse
largely as-is").

Stage 1 minimizes KL(teacher || student) over `data.DistillExample.
teacher_probs`, so the student inherits the teacher's uncertainty, not just
its argmax (`SPECIALIST.md`, "Distillation for the cold start"). Stage 2
minimizes cross-entropy against `data.Example.label`, weighted by
`Example.weight` — 1.0 for an explicit approve/dismiss, the labeller's own
confidence for an implicit label, so a shakier implicit label pulls the
weights less than a direct human action.

Every function here runs in seconds on tens of rows; nothing in this module
launches or sizes for a real run. `scaling.py` is where a real run is wired
up, and it is explicitly left unrun.
"""

from __future__ import annotations

import math
from collections.abc import Sequence
from dataclasses import dataclass

import torch
import torch.nn.functional as F
from torch import nn
from torch.optim import AdamW
from torch.optim.lr_scheduler import LambdaLR

from data import DistillExample, Example
from model import ACTIONS, SpecialistCollator, SpecialistExample


@dataclass(frozen=True)
class TrainConfig:
    learning_rate: float = 2e-3
    weight_decay: float = 1e-2
    warmup_frac: float = 0.05
    batch_size: int = 32
    epochs: int = 1
    grad_clip: float = 1.0


def build_optimizer(model: nn.Module, config: TrainConfig) -> AdamW:
    return AdamW(model.parameters(), lr=config.learning_rate, weight_decay=config.weight_decay)


def _cosine_warmup(step: int, total_steps: int, warmup_steps: int) -> float:
    if step < warmup_steps:
        return (step + 1) / max(1, warmup_steps)
    progress = (step - warmup_steps) / max(1, total_steps - warmup_steps)
    return 0.5 * (1.0 + math.cos(math.pi * min(progress, 1.0)))


def build_scheduler(optimizer: AdamW, total_steps: int, warmup_frac: float) -> LambdaLR:
    warmup_steps = max(1, round(total_steps * warmup_frac))
    return LambdaLR(optimizer, lambda step: _cosine_warmup(step, max(total_steps, 1), warmup_steps))


def _batches(items: Sequence, batch_size: int) -> list[Sequence]:
    return [items[i : i + batch_size] for i in range(0, len(items), batch_size)]


def distill_batch_loss(model: nn.Module, collator: SpecialistCollator, batch: Sequence[DistillExample]) -> torch.Tensor:
    placeholders = [SpecialistExample(context=item.context, label=0) for item in batch]
    logits = model(collator(placeholders))
    teacher = torch.tensor([item.teacher_probs for item in batch], dtype=torch.float32)
    log_student = F.log_softmax(logits, dim=-1)
    return F.kl_div(log_student, teacher, reduction="batchmean")


def supervised_batch_loss(model: nn.Module, collator: SpecialistCollator, batch: Sequence[Example]) -> torch.Tensor:
    examples = [SpecialistExample(context=item.context, label=item.label) for item in batch]
    collated = collator(examples)
    logits = model(collated)
    per_example = F.cross_entropy(logits, collated["labels"], reduction="none")
    weights = torch.tensor([item.weight for item in batch], dtype=torch.float32)
    return (per_example * weights).sum() / weights.sum().clamp_min(1e-8)


def _run(
    model: nn.Module,
    collator: SpecialistCollator,
    examples: Sequence,
    config: TrainConfig,
    loss_fn,
) -> list[float]:
    if not examples:
        return []
    optimizer = build_optimizer(model, config)
    batches_per_epoch = max(1, math.ceil(len(examples) / config.batch_size))
    scheduler = build_scheduler(optimizer, batches_per_epoch * config.epochs, config.warmup_frac)
    losses = []
    model.train()
    for _ in range(config.epochs):
        for batch in _batches(examples, config.batch_size):
            optimizer.zero_grad()
            loss = loss_fn(model, collator, batch)
            loss.backward()
            torch.nn.utils.clip_grad_norm_(model.parameters(), config.grad_clip)
            optimizer.step()
            scheduler.step()
            losses.append(float(loss.detach()))
    model.eval()
    return losses


def run_distillation(
    model: nn.Module, collator: SpecialistCollator, examples: Sequence[DistillExample], config: TrainConfig
) -> list[float]:
    return _run(model, collator, examples, config, distill_batch_loss)


def run_supervised(
    model: nn.Module, collator: SpecialistCollator, examples: Sequence[Example], config: TrainConfig
) -> list[float]:
    return _run(model, collator, examples, config, supervised_batch_loss)


def train_two_stage(
    model: nn.Module,
    collator: SpecialistCollator,
    distill_examples: Sequence[DistillExample],
    supervised_examples: Sequence[Example],
    *,
    distill_config: TrainConfig = TrainConfig(),
    supervised_config: TrainConfig = TrainConfig(),
) -> dict[str, list[float]]:
    return {
        "distill_losses": run_distillation(model, collator, distill_examples, distill_config),
        "supervised_losses": run_supervised(model, collator, supervised_examples, supervised_config),
    }


@torch.no_grad()
def predict_probs(model: nn.Module, collator: SpecialistCollator, contexts: Sequence[str]) -> list[list[float]]:
    if not contexts:
        return []
    was_training = model.training
    model.eval()
    examples = [SpecialistExample(context=c, label=0) for c in contexts]
    logits = model(collator(examples))
    probs = F.softmax(logits, dim=-1).tolist()
    if was_training:
        model.train()
    return probs


__all__ = [
    "TrainConfig",
    "build_optimizer",
    "build_scheduler",
    "distill_batch_loss",
    "supervised_batch_loss",
    "run_distillation",
    "run_supervised",
    "train_two_stage",
    "predict_probs",
    "ACTIONS",
]
