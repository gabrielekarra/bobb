import math

import numpy as np
import pytest
from fake_engine import BatchedFakeEngine, FakeEngine, logits_at, peaked_logits, queued

from leonardd.decide import _letter_id_sets, decide, decide_many, prime
from leonardd.schema import Bool, Choice, Score


def test_choice_returns_in_schema_value():
    engine = FakeEngine(queued(peaked_logits(4096, high_index=0)))  # bare "A" wins -> billing
    q = Choice(name="topic", question="what is this about", options=("billing", "technical"))
    decision = decide(engine, "a customer wrote in", q)
    assert decision.value == "billing"
    assert decision.value in q.options


def test_score_returns_in_schema_value():
    engine = FakeEngine(queued(peaked_logits(4096, high_index=2)))  # bare "C" wins -> "3"
    q = Score(name="urgency", rubric="how urgent is this", lo=1, hi=5)
    decision = decide(engine, "state", q)
    assert decision.value == 3
    assert str(decision.value) in q.labels


def test_bool_returns_in_schema_value():
    engine = FakeEngine(queued(peaked_logits(4096, high_index=1)))  # bare "B" wins -> true
    q = Bool(name="is_spam", statement="this message is spam")
    decision = decide(engine, "state", q)
    assert decision.value is True


def test_probabilities_sum_to_one_and_schema_constrained():
    engine = FakeEngine(queued(peaked_logits(4096, high_index=0)))
    q = Choice(name="topic", question="?", options=("billing", "technical", "refund"))
    decision = decide(engine, "state", q)
    assert set(decision.probabilities) == set(q.labels)
    assert math.isclose(sum(decision.probabilities.values()), 1.0, abs_tol=1e-6)
    assert math.isclose(sum(decision.raw_probabilities.values()), 1.0, abs_tol=1e-6)
    assert decision.value in q.options  # never off-schema, whatever the logits said


def test_decide_many_answers_all_questions_from_one_prefill():
    engine = FakeEngine(
        queued(
            peaked_logits(4096, high_index=0),
            peaked_logits(4096, high_index=2),
            peaked_logits(4096, high_index=1),
        )
    )
    questions = [
        Choice(name="topic", question="?", options=("billing", "technical")),
        Score(name="urgency", rubric="?", lo=1, hi=5),
        Bool(name="is_spam", statement="?"),
    ]
    decisions = decide_many(engine, "shared context", questions)
    assert engine.prefill_calls == 1
    assert len(decisions) == 3


def test_off_schema_huge_logit_is_never_returned_and_lowers_schema_mass():
    # id 500 is an ordinary word token, not any letter's bare/spaced id: the
    # model spent nearly all its mass off-schema, and the readout must show it.
    vocab_size = 4096
    logits = logits_at(vocab_size, {0: 1.0, 1: 0.5, 500: 100.0})
    engine = FakeEngine(queued(logits))
    q = Choice(name="topic", question="?", options=("billing", "technical"))
    decision = decide(engine, "state", q)
    assert decision.value == "billing"  # still schema-constrained
    assert math.isclose(sum(decision.probabilities.values()), 1.0, abs_tol=1e-6)
    assert decision.schema_mass < 1e-10  # but flagged as almost entirely off-schema


def test_schema_mass_flags_mostly_off_schema_answers():
    vocab_size = 4096
    logits = logits_at(vocab_size, {0: -1.0, 1: -2.0, 500: 20.0})
    engine = FakeEngine(queued(logits))
    q = Choice(name="topic", question="?", options=("billing", "technical"))
    decision = decide(engine, "state", q)
    assert decision.value == "billing"  # still argmax among valid letters
    assert decision.schema_mass < 1e-6


def test_readout_sums_bare_and_spaced_letter_variants():
    # "A"'s bare id is deliberately lower than "B"'s bare id, but "A"'s spaced
    # id (100) carries the true, dominant mass: the grouped readout must sum
    # both variants per letter, not just the bare one, and still pick "A".
    vocab_size = 4096
    logits = logits_at(vocab_size, {0: -5.0, 100: 9.0, 1: -4.0, 101: -10.0})
    engine = FakeEngine(queued(logits))
    q = Choice(name="topic", question="?", options=("billing", "technical"))
    decision = decide(engine, "state", q)
    assert decision.value == "billing"
    assert decision.schema_mass > 0.5


