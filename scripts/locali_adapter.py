"""Experimental adapters for the actual Locali checkout, never downloaded weights.

Upstream source is read-only. Qwen's nested vocabulary metadata is normalized
for Locali's resident constructor. The MoE adapter reuses Locali's ArenaStore
and ArenaMoE, preserving Qwen's softmax router rather than DeepSeek's sigmoid.
"""
import importlib.util
import json
from pathlib import Path
import struct
import sys


def source_module(source, filename, name):
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_file_location(name, Path(source) / filename)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def resident(source, checkpoint):
    module = source_module(source, 'resident_mlx.py', 'bobb_experiment_locali_resident')
    original_load = module.load
    def load(*args, **kwargs):
        model, tokenizer, config = original_load(*args, **kwargs)
        if 'vocab_size' not in config:
            config = {**config, 'vocab_size': config['text_config']['vocab_size']}
        return model, tokenizer, config
    module.load = load
    path = Path(checkpoint).resolve()
    return module.ResidentMLX(path.name, models_dir=path.parent)


def headers(snapshot):
    tensors = {}
    for path in sorted(Path(snapshot).glob('model*.safetensors')):
        with path.open('rb') as f:
            size = struct.unpack('<Q', f.read(8))[0]
            header = json.loads(f.read(size))
        for name, meta in header.items():
            if name != '__metadata__':
                tensors[name] = (path, 8 + size, meta)
    return tensors


def qwen_index(snapshot):
    """Index actual converted shard headers; upstream weight maps may be stale."""
    snapshot = Path(snapshot).resolve()
    config = json.loads((snapshot / 'config.json').read_text())
    if config['model_type'] != 'qwen3_vl_moe':
        raise ValueError('Streamed adapter currently supports qwen3_vl_moe only')
    quant = config.get('quantization', {})
    if (quant.get('bits'), quant.get('group_size'), quant.get('mode', 'affine')) != (4, 64, 'affine'):
        raise ValueError('This Locali arena requires 4-bit affine Qwen experts with group size 64')
    args = config['text_config']
    tensors = headers(snapshot)
    entries = {}
    total = 0
    for layer in range(args['num_hidden_layers']):
        for proj in ('gate_proj', 'up_proj', 'down_proj'):
            for array in ('weight', 'scales', 'biases'):
                name = f'language_model.model.layers.{layer}.mlp.switch_mlp.{proj}.{array}'
                path, start, meta = tensors[name]
                count = args['num_experts']
                if meta['shape'][0] != count:
                    raise ValueError(f'Unexpected expert shape: {name}')
                size = meta['data_offsets'][1] - meta['data_offsets'][0]
                if size % count:
                    raise ValueError(f'Invalid expert stride: {name}')
                stride = size // count
                for expert in range(count):
                    record = [str(snapshot), path.name, start + meta['data_offsets'][0] + expert * stride,
                              stride, meta['shape'][1:], meta['dtype']]
                    entries.setdefault(f'L{layer}.E{expert}', {'tier': 'hot'}).setdefault(proj, {})[array] = record
                total += size
    return {'layers': args['num_hidden_layers'], 'num_experts': args['num_experts'],
            'top_k': args['num_experts_per_tok'], 'expert_bytes': total, 'experts': entries}


def streamed(source, checkpoint, index_path, ceiling_gb=2):
    import mlx.core as mx
    import mlx.nn as nn
    from mlx_lm.utils import load
    module = source_module(source, 'arena.py', 'bobb_experiment_locali_arena')
    index = qwen_index(checkpoint)
    Path(index_path).write_text(json.dumps(index))
    model, tokenizer, config = load(str(checkpoint), lazy=True, return_config=True)
    store = module.ArenaStore(index_path, ceiling_gb=ceiling_gb, nocache=True)

    class QwenArena(module.ArenaMoE):
        def route(self, x, input_ids=None):
            gates = mx.softmax(self.gate(x), axis=-1, precise=True)
            inds = mx.argpartition(gates, kth=-self.top_k, axis=-1)[..., -self.top_k:]
            scores = mx.take_along_axis(gates, inds, axis=-1)
            if self.norm_topk_prob:
                scores /= mx.sum(scores, axis=-1, keepdims=True)
            return inds, scores

    class StreamedBlock(nn.Module):
        def __init__(self, block, layer):
            super().__init__()
            self.gate = block.gate
            arena = QwenArena(store, layer, self.gate, None, block.top_k)
            arena.norm_topk_prob = block.norm_topk_prob
            self.__dict__['arena'] = arena
        def __call__(self, x):
            return self.arena(x)

    # Verify the seam against original quantized expert bytes before dropping
    # the resident expert graph. This only evaluates one layer, not 30B weights.
    first = model.layers[0].mlp
    mx.random.seed(7)
    probe = mx.random.normal((1, 3, config['text_config']['hidden_size'])).astype(mx.bfloat16)
    expected = first(probe)
    mx.eval(expected)
    candidate = StreamedBlock(first, 0)
    actual = candidate(probe)
    mx.eval(actual)
    parity = float(mx.max(mx.abs(actual.astype(mx.float32) - expected.astype(mx.float32))).item())
    if parity != 0:
        store.close()
        raise ValueError(f'Locali/Qwen expert parity failed: maximum error {parity}')
    for layer, block in enumerate(model.layers):
        block.mlp = candidate if layer == 0 else StreamedBlock(block.mlp, layer)
    del first, expected, actual, probe, candidate
    mx.clear_cache()
    mx.eval(model.parameters())
    engine = type('StreamedLocali', (), {})()
    engine.model, engine.tokenizer, engine.store = model, tokenizer, store
    engine.name = str(checkpoint)
    engine.parity_max_error = parity
    engine.expert_bytes = index['expert_bytes']
    return engine
