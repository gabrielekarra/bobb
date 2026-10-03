import asyncio
import json
import sqlite3
import threading
from dataclasses import replace

import pytest
from bobbd import proactive
from bobbd.memory import MemoryStore, Observation
from bobbd.settings import Settings
from bobbd.generation import Generated
from test_agent import scripted

TEXT = 'Cliente Rossi: manca il preventivo aggiornato per il progetto. Puoi prepararlo prima della riunione di domani?'
PROPOSAL = {'title': 'Prepara il preventivo', 'reason': 'Il cliente lo richiede prima della riunione.', 'quote': TEXT, 'draft': 'Buongiorno, potresti condividere il preventivo aggiornato per il progetto prima della riunione?'}

def proposal_stream(proposal):
    results = iter([json.dumps({'item':'preventivo aggiornato','reason':proposal['reason'],'quote':proposal['quote']}), proposal['draft']])
    return lambda *a, **kw: Generated(next(results), 1, 1, 1, False, 'stop')

@pytest.fixture
def setup(tmp_path):
    conn = sqlite3.connect(tmp_path / 'work.db')
    memory = MemoryStore(tmp_path / 'memory.db')
    row = memory.observe(Observation(app='Studio', bundle_id='app.studio', text=TEXT, ts=1000))
    store = proactive.InitiativeStore(conn)
    yield store, memory, memory.get(row.row_id)
    memory.close()
    conn.close()


def test_snooze_feedback_restart_and_expiry(setup):
    store, memory, hit = setup
    store.add(hit, PROPOSAL, bundle='app.studio', now=1000)
    item = store.listing(memory, Settings(), now=1001)[0]
    store.respond(item['id'], 'snooze', now=1002)
    restarted = proactive.InitiativeStore(store.conn)
    assert restarted.listing(memory, Settings(), now=1003) == []
    assert restarted.listing(memory, Settings(), now=4603)[0]['id'] == item['id']
    restarted.respond(item['id'], 'prepare', now=4604)
    assert restarted.listing(memory, Settings(), now=4605) == []
    with pytest.raises(ValueError): restarted.respond(item['id'], 'dismiss')
    assert restarted.listing(memory, Settings(), now=100000) == []


@pytest.mark.parametrize('change', ['delete', 'exclude', 'disable', 'memory_off'])
def test_sources_and_permissions_are_rechecked_before_display(setup, change):
    store, memory, hit = setup
    store.add(hit, PROPOSAL, bundle='app.studio', now=1000)
    settings = Settings()
    if change == 'delete': memory.delete(row_id=hit.id)
    elif change == 'exclude': settings = replace(settings, extra_protected_apps=frozenset({'app.studio'}))
    elif change == 'disable': settings = replace(settings, context_proactive=False)
    else: settings = replace(settings, memory_enabled=False)
    assert store.listing(memory, settings, now=1001) == []


def test_repeated_dismissals_teach_silence_and_reset_restores_eligibility(setup):
    store, memory, hit = setup
    for n in range(3):
        current = replace(hit, text=TEXT + str(n))
        proposal = {**PROPOSAL, 'quote': TEXT + str(n)}
        store.add(current, proposal, now=1000 + n * 400)
        identifier = store.conn.execute('SELECT id FROM initiatives WHERE status="pending"').fetchone()[0]
        store.respond(identifier, 'dismiss', now=1001 + n * 400)
    assert store.muted() == ['Studio']
    assert not store.reserve(replace(hit, text=TEXT + 'new'), now=3000)
    store.reset()
    assert store.muted() == []
    assert store.reserve(replace(hit, text=TEXT + 'new'), now=3001)


def test_no_repeated_inference_or_flood_from_chatty_sensors(setup):
    store, memory, hit = setup
    assert store.reserve(hit, now=1000)
    assert not store.reserve(replace(hit, text=TEXT + 'changed'), now=1001)
    assert not store.reserve(hit, now=1400)
    assert store.reserve(replace(hit, text=TEXT + 'changed'), now=1400)
    store.add(hit, PROPOSAL, now=1401)
    assert not store.reserve(replace(hit, text=TEXT + 'again'), now=1800)


