from collections import defaultdict

from data import Example
from synth import CATEGORIES, HARD_NEGATIVE_PAIRS, generate_examples, split_examples, to_examples


def test_generation_is_deterministic_for_a_fixed_seed():
    assert generate_examples(20, seed=7) == generate_examples(20, seed=7)


def test_generation_is_order_independent_across_run_sizes():
    big = generate_examples(30, seed=7)
    small = generate_examples(10, seed=7)
    assert big[:10] == small


def test_every_row_labels_match_its_category():
    rows = generate_examples(50, seed=1)
    by_key = {c.key: c for c in CATEGORIES}
    for row in rows:
        category = by_key[row["meta"]["category"]]
        from model import ACTIONS

        assert row["label"] == ACTIONS.index(category.action)


def test_split_is_disjoint_by_category_signature():
    rows = generate_examples(300, seed=3)
    signature_to_splits: dict[str, set[str]] = defaultdict(set)
    buckets = split_examples(rows)
    for split_name, split_rows in buckets.items():
        for row in split_rows:
            signature_to_splits[row["meta"]["signature"]].add(split_name)
    assert all(len(splits) == 1 for splits in signature_to_splits.values())


def test_split_ratios_are_roughly_honoured():
    rows = generate_examples(300, seed=3)
    buckets = split_examples(rows, ratios=(0.8, 0.1, 0.1))
    total = sum(len(v) for v in buckets.values())
    assert total == len(rows)
    assert buckets["train"]
    assert 0.6 < len(buckets["train"]) / total < 0.95


def test_hard_negative_pairs_reference_real_categories():
    keys = {c.key for c in CATEGORIES}
    for first, second in HARD_NEGATIVE_PAIRS:
        assert first in keys
        assert second in keys


def test_to_examples_produces_valid_data_examples():
    rows = generate_examples(5, seed=9)
    examples = to_examples(rows)
    assert all(isinstance(example, Example) for example in examples)
    assert all(example.source == "synthetic" for example in examples)
