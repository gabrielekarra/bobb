#!/usr/bin/env python3
"""Compare two-readout routing with one readout on synthetic user requests.

Only Kev is loaded. This measures classification, not generation or UI latency.
Selected documents never determine intent in either candidate.
"""
import argparse
import json
import os
from pathlib import Path
import socket
import sys
import time
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[1]
os.environ['BOBB_MODELS_DIR'] = str(ROOT / '.runtime/models')
sys.path.insert(0, str(ROOT / 'bobbd'))
original_connect = socket.socket.connect
def offline_connect(connection, address):
    if connection.family != socket.AF_UNIX:
        raise AssertionError('Routing attempted a network connection')
    return original_connect(connection, address)
socket.socket.connect = socket.socket.connect_ex = offline_connect

from bobbd.agent import ROUTE_DO, ROUTE_FLOOR, SCHEMA_MASS_FLOOR, request_context, route_request
from bobbd.decide import decide_many
from bobbd.kev import KevDecisionBackend
from bobbd.routing import TEXT_MODE, text_mode
from bobbd.schema import Choice

REQUEST_MODE = Choice('request_mode',
    "What does the user explicitly ask Bobb to do? Choose 'Operate apps, files or websites' only for "
    "sending messages, opening apps, manipulating files or searching websites. Writing, editing, translating "
    "and summarizing produce text in the chat, without operating the computer. Missing details in an execution "
    "request require clarification, not a text-only answer. A negated action is not authorized. "
    + TEXT_MODE.question,
    (ROUTE_DO, *TEXT_MODE.options))

CASES = [
    ('IT knowledge', 'Perché il cielo è blu?', 'answer', 'ask'),
    ('EN knowledge', 'Why does the moon have phases?', 'answer', 'ask'),
    ('IT write', 'Scrivi una breve email a Marco per fissare una riunione.', 'answer', 'write'),
    ('EN write', 'Write a short invitation for a birthday dinner.', 'answer', 'write'),
    ('IT literal', 'Scrivi solo: Ricevuto, grazie.', 'answer', 'write'),
    ('IT rewrite', 'Rendilo più cortese.', 'answer', 'rewrite'),
    ('EN rewrite', 'Make this message clearer and more polite.', 'answer', 'rewrite'),
    ('IT translation', 'Traduci in inglese.', 'answer', 'translate'),
    ('EN translation', 'Translate the selected text into Spanish.', 'answer', 'translate'),
    ('IT summary', 'Riassumi questo testo.', 'answer', 'summarize'),
    ('EN summary', 'Summarize this document in three bullets.', 'answer', 'summarize'),
    ('IT reply', 'Prepara una risposta a questo messaggio.', 'answer', 'reply'),
    ('EN reply', 'Draft a reply to this email declining the invitation.', 'answer', 'reply'),
    ('IT explain', 'Spiegami cosa significa interesse composto.', 'answer', 'explain'),
    ('EN explain', 'Explain this error message in plain English.', 'answer', 'explain'),
    ('IT compute', 'Calcola il totale di questi importi.', 'answer', 'compute'),
    ('EN compute', 'Calculate 18 percent of 450.', 'answer', 'compute'),
    ('IT negated send', 'Non inviare questa email. Rendila più cortese.', 'answer', 'rewrite'),
    ('EN negated send', 'Do not send this. Rewrite it to be more concise.', 'answer', 'rewrite'),
    ('IT notes', 'Apri Note e crea una nota chiamata Idee per Bobb.', 'do', None),
    ('EN app', 'Open Calendar and create a meeting for tomorrow at 10.', 'do', None),
    ('IT website', 'Cerca su YouTube lofi hip hop.', 'do', None),
    ('EN website', 'Search the internet for the current train timetable.', 'do', None),
    ('IT sending', 'Invia il documento domani alle 10.', 'do', None),
    ('EN missing target', 'Send the attachment to the client.', 'do', None),
    ('IT local files', 'Sposta il PDF nella cartella del progetto.', 'do', None),
    ('EN local files', 'Rename this file to Meeting notes.', 'do', None),
    ('IT draft URL', 'Scrivi una mail con questo link: https://example.org.', 'answer', 'write'),
    ('EN draft URL', 'Draft a message recommending https://example.org.', 'answer', 'write'),
    ('IT how to', 'Spiegami come aprire una nuova scheda in Safari.', 'answer', 'explain'),
    ('EN how to', 'Explain how to send an email in Mail.', 'answer', 'explain'),
]


def run(output):
    engine = SimpleNamespace(decision_backend=KevDecisionBackend())
    rows = []
    for repeat in range(2):
        for name, prompt, expected_route, expected_mode in CASES:
            measures = {}
            # Alternate order; do not let the second variant inherit a prefix.
            for backend in (('separate', 'single') if repeat == 0 else ('single', 'separate')):
                engine.decision_backend.clear_prefix()
                started = time.monotonic()
                if backend == 'separate':
                    route, confidence = route_request(engine, prompt)
                    mode = text_mode(engine, prompt) if route == 'answer' else None
                else:
                    decision = decide_many(engine, request_context(prompt), [REQUEST_MODE])[0]
                    action = (decision.value == ROUTE_DO and decision.confidence >= ROUTE_FLOOR
                              and decision.schema_mass >= SCHEMA_MASS_FLOOR)
                    route = 'do' if action else 'answer'
                    mode = None if action else ('ask' if decision.value == ROUTE_DO else decision.value)
                    confidence = decision.confidence
                measures[backend] = {'route':route, 'mode':mode, 'confidence':round(confidence,4),
                    'ms':round((time.monotonic()-started)*1000,1),
                    'matches': route == expected_route and mode == expected_mode}
            row = {'case':name,'repeat':repeat,'prompt':prompt,
                'expected_route':expected_route,'expected_mode':expected_mode,**measures}
            rows.append(row)
            print(json.dumps(row,ensure_ascii=False),flush=True)
    result = {'scope':'31 synthetic development cases repeated twice, Kev only, prefix cleared between variants. Presence of selected text cannot authorize or change intent. Not app success or calibrated action safety.',
        'cases':rows}
    output.parent.mkdir(parents=True,exist_ok=True)
    output.write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--output',type=Path,default=ROOT/'docs/benchmarks/request-routing-2026-10-02.json')
    run(parser.parse_args().output)