@pytest.mark.parametrize('quote', ['Invented deadline Friday at 9', 'short', ''])
def test_fabricated_or_insufficient_sources_are_rejected(monkeypatch, quote):
    monkeypatch.setattr(proactive, 'supports_generation', lambda e: True)
    monkeypatch.setattr(proactive, 'decide_many', scripted({'useful_initiative': True}))
    monkeypatch.setattr(proactive, 'stream_text', proposal_stream({**PROPOSAL, 'quote': quote}))
    assert proactive.propose(object(), TEXT, app='Studio', window='', locale='it') is None


def test_exact_quote_still_requires_independent_grounding(monkeypatch):
    monkeypatch.setattr(proactive, 'supports_generation', lambda e: True)
    monkeypatch.setattr(proactive, 'decide_many', scripted({'useful_initiative': True, 'grounded_initiative': False}))
    monkeypatch.setattr(proactive, 'stream_text', proposal_stream(PROPOSAL))
    assert proactive.propose(object(), TEXT, app='Studio', window='', locale='it') is None


def test_noise_does_not_run_generator(monkeypatch):
    monkeypatch.setattr(proactive, 'supports_generation', lambda e: True)
    monkeypatch.setattr(proactive, 'decide_many', scripted({'useful_initiative': False}))
    monkeypatch.setattr(proactive, 'stream_text', lambda *a, **kw: pytest.fail('Noise ran generation'))
    assert proactive.propose(object(), TEXT, app='Studio', window='', locale='it') is None


@pytest.mark.asyncio
async def test_deleting_memory_while_inference_runs_cannot_resurrect_suggestion(tmp_path, monkeypatch):
    from bobbd.audit import open_db
    from bobbd.attention import AttentionEngine
    from bobbd.server import BobbServer
    from fake_engine import TrivialEngine
    conn = open_db(tmp_path / 'audit.db')
    memory = MemoryStore(tmp_path / 'memory.db')
    row = memory.observe(Observation(app='Studio', text=TEXT))
    server = BobbServer(AttentionEngine(TrivialEngine()), conn, memory=memory)
    started, finish = asyncio.Event(), asyncio.Event()
    async def delayed(*a, **kw):
        started.set()
        await finish.wait()
        return PROPOSAL
    monkeypatch.setattr(server, '_run_model', delayed)
    task = asyncio.create_task(server._make_initiative(memory.get(row.row_id), 'app.studio', server._initiative_epoch))
    await started.wait()
    memory.delete(everything=True)
    finish.set()
    await task
    assert server.initiatives.listing(memory, server.settings) == []
    server.close()


def test_wrapping_quotes_are_accepted_only_when_inner_quote_is_exact(monkeypatch):
    monkeypatch.setattr(proactive, 'supports_generation', lambda e: True)
    monkeypatch.setattr(proactive, 'decide_many', scripted({'useful_initiative': True, 'grounded_initiative': True}))
    monkeypatch.setattr(proactive, 'stream_text', proposal_stream({**PROPOSAL, 'quote': '“' + TEXT + '”'}))
    proposal = proactive.propose(object(), TEXT, app='Studio', window='', locale='it')
    assert proposal['quote'] == TEXT


@pytest.mark.asyncio
async def test_pausing_while_inference_runs_discards_the_result(tmp_path, monkeypatch):
    from bobbd.audit import open_db
    from bobbd.attention import AttentionEngine
    from bobbd.server import BobbServer
    from fake_engine import TrivialEngine
    conn = open_db(tmp_path / 'audit.db')
    memory = MemoryStore(tmp_path / 'memory.db')
    row = memory.observe(Observation(app='Studio', text=TEXT))
    server = BobbServer(AttentionEngine(TrivialEngine()), conn, memory=memory)
    async def disable(*a, **kw):
        server.apply_settings({'context_proactive': False})
        return PROPOSAL
    monkeypatch.setattr(server, '_run_model', disable)
    await server._make_initiative(memory.get(row.row_id), 'app.studio', server._initiative_epoch)
    assert conn.execute('SELECT count(*) FROM initiatives').fetchone()[0] == 0
    server.close()


