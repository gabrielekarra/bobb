#!/usr/bin/env python3
"""Measure real-daemon first streamed text, routing and proactive preemption.

Synthetic requests and an isolated database only. Includes Kev in the normal
shipping configuration; timings start at submission, after model readiness.
"""
import argparse
import asyncio
import json
import os
from pathlib import Path
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


async def run(output):
    with tempfile.TemporaryDirectory(prefix='bobb-latency-', dir='/private/tmp') as directory:
        path = Path(directory)
        log_path = path / 'daemon.log'
        log = log_path.open('w')
        process = await asyncio.create_subprocess_exec(str(ROOT / 'bobbd/.venv/bin/python'), '-m', 'bobbd',
            '--data-dir', directory, '--socket', str(path / 'b.sock'), '--log-level', 'DEBUG',
            cwd=ROOT / 'bobbd', env={**os.environ, 'BOBB_MODELS_DIR': str(ROOT / '.runtime/models')},
            stdout=log, stderr=log)
        writer = None
        boot = time.monotonic()
        try:
            for _ in range(240):
                if process.returncode is not None: raise RuntimeError(log_path.read_text())
                if (path / 'b.sock').exists(): break
                await asyncio.sleep(.25)
            reader, writer = await asyncio.open_unix_connection(str(path / 'b.sock'))
            async def send(frame):
                writer.write((json.dumps(frame) + '\n').encode()); await writer.drain()
            async def receive():
                raw = await asyncio.wait_for(reader.readline(), 120)
                if not raw: raise RuntimeError('Daemon disconnected')
                frame = json.loads(raw)
                if frame['t'] == 'error': raise RuntimeError(frame)
                return frame
            async def until(kind, request_id=None):
                while True:
                    frame = await receive()
                    if frame['t'] == kind and (request_id is None or frame.get('request_id') == request_id):
                        return frame
            await send({'t':'hello', 'locale':'it'})
            await until('ready')
            ready_seconds = time.monotonic() - boot
            await send({'t':'settings', 'context_proactive':True, 'memory_enabled':True, 'quiet_hours':None, 'floor':.6})
            await until('settings')

            async def ask(name, prompt, *, mode='ask', selection='', route=False):
                start = time.monotonic()
                await send({'t':'ask','id':name,'mode':mode,'route':route,'prompt':prompt,'selection':selection})
                first = None
                while True:
                    frame = await receive()
                    if frame.get('request_id') != name: continue
                    if frame['t'] == 'answer.delta' and frame.get('text') and first is None:
                        first = time.monotonic() - start
                    if frame['t'] == 'answer': break
                assert frame.get('ok') and frame.get('text') and frame.get('result_kind') != 'task', frame
                assert first is not None, 'No text was streamed before completion'
                row = {'case':name,'first_text_ms':round(first * 1000, 1),
                    'complete_ms':round((time.monotonic()-start)*1000, 1),
                    'generation_first_token_ms':frame.get('first_token_ms'),
                    'text':frame['text']}
                print(json.dumps(row,ensure_ascii=False),flush=True)
                return row

            rows = []
            for repeat in range(2):
                rows.append(await ask(f'direct_{repeat}', 'Perché le foglie cambiano colore in autunno? Rispondi in due frasi.'))
                rows.append(await ask(f'auto_{repeat}', 'Perché le foglie cambiano colore in autunno? Rispondi in due frasi.', mode='auto', route=True))
                rows.append(await ask(f'rewrite_{repeat}', 'Rendi più cortese questo messaggio, senza aggiungere fatti.', mode='auto', route=True,
                    selection='Mi serve la copia della fattura relativa al bonifico di 450 euro. Puoi mandarmela?'))

            await send({'t':'memory.observe','id':'context','app':'Project Studio','bundle_id':'test.bobb.studio',
                'window':'Cortile','source':'screen','ts':time.time(),
                'text':'Revisione progetto: il cliente chiede di confrontare due alternative per il cortile. Mancano le misure aggiornate del lotto, necessarie prima di preparare il confronto.'})
            await until('memory.observed','context')
            for _ in range(100):
                if process.returncode is not None: raise RuntimeError(log_path.read_text())
                if 'initiative generation started' in log_path.read_text(): break
                await asyncio.sleep(.05)
            else: raise RuntimeError('Proactive generation did not start')
            foreground = await ask('foreground_during_proactivity', 'Scrivi solo: Ricevuto, grazie.')
            assert foreground['text'].strip().strip('"') == 'Ricevuto, grazie.', foreground
            rows.append(foreground)
            await send({'t':'bobb.command','id':'snapshot','op':'list','payload':{}})
            snapshot = await until('bobb.state','snapshot')
            assert not snapshot['runs'], 'Text latency check enqueued app actions'
            assert not snapshot['initiatives'], 'Preempted proactive generation was published'
            result = {'scope':'Real shipping Qwen3.5 4B + Kev daemon, synthetic Unix-socket requests, after readiness; not UI latency or a battery benchmark.',
                'ready_seconds':round(ready_seconds,3),'background_generation_started':True,
                'preempted_result_not_published':True,'no_app_actions':True,'cases':rows}
            output.parent.mkdir(parents=True,exist_ok=True)
            output.write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
            print(json.dumps({k:v for k,v in result.items() if k!='cases'}),flush=True)
        finally:
            if writer:
                writer.close(); await writer.wait_closed()
            if process.returncode is None:
                process.terminate()
                try: await asyncio.wait_for(process.wait(),10)
                except asyncio.TimeoutError: process.kill(); await process.wait()
            log.close()


if __name__ == '__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('--output',type=Path,default=ROOT/'docs/benchmarks/response-latency-2026-10-02.json')
    asyncio.run(run(parser.parse_args().output))