def test_too_many_options_raises():
    engine = FakeEngine(queued())
    q = Score(name="score", rubric="?", lo=1, hi=40)  # 40 labels > 26 letters
    with pytest.raises(ValueError):
        decide(engine, "state", q)


def test_letter_id_sets_raises_on_empty_set():
    table = {"A": [10], "B": []}
    with pytest.raises(ValueError):
        _letter_id_sets(table, 2)


def test_letter_id_sets_raises_on_collision():
    table = {"A": [10, 11], "B": [11, 12]}  # id 11 shared between letters
    with pytest.raises(ValueError):
        _letter_id_sets(table, 2)


class MissingLetterTokenEngine(FakeEngine):
    def decode_text(self, ids):
        text = super().decode_text(ids)
        return "<removed>" if text.strip() == "B" else text


def test_missing_letter_token_raises_end_to_end():
    engine = MissingLetterTokenEngine(queued())
    q = Choice(name="topic", question="?", options=("billing", "technical"))
    with pytest.raises(ValueError):
        decide(engine, "state", q)


def test_prime_prefills_once_and_decide_many_forks_instead():
    engine = FakeEngine(
        queued(
            peaked_logits(4096, high_index=0),  # state advance
            peaked_logits(4096, high_index=0),
            peaked_logits(4096, high_index=1),
        )
    )
    primed = prime(engine, "system prompt")
    assert engine.prefill_calls == 1

    questions = [
        Choice(name="q1", question="?", options=("x", "y")),
        Bool(name="q2", statement="?"),
    ]
    decisions = decide_many(engine, "a ticket", questions, primed=primed)

    assert engine.prefill_calls == 1  # never prefilled again
    assert engine.fork_calls == 1 + len(questions)  # base fork + one per question
    assert len(decisions) == 2


def test_batched_engine_answers_every_question_in_one_call():
    engine = BatchedFakeEngine(lambda cache: peaked_logits(4096, high_index=0))
    q = Choice(name="dept", question="?", options=("billing", "technical", "sales"))
    decisions = decide_many(engine, "a ticket", [q, q, q])
    assert len(decisions) == 3
    assert all(d.value in q.options for d in decisions)
    assert engine.prefill_calls == 1
    assert len(engine.step_many_calls) == 1  # one batched pass, not three sequential steps
    assert engine.step_calls == []


def test_decide_many_empty_questions_returns_empty_without_prefill():
    engine = FakeEngine(queued())
    assert decide_many(engine, "state", []) == []
    assert engine.prefill_calls == 0


# ---------------------------------------------------------------- letter-order debiasing


def test_debias_cancels_a_model_that_only_ever_says_A():
    always_a = lambda cache: peaked_logits(4096, high_index=100)  # " A", whatever the question
    q = Choice(name="kind", question="?", options=("request", "fyi"), debias=True)
    decision = decide(FakeEngine(always_a), "state", q)
    # Forward order says "request", reversed order says "fyi": no real opinion.
    assert decision.probabilities["request"] == pytest.approx(0.5, abs=1e-6)
    assert decision.probabilities["fyi"] == pytest.approx(0.5, abs=1e-6)


def test_debias_keeps_an_answer_that_survives_reordering():
    # Forward: B (= "fyi"). Reversed order lists "fyi" first: A (= "fyi").
    engine = FakeEngine(queued(peaked_logits(4096, high_index=1), peaked_logits(4096, high_index=0)))
    q = Choice(name="kind", question="?", options=("request", "fyi"), debias=True)
    decision = decide(engine, "state", q)
    assert decision.value == "fyi"
    assert decision.confidence > 0.99


def test_debias_rides_the_same_batched_pass():
    engine = BatchedFakeEngine(lambda cache: peaked_logits(4096, high_index=100))
    questions = [
        Choice(name="kind", question="?", options=("a", "b", "c"), debias=True),
        Score(name="urgency", rubric="?", lo=0, hi=4),
    ]
    decisions = decide_many(engine, "shared", questions)
    assert [d.name for d in decisions] == ["kind", "urgency"]
    assert sum(len(call) for call in engine.step_many_calls) == 3  # 2 rows for kind, 1 for urgency
    assert engine.prefill_calls == 1


def test_bool_never_debiases():
    assert Bool(name="x", statement="y").debias is False