def test_notification_is_once_across_restart_with_global_cooldown(setup):
    store, memory, hit = setup
    store.add(hit, PROPOSAL, now=100000)
    identifier = store.listing(memory, Settings(), now=100001)[0]['id']
    assert store.mark_presented(identifier, now=100002)
    reopened = proactive.InitiativeStore(store.conn)
    assert not reopened.mark_presented(identifier, now=101000)
    assert reopened.listing(memory, Settings(), now=101001)[0]['announced_at'] == 100002
    other = replace(hit, app='Other')
    reopened.add(other, PROPOSAL, now=100003)
    other_id = reopened.conn.execute("SELECT id FROM initiatives WHERE app='Other'").fetchone()[0]
    assert not reopened.mark_presented(other_id, now=100005)
    assert reopened.mark_presented(other_id, now=101002)
    reopened.respond(identifier, 'snooze', now=101003)
    assert not reopened.mark_presented(identifier, now=101004)
    assert reopened.mark_presented(identifier, now=104604)


def test_resolved_document_supersedes_old_source_even_when_quote_survives(setup):
    store, memory, hit = setup
    hit = replace(hit, window='Progetto Rossi')
    store.observe(hit, now=1000)
    store.add(hit, PROPOSAL, now=1000)
    revision = replace(hit, id=hit.id + 1, text=TEXT + '\nAggiornamento: preventivo ricevuto e riunione completata.')
    store.observe(revision, now=1001)
    assert not store.is_current(hit)
    assert store.conn.execute("SELECT count(*) FROM initiatives WHERE status='pending'").fetchone()[0] == 0
    # An earlier in-flight model cannot reintroduce the resolved suggestion.
    store.add(hit, PROPOSAL, now=1002)
    assert store.listing(memory, Settings(), now=1003) == []


def test_same_window_different_web_document_does_not_erase_pending_work(setup):
    store, memory, hit = setup
    hit = replace(hit, window='Safari', url='https://example.test/project/one')
    store.observe(hit, now=1000)
    store.add(hit, PROPOSAL, now=1000)
    store.observe(replace(hit, id=2, url='https://example.test/project/two', text='Unrelated completed work'), now=1001)
    assert store.is_current(hit)
    assert store.conn.execute("SELECT count(*) FROM initiatives WHERE status='pending'").fetchone()[0] == 1


def test_source_growth_requires_new_evaluation_after_restart(setup):
    store, memory, hit = setup
    store.observe(hit, now=1000)
    store.add(hit, PROPOSAL, now=1000)
    revision = replace(hit, text=TEXT + '\nIl preventivo è stato già preparato.')
    restarted = proactive.InitiativeStore(store.conn)
    restarted.observe(revision, now=1001)
    assert not restarted.is_current(hit)
    assert restarted.is_current(revision)
    assert restarted.listing(memory, Settings(), now=1002) == []


def test_reobserving_identical_document_keeps_its_suggestion(setup):
    store, memory, hit = setup
    store.observe(hit, now=1000)
    store.add(hit, PROPOSAL, now=1000)
    store.observe(hit, now=1001)
    item = store.listing(memory, Settings(), now=1002)[0]
    assert item['title'] == PROPOSAL['title']
    assert 'source_digest' not in item and 'source_scope' not in item


def test_cancelled_initiative_does_not_generate_or_publish(monkeypatch):
    monkeypatch.setattr(proactive, 'supports_generation', lambda e: True)
    cancel = threading.Event()
    cancel.set()
    monkeypatch.setattr(proactive, 'decide_many', lambda *a: pytest.fail('Cancelled job ran inference'))
    assert proactive.propose(object(), TEXT, app='Studio', window='', locale='it', cancel=cancel) is None


@pytest.mark.asyncio
async def test_foreground_model_work_preempts_background_preparation(tmp_path, monkeypatch):
    from bobbd.audit import open_db
    from bobbd.attention import AttentionEngine
    from bobbd.server import BobbServer
    from fake_engine import TrivialEngine
    server = BobbServer(AttentionEngine(TrivialEngine()), open_db(tmp_path / 'audit.db'))
    started = threading.Event()
    def preparation(*a, **kw):
        started.set()
        assert kw['cancel'].wait(3), 'Foreground request failed to stop proactive generation'
        return None
    monkeypatch.setattr(proactive, 'propose', preparation)
    task = asyncio.create_task(server._run_model(proactive.propose, cancel=server._initiative_cancel))
    for _ in range(100):
        if started.is_set(): break
        await asyncio.sleep(.01)
    assert started.is_set()
    assert await server._run_model(lambda: 'foreground answer') == 'foreground answer'
    assert await task is None
    server.close()
