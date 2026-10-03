#!/usr/bin/env python3
"""Same weights/prompts, different actual engine; one isolated process per run."""
import argparse
import json
import os
from pathlib import Path
import resource
import tempfile
import socket
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
os.environ['BOBB_MODELS_DIR'] = str(ROOT / '.runtime/models')
os.environ['HF_HUB_OFFLINE'] = '1'
os.environ['TRANSFORMERS_OFFLINE'] = '1'
sys.path.insert(0, str(ROOT / 'bobbd'))
connect = socket.socket.connect
def offline(sock, address):
    if sock.family != socket.AF_UNIX:
        raise RuntimeError('Engine experiment attempted IP networking')
    return connect(sock, address)
socket.socket.connect = offline
socket.socket.connect_ex = offline

CASES = [
    ('accounting', 'Scrivi solo una breve richiesta al cliente Alfa: manca la fattura relativa al bonifico di 450 euro. Non aggiungere fatti o scadenze.'),
    ('architecture', 'Scrivi solo una richiesta delle misure aggiornate del lotto necessarie per confrontare due alternative per un cortile. Non aggiungere fatti o scadenze.'),
    ('development', 'ModuleNotFoundError: No module named invoice_parser. Give a short diagnostic checklist. It might be a local module or a dependency; do not assume either.'),
    ('followup', 'Draft a short reminder requesting the signed approval for the kitchen layout. The design review is waiting on it. Do not invent an agreement or deadline.'),
]

def main():
    p = argparse.ArgumentParser()
    p.add_argument('--backend', choices=['bobb', 'locali-resident', 'locali-streamed'], required=True)
    p.add_argument('--model', type=Path, default=ROOT / '.runtime/models/Qwen3.5-4B-4bit')
    p.add_argument('--locali-source', type=Path, default=Path('/Users/gabrielekarra/dev/locali'))
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--ceiling-gb', type=float, default=2)
    p.add_argument('--max-tokens', type=int, default=120)
    p.add_argument('--repeats', type=int, default=2)
    args = p.parse_args()
    import mlx.core as mx
    from bobbd.engine import ResidentMLX
    from bobbd.generation import stream_text
    started = time.monotonic()
    if args.backend == 'bobb':
        engine = ResidentMLX(str(args.model))
    else:
        from locali_adapter import resident, streamed
        if args.backend == 'locali-resident':
            engine = resident(args.locali_source, args.model)
        else:
            with tempfile.TemporaryDirectory(prefix='bobb-locali-index-') as directory:
                engine = streamed(args.locali_source, args.model, Path(directory) / 'experts.json', args.ceiling_gb)
    loaded = time.monotonic() - started
    rows = []
    try:
        for repeat in range(args.repeats):
            for case, prompt in CASES:
                before = engine.store.stats() if hasattr(engine, 'store') else {}
                output = stream_text(engine, [{'role': 'system', 'content': 'Help prepare useful work. Be concise and factual. Unknown facts must remain unknown.'},
                    {'role': 'user', 'content': prompt}], max_tokens=args.max_tokens, temperature=0)
                after = engine.store.stats() if hasattr(engine, 'store') else {}
                row = {'case': case, 'repeat': repeat, 'text': output.text, 'tokens': output.tokens,
                    'seconds': round(output.latency_ms / 1000, 3), 'first_token_ms': output.first_token_ms,
                    'finish_reason': output.finish_reason, 'read_bytes': after.get('bytes_read', 0) - before.get('bytes_read', 0)}
                rows.append(row)
                print(json.dumps(row, ensure_ascii=False), flush=True)
        result = {'backend': args.backend, 'model': str(args.model.resolve()),
            'scope': 'Four identical synthetic text prompts, repeated; engine comparison, not a model quality or real-app benchmark. No Kev loaded.',
            'load_seconds': round(loaded, 3), 'mlx_peak_gb': mx.get_peak_memory() / 1e9,
            'rss_peak_gb': resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1e9,
            'parity_max_error': getattr(engine, 'parity_max_error', None), 'cases': rows}
        if args.backend.startswith('locali'):
            import hashlib
            source = args.locali_source / ('arena.py' if args.backend == 'locali-streamed' else 'resident_mlx.py')
            result['locali_source'] = {'file': source.name, 'sha256': hashlib.sha256(source.read_bytes()).hexdigest(),
                'compatibility': 'Qwen nested vocab metadata for resident; Qwen softmax router and shard index for streamed.'}
        if hasattr(engine, 'store'):
            result['arena'] = engine.store.stats()
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
        print(json.dumps({k:v for k,v in result.items() if k != 'cases'}), flush=True)
    finally:
        if hasattr(engine, 'store'):
            engine.store.close()

if __name__ == '__main__':
    main()
