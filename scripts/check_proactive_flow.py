#!/usr/bin/env python3
"""Exercise the real offline daemon through its Unix socket with synthetic data.

Uses an isolated temporary database. Does not touch the user's Bobb state,
apps, accounts or permissions. Requires installed default models.
"""
import asyncio
import json
import os
from pathlib import Path
import sys
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]

async def run():
    with tempfile.TemporaryDirectory(prefix='bobb-flow-', dir='/private/tmp') as directory:
        path = Path(directory)
        env = {**os.environ, 'BOBB_MODELS_DIR': str(ROOT / '.runtime/models')}
        log = (path / 'daemon.log').open('w')
        process = await asyncio.create_subprocess_exec(str(ROOT / 'bobbd/.venv/bin/python'), '-m', 'bobbd',
            '--data-dir', directory, '--socket', str(path / 'b.sock'), cwd=ROOT / 'bobbd', env=env,
            stdout=log, stderr=log)
        writer = None
        started = time.monotonic()
        try:
            for _ in range(180):
                if process.returncode is not None: raise RuntimeError((path / 'daemon.log').read_text())
                if (path / 'b.sock').exists(): break
                await asyncio.sleep(.5)
            reader, writer = await asyncio.open_unix_connection(str(path / 'b.sock'))
            async def send(frame):
                writer.write((json.dumps(frame) + '\n').encode()); await writer.drain()
            async def receive(kind, identifier=None):
                while True:
                    raw = await asyncio.wait_for(reader.readline(), 120)
                    if not raw: raise RuntimeError('Daemon disconnected')
                    frame = json.loads(raw)
                    if frame['t'] == 'error': raise RuntimeError(frame)
                    if frame['t'] == kind and (identifier is None or frame.get('request_id') == identifier): return frame
            async def command(op='list', payload=None):
                identifier = uuid.uuid4().hex
                await send({'t':'bobb.command', 'id':identifier, 'op':op, 'payload':payload or {}})
                return await receive('bobb.state', identifier)
            await send({'t':'hello', 'locale':'it'})
            await receive('ready')
            await send({'t':'settings', 'context_proactive': True, 'memory_enabled': True, 'floor': .6, 'quiet_hours': None})
            await receive('settings')
            source = 'Revisione progetto: il cliente chiede di confrontare due alternative per il cortile. Mancano le misure aggiornate del lotto, necessarie prima di preparare il confronto.'
            await send({'t':'memory.observe', 'id':'synthetic', 'app':'Project Studio', 'bundle_id':'test.bobb.studio',
                        'window':'Cortile', 'text':source, 'source':'screen', 'ts':time.time()})
            observed = await receive('memory.observed','synthetic')
            assert observed['outcome'] == 'stored', observed
            item = None
            for _ in range(60):
                snapshot = await command()
                if snapshot['initiatives']:
                    item = snapshot['initiatives'][0]; break
                await asyncio.sleep(.5)
            assert item is not None, 'No initiative reached the persistent inbox'
            assert item['quote'] in source
            assert item.get('draft'), 'Initiative has no prepared draft'
            assert (await command('initiative_presented', {'id':item['id']}))['result'] is True
            assert (await command('initiative_presented', {'id':item['id']}))['result'] is False
            await command('initiative_response', {'id':item['id'],'response':'prepare'})
            assert not (await command())['initiatives']
            await send({'t':'ask','id':'prepare','mode':'ask','route':False,'selection':item['quote'],
                'app':item['app'],'prompt':'Prepara una breve lista delle informazioni mancanti nel testo selezionato, senza inventare dati e senza eseguire azioni.'})
            answer = await receive('answer','prepare')
            assert answer.get('ok') and answer.get('text') and answer.get('result_kind') != 'task', answer
            assert not (await command())['runs'], 'Preparation unexpectedly enqueued an action'
            await send({'t':'memory.delete','id':'forget','scope':'all'})
            await receive('memory.deleted','forget')
            assert not (await command())['initiatives']
            result = {'passed':True, 'scope':'Real daemon, local models, Unix socket, isolated synthetic data; not UI automation.',
                'source_observed':True, 'suggestion':item, 'answer':answer['text'],
                'notification_once':True,'no_action_enqueued':True,'deletion_verified':True,
                'seconds':round(time.monotonic()-started,3)}
            out = ROOT / 'docs/benchmarks/proactive-flow-2026-10-02.json'
            out.write_text(json.dumps(result, ensure_ascii=False, indent=2)+'\n')
            print(json.dumps(result,ensure_ascii=False),flush=True)
        finally:
            if writer: writer.close(); await writer.wait_closed()
            if process.returncode is None:
                process.terminate()
                try: await asyncio.wait_for(process.wait(), 10)
                except asyncio.TimeoutError: process.kill(); await process.wait()
            log.close()

if __name__ == '__main__': asyncio.run(run())
