"""Cancellation must release generation before a large prompt finishes."""
import threading
from types import SimpleNamespace

import pytest
from bobbd.generation import stream_text


@pytest.mark.parametrize("background,chunk_size", [(True,128), (False,2048)])
def test_cancellation_during_prompt_processing_yields_no_text(monkeypatch, background, chunk_size):
    cancel = threading.Event()
    released = []
    deltas = []
    engine = SimpleNamespace(model=object(), tokenizer=SimpleNamespace(apply_chat_template=lambda *a, **kw: "prompt"))
    def fake_stream(*args, **kwargs):
        assert kwargs['prefill_step_size'] == chunk_size
        try:
            cancel.set()
            kwargs['prompt_progress_callback'](chunk_size, 2000)
            pytest.fail("Cancelled prompt continued generating")
            yield
        finally:
            released.append(True)
    monkeypatch.setattr('mlx_lm.stream_generate', fake_stream)
    result = stream_text(engine, [], cancel=cancel, interruptible_prefill=background, on_delta=deltas.append)
    assert result.cancelled and not result.text and result.tokens == 0
    assert released == [True] and deltas == []


def test_already_cancelled_request_does_not_tokenize_or_start_mlx():
    cancel = threading.Event()
    cancel.set()
    result = stream_text(SimpleNamespace(model=object(), tokenizer=object()), [], cancel=cancel)
    assert result.cancelled and result.tokens == 0 and result.first_token_ms is None
