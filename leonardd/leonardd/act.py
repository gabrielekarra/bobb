"""The action loop: `observe` in, `act` out. See `docs/CONTRACT.md`, "The
action loop -- driving any application".

Two readouts off one prefill -- which operation, and which candidate is its
target -- answered together by `decide_many`, the same machinery the
attention path uses. `text` is generated with the resident model only when
the chosen operation is `TYPE_TEXT`; every other step is the constrained
readout alone, no generation.

The invariant this module exists to hold: **the scoring path never sees or
emits a tool name, a coordinate, an argument or a file path.** It sees
`Candidate.id` and `Candidate.label` -- opaque identifiers and the human
text describing them -- and it returns an id. `tests/test_act.py` enforces
this by construction: nothing importable from this module ever touches a
coordinate, a tool name or a path, and `ActResult` has no field that could
carry one.
"""

from __future__ import annotations

import time
from dataclasses import dataclass

from mlx_lm import generate as _mlx_generate

from .decide import decide_many
from .draft import GenerativeEngine, supports_generation
from .engine import Cache, Engine
from .schema import Choice, Decision

OPERATIONS = ("CLICK", "TYPE_TEXT", "SELECT", "SCROLL_UP", "SCROLL_DOWN", "WAIT", "DONE", "BLOCKED")
MAX_CANDIDATES = 20
REQUIRED_CANDIDATE_IDS = ("done", "escalate")
DEFAULT_FLOOR = 0.60
SCHEMA_MASS_FLOOR = 0.5

_OPERATION = Choice(
    name="operation",
    question=(
        "Given the goal and the candidates below, which single operation should happen next? "
        "Use these definitions:\n"
        "CLICK = activate a button, link, or control.\n"
        "TYPE_TEXT = enter text into a focused field.\n"
        "SELECT = choose one value from a picker or menu.\n"
        "SCROLL_UP = reveal content above the current view.\n"
        "SCROLL_DOWN = reveal content below the current view.\n"
        "WAIT = nothing actionable yet; the screen is still settling.\n"
        "DONE = the goal is already achieved.\n"
        "BLOCKED = no candidate can make progress toward the goal."
    ),
    options=OPERATIONS,
)

_TEXT_SYSTEM = (
    "You write the exact text to type into one form field to accomplish the stated goal. "
    "Output only that text: no quotes, no explanation, no field name."
)


@dataclass(frozen=True)
class Candidate:
    id: str
    label: str
    role: str = ""
    enabled: bool = True


def _candidate(raw: dict) -> Candidate:
    return Candidate(
        id=str(raw["id"]),
        label=str(raw.get("label", "")),
        role=str(raw.get("role", "")),
        enabled=bool(raw.get("enabled", True)),
    )


def _validate_candidates(candidates: list[Candidate]) -> None:
    if len(candidates) > MAX_CANDIDATES:
        raise ValueError(
            f"observe carries {len(candidates)} candidates; the daemon scores at most "
            f"{MAX_CANDIDATES} (including 'done' and 'escalate'). The app must narrow the "
            "candidate set before calling the daemon."
        )
    ids = [c.id for c in candidates]
    if len(set(ids)) != len(ids):
        raise ValueError(f"candidate ids must be unique, got {ids}")
    for required in REQUIRED_CANDIDATE_IDS:
        if required not in ids:
            raise ValueError(f"observe is missing the required {required!r} candidate")


def _target_question(candidates: list[Candidate]) -> Choice:
    return Choice(
        name="target",
        question="Which candidate is the right target for that operation, given the goal?",
        options=tuple(c.id for c in candidates),
    )


def _candidates_text(candidates: list[Candidate]) -> str:
    lines = []
    for c in candidates:
        role = f" ({c.role})" if c.role else ""
        state = "" if c.enabled else " [disabled]"
        lines.append(f"- {c.id}: {c.label}{role}{state}")
    return "\n".join(lines)


def _context(observation: dict, candidates: list[Candidate]) -> str:
    return (
        f"Goal: {observation.get('goal', '')}\n"
        f"App: {observation.get('app', '')}\n"
        f"Window: {observation.get('window', '')}\n"
        f"Step: {observation.get('step', 0)}\n\n"
        f"Candidates:\n{_candidates_text(candidates)}"
    )


def _generate_text(engine: GenerativeEngine, observation: dict, target: Candidate) -> str:
    messages = [
        {"role": "system", "content": _TEXT_SYSTEM},
        {
            "role": "user",
            "content": f"Goal: {observation.get('goal', '')}\nField: {target.label}\n\nWrite the text.",
        },
    ]
    prompt = engine.tokenizer.apply_chat_template(messages, tokenize=False, add_generation_prompt=True)
    return _mlx_generate(engine.model, engine.tokenizer, prompt, max_tokens=180).strip()


@dataclass(frozen=True)
class ActResult:
    operation: str
    candidate_id: str
    confidence: float
    schema_mass: float
    operation_probabilities: dict[str, float]
    probabilities: dict[str, float]
    text: str | None
    latency_ms: float
    abstained: bool


def score_action(
    engine: Engine,
    observation: dict,
    *,
    floor: float = DEFAULT_FLOOR,
    primed: Cache | None = None,
) -> ActResult:
    started = time.perf_counter()
    candidates = [_candidate(c) for c in observation.get("candidates", [])]
    _validate_candidates(candidates)

    context = _context(observation, candidates)
    operation_decision, target_decision = decide_many(
        engine, context, [_OPERATION, _target_question(candidates)], primed=primed
    )

    schema_mass = min(operation_decision.schema_mass, target_decision.schema_mass)
    confidence = min(operation_decision.confidence, target_decision.confidence)
    operation = str(operation_decision.value)
    candidate_id = str(target_decision.value)

    abstained = confidence < floor or schema_mass < SCHEMA_MASS_FLOOR
    if abstained:
        operation = "BLOCKED"
        candidate_id = "escalate"

    text = None
    if operation == "TYPE_TEXT" and not abstained and supports_generation(engine):
        target = next(c for c in candidates if c.id == candidate_id)
        text = _generate_text(engine, observation, target)

    latency_ms = (time.perf_counter() - started) * 1000
    return ActResult(
        operation=operation,
        candidate_id=candidate_id,
        confidence=confidence,
        schema_mass=schema_mass,
        operation_probabilities=operation_decision.probabilities,
        probabilities=target_decision.probabilities,
        text=text,
        latency_ms=latency_ms,
        abstained=abstained,
    )


def act_frame(observation_id: str, result: ActResult, *, why: str = "") -> dict:
    return {
        "t": "act",
        "ts": time.time(),
        "observation_id": observation_id,
        "operation": result.operation,
        "candidate_id": result.candidate_id,
        "confidence": round(result.confidence, 6),
        "schema_mass": round(result.schema_mass, 6),
        "operation_probabilities": {k: round(v, 6) for k, v in result.operation_probabilities.items()},
        "probabilities": {k: round(v, 6) for k, v in result.probabilities.items()},
        "text": result.text,
        "latency_ms": round(result.latency_ms, 6),
        "abstained": result.abstained,
        "why": why,
    }


__all__ = [
    "OPERATIONS",
    "MAX_CANDIDATES",
    "Candidate",
    "ActResult",
    "score_action",
    "act_frame",
]
