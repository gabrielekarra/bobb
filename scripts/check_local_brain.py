#!/usr/bin/env python3
"""Offline checks of the real Qwen + Kev runtime, using synthetic content."""
import json
import os
from pathlib import Path
import resource
import socket
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
os.environ['BOBB_MODELS_DIR'] = str(ROOT / '.runtime/models')
sys.path.insert(0, str(ROOT / 'bobbd'))

# Model loading and every inference must work with all IP sockets forbidden.
original_connect = socket.socket.connect
def offline_connect(connection, address):
    if connection.family != socket.AF_UNIX:
        raise AssertionError('Local inference attempted a network connection')
    return original_connect(connection, address)
socket.socket.connect = offline_connect
socket.socket.connect_ex = offline_connect

from bobbd.engine import ResidentMLX
from bobbd.kev import KevDecisionBackend
from bobbd.decide import decide_many
from bobbd.schema import Bool, Choice, Score
from bobbd.generation import stream_text
from bobbd.agent import route_request
from bobbd.compose import Request, for_request
from bobbd.routing import text_mode, browser_destination
import mlx.core as mx

started = time.monotonic()
engine = ResidentMLX('mlx-community/Qwen3.5-4B-4bit')
engine.decision_backend = KevDecisionBackend()
print('Loaded Qwen + Kev in', round(time.monotonic() - started, 2), 's', flush=True)
questions = [Bool(name='needs_reply', statement='Does this message ask the recipient for an answer or action?')]
for text, expected in [
    ('Puoi mandarmi il preventivo entro domani?', True),
    ('Grazie, ho ricevuto tutto. Buona giornata!', False),
    ('Your order was shipped. This is an automated notification. Do not reply.', False),
    ('Can you confirm whether you accept the proposal by 3 PM today?', True),
]:
    result = decide_many(engine, text, questions)[0]
    print(json.dumps({'input': text, 'value': result.value, 'p': result.confidence, 'ms': result.latency_ms}), flush=True)
    assert result.value == expected

for text, expected in [
    ('Apri Note e crea una nota chiamata Idee per Bobb.', 'do'),
    ('Spiegami cosa significa interesse composto.', 'answer'),
    ('Rendilo più cortese.', 'answer'),
    ('Traduci in inglese.', 'answer'),
    ('Riassumi questo testo.', 'answer'),
    ('Scrivi una breve email a Marco per fissare una riunione.', 'answer'),
    ('Non inviare questa email. Rendila più cortese.', 'answer'),
    ('Cerca su YouTube lofi hip hop.', 'do'),
]:
    route, p = route_request(engine, text)
    print('Route:', text, route, round(p, 3), flush=True)
    assert route == expected

for prompt, selected, expected in [
    ('Rendilo più cortese.', 'Mandami il preventivo entro domani.', 'rewrite'),
    ('Traduci in inglese.', 'La riunione è domani alle 10.', 'translate'),
    ('Riassumi questo testo.', 'La riunione è domani. Discuteremo il preventivo.', 'summarize'),
    ('Scrivi una breve email a Marco per fissare una riunione.', '', 'write'),
    ('Non inviare questa email. Rendila più cortese.', 'Inviami il preventivo.', 'rewrite'),
]:
    actual = text_mode(engine, prompt, selected)
    print('Text intent:', prompt, actual, flush=True)
    assert actual == expected

for prompt in ['Cerca su YouTube lofi hip hop.', 'Riproduci un video lofi su YouTube.']:
    plan = browser_destination(engine, prompt)
    print('Browser intent:', prompt, plan, flush=True)
    assert plan is not None and plan.url.startswith('https://www.youtube.com/results?')

for selection in ['Mandami il preventivo entro domani.', 'Non hai ancora risposto alla mia email.']:
    task = for_request(Request(mode='rewrite', selection=selection,
                              prompt='Rendi questa frase più cortese in italiano, mantenendo la scadenza.'), None, 'it')
    generated = stream_text(engine, task.messages, max_tokens=task.max_tokens, temperature=task.temperature)
    print('Rewrite:', generated.text, 'first token:', round(generated.first_token_ms or 0), 'ms', flush=True)
    assert generated.text and '<think>' not in generated.text
    if 'domani' in selection:
        assert 'domani' in generated.text.lower() and 'preventivo' in generated.text.lower()
        assert 'potrei' not in generated.text.lower() and 'posso' not in generated.text.lower(), 'Rewrite reversed the actor'
        assert 'inviarci' not in generated.text.lower() and 'mandarci' not in generated.text.lower(), 'Rewrite changed me to us'
    assert 'cliente' not in generated.text.lower(), 'Rewrite invented a recipient'

print(json.dumps({'mlx_active_gb': mx.get_active_memory() / 1e9, 'mlx_peak_gb': mx.get_peak_memory() / 1e9,
                  'process_peak_gb': resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1e9}), flush=True)
