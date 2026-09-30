"""A CPU reference engine: the shipped 4-bit checkpoint, dequantized, run by PyTorch.

Not part of the product. MLX's CPU backend is too slow to evaluate a 3B
model on a Linux box, and the product only ever runs on Apple silicon, so
this exists for one purpose: measuring prompts, question sets and generated
text on machines without a Mac — a laptop, a CI runner — against the *same
weights* the app downloads.

`dequantize()` expands the MLX 4-bit tensors with MLX itself (elementwise,
fast on CPU) and writes a bfloat16 checkpoint once. `TorchEngine` implements
`bobbd.engine.Engine` on top of it, so `decide_many`, `AttentionEngine`
and `judgement_eval` run unmodified. `torch_stream_text` stands in for
`bobbd.generation.stream_text`.

Numbers measured through this engine are CPU reference numbers: the readout
probabilities match the product's to within bfloat16 rounding, the latencies
do not match anything and must never be quoted.

    uv pip install torch --index-url https://download.pytorch.org/whl/cpu
    PYTHONPATH=. uv run --no-sync python tools/torch_reference.py dequantize
"""

from __future__ import annotations

import copy
import json
import sys
import threading
import time
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / ".runtime" / "models" / "Llama-3.2-3B-Instruct-4bit"
TARGET = ROOT / ".runtime" / "models" / "Llama-3.2-3B-Instruct-bf16-reference"


def dequantize(source: Path = SOURCE, target: Path = TARGET) -> Path:
    import mlx.core as mx
    import torch
    from safetensors.torch import save_file

    config = json.loads((source / "config.json").read_text())
    quant = config.pop("quantization", None)
    config.pop("quantization_config", None)
    group_size, bits = quant["group_size"], quant["bits"]
    weights = mx.load(str(source / "model.safetensors"))
    out: dict[str, torch.Tensor] = {}
    for key in sorted(weights):
        if key.endswith(".scales") or key.endswith(".biases"):
            continue
        base = key[: -len(".weight")] if key.endswith(".weight") else None
        if base and f"{base}.scales" in weights:
            dense = mx.dequantize(
                weights[key], weights[f"{base}.scales"], weights[f"{base}.biases"], group_size=group_size, bits=bits
            )
        else:
            dense = weights[key]
        array = np.array(dense.astype(mx.float32))
        out[key] = torch.from_numpy(array).to(torch.bfloat16)
    target.mkdir(parents=True, exist_ok=True)
    save_file(out, str(target / "model.safetensors"))
    config["torch_dtype"] = "bfloat16"
    (target / "config.json").write_text(json.dumps(config, indent=2))
    for name in ("tokenizer.json", "tokenizer_config.json", "special_tokens_map.json"):
        (target / name).write_bytes((source / name).read_bytes())
    return target


class TorchEngine:
    def __init__(self, path: Path = TARGET, threads: int | None = None):
        import torch
        from transformers import AutoTokenizer, LlamaForCausalLM

        if threads:
            torch.set_num_threads(threads)
        self.torch = torch
        self.tokenizer = AutoTokenizer.from_pretrained(str(path))
        self.model = LlamaForCausalLM.from_pretrained(str(path), torch_dtype=torch.bfloat16)
        self.model.eval()
        self.name = "torch-reference:" + path.name
        self.vocab_size = int(self.model.config.vocab_size)

    # ---- Engine protocol

    def encode(self, text: str, *, add_special: bool = False) -> list[int]:
        return self.tokenizer.encode(text, add_special_tokens=add_special)

    def decode_text(self, ids: list[int]) -> str:
        return self.tokenizer.decode(ids)

    def chat_frame(self, system: str) -> tuple[str, str]:
        sentinel = "\x00BOBB_CONTENT\x00"
        user = {"role": "user", "content": sentinel}
        messages = [{"role": "system", "content": system}, user] if system else [user]
        rendered = self.tokenizer.apply_chat_template(messages, tokenize=False, add_generation_prompt=True)
        head, found, tail = rendered.partition(sentinel)
        if not found:
            raise NotImplementedError
        return head, tail

    def _forward(self, ids: list[int], past):
        with self.torch.no_grad():
            out = self.model(input_ids=self.torch.tensor([ids]), past_key_values=past, use_cache=True)
        return out.past_key_values, out.logits[0, -1].float().numpy()

    def prefill(self, ids: list[int]):
        past, logits = self._forward(ids, None)
        return {"past": past, "logits": logits}

    def fork(self, cache):
        return {"past": copy.deepcopy(cache["past"]), "logits": cache["logits"].copy()}

    def step(self, cache, ids: list[int]) -> np.ndarray:
        if ids:
            cache["past"], cache["logits"] = self._forward(ids, cache["past"])
        return cache["logits"].copy()

    def step_many(self, cache, id_lists: list[list[int]]) -> np.ndarray:
        return np.stack([self.step(self.fork(cache), ids) for ids in id_lists])


def torch_stream_text(engine, messages, *, max_tokens=400, on_delta=None, cancel=None, temperature=0.3, prefix=""):
    """`bobbd.generation.stream_text` for a `TorchEngine`: greedy at
    temperature 0, nucleus sampling otherwise, same cleanup."""
    from bobbd.generation import Generated, clean

    torch = engine.torch
    prompt = engine.tokenizer.apply_chat_template(messages, tokenize=False, add_generation_prompt=True) + prefix
    ids = engine.tokenizer.encode(prompt, add_special_tokens=False)
    if prefix and on_delta:
        on_delta(prefix)
    started = time.perf_counter()
    past, logits = engine._forward(ids, None)
    eos = set(engine.tokenizer.convert_tokens_to_ids(["<|eot_id|>", "<|end_of_text|>", "<|eom_id|>"]))
    generated: list[int] = []
    text_so_far = ""
    first = None
    generator = torch.Generator().manual_seed(0)
    for _ in range(max_tokens):
        if cancel is not None and cancel.is_set():
            break
        scores = torch.from_numpy(logits)
        for token in set(generated[-20:]):
            scores[token] = scores[token] / 1.1 if scores[token] > 0 else scores[token] * 1.1
        if temperature <= 0:
            token = int(torch.argmax(scores))
        else:
            probs = torch.softmax(scores / temperature, dim=-1)
            sorted_p, order = torch.sort(probs, descending=True)
            keep = torch.cumsum(sorted_p, 0) - sorted_p < 0.9
            sorted_p = sorted_p * keep
            token = int(order[torch.multinomial(sorted_p / sorted_p.sum(), 1, generator=generator)])
        if token in eos:
            break
        generated.append(token)
        text = engine.tokenizer.decode(generated, skip_special_tokens=True)
        delta, text_so_far = text[len(text_so_far):], text
        if delta:
            first = first or (time.perf_counter() - started) * 1000
            if on_delta:
                on_delta(delta)
        past, logits = engine._forward([token], past)
    return Generated(clean(prefix + text_so_far), len(generated), (time.perf_counter() - started) * 1000, first,
                     bool(cancel and cancel.is_set()), "stop")


if __name__ == "__main__":
    if sys.argv[1:] == ["dequantize"]:
        print(dequantize())
    else:
        raise SystemExit("usage: torch_reference.py dequantize")
