import pytest

from data import Example
from scaling import DEFAULT_SIZES, run_scaling_experiment


def test_default_sizes_match_specialist_md():
    assert DEFAULT_SIZES == (100, 300, 1000, 3000)


def test_run_scaling_experiment_refuses_to_run_without_explicit_confirmation():
    examples = [Example(context="K mail.opened", label=0, weight=1.0, source="synthetic", ts=float(i)) for i in range(10)]
    with pytest.raises(RuntimeError):
        run_scaling_experiment(examples)
