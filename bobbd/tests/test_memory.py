import time

import pytest

from bobbd.memory import (
    REDACTED,
    MemoryStore,
    Observation,
    fts_query,
    normalize,
    query_terms,
    redact,
)

MARCO = (
    "Da: Marco Rossi <marco@studiorossi.it>\n"
    "Oggetto: Preventivo revisione\n"
    "Ciao Gabriele, ti allego il preventivo per la revisione del sito.\n"
    "Il totale è 4.800 euro, IBAN IT60 X054 2811 1010 0000 0123 456.\n"
    "Mi serve una conferma entro venerdì."
)


@pytest.fixture
def store(tmp_path):
    s = MemoryStore(tmp_path / "memory.db")
    yield s
    s.close()


def test_normalize_collapses_spaces_and_drops_blank_lines():
    assert normalize("  a   b \n\n\t c  \n") == "a b\nc"


# ---------------------------------------------------------------- redaction


def test_redacts_a_luhn_valid_card_number():
    text, n = redact("Carta: 4111 1111 1111 1111 scade 12/29")
    assert "4111" not in text and REDACTED in text and n == 1


def test_leaves_a_number_that_fails_luhn_alone():
    text, n = redact("Ordine 1234 5678 9012 3456")
    assert "1234 5678 9012 3456" in text and n == 0


def test_never_redacts_an_iban():
    text, _ = redact(MARCO)
    assert "IT60 X054 2811 1010 0000 0123 456" in text


def test_redacts_private_keys_tokens_and_password_lines():
    raw = (
        "-----BEGIN OPENSSH PRIVATE KEY-----\nabc\n-----END OPENSSH PRIVATE KEY-----\n"
        "token ghp_abcdefghijklmnopqrstuvwxyz0123456789\n"
        "Password: hunter2\n"
        "Il tuo codice di verifica è 482913\n"
    )
    text, n = redact(raw)
    assert "PRIVATE KEY" not in text
    assert "ghp_" not in text
    assert "hunter2" not in text
    assert "482913" not in text
    assert n == 4


# ---------------------------------------------------------------- query terms


def test_query_terms_drop_stopwords_in_both_languages():
    assert query_terms("What was the IBAN Marco sent about the preventivo?") == ["iban", "marco", "preventivo"]
    assert query_terms("cosa mi ha scritto Giulia sulla riunione") == ["giulia", "riunione"]


def test_long_words_match_on_a_prefix_numbers_match_exactly():
    assert fts_query(["preventivi"]) == '"preventi"*'
    assert fts_query(["inv-2041"]) == '"inv 2041"'
    assert fts_query(["iban"]) == '"iban"'


# ---------------------------------------------------------------- observe / dedup


def test_protected_apps_are_refused_before_anything_is_read(store):
    result = store.observe(Observation(app="1Password", text="secret vault contents " * 5), protected=True)
    assert result.outcome == "refused"
    assert store.stats()["rows"] == 0


def test_short_text_is_not_worth_a_row(store):
    assert store.observe(Observation(app="Finder", text="Desktop")).outcome == "refused"


def test_identical_window_merges_instead_of_duplicating(store):
    first = store.observe(Observation(app="Mail", window="Preventivo", text=MARCO, ts=1000.0))
    again = store.observe(Observation(app="Mail", window="Preventivo", text=MARCO, ts=1060.0))
    assert first.outcome == "stored"
    assert again.outcome == "merged" and again.row_id == first.row_id
    assert store.stats()["rows"] == 1
    assert store.get(first.row_id).last_seen == 1060.0


def test_text_that_only_grew_replaces_the_row(store):
    first = store.observe(Observation(app="Mail", window="Preventivo", text=MARCO, ts=1000.0))
    grown = MARCO + "\nP.S. Il contratto è in allegato.\nA presto, Marco"
    result = store.observe(Observation(app="Mail", window="Preventivo", text=grown, ts=1100.0))
    assert result.outcome == "grew" and result.row_id == first.row_id
    assert "contratto" in store.get(first.row_id).text
    assert store.stats()["rows"] == 1


def test_different_content_in_the_same_window_is_a_new_row(store):
    store.observe(Observation(app="Safari", window="Docs", text="Pagina uno: installazione del prodotto", ts=1000.0))
    store.observe(Observation(app="Safari", window="Docs", text="Pagina due: configurazione avanzata", ts=1010.0))
    assert store.stats()["rows"] == 2


def test_slow_drift_is_compared_against_the_stored_row_not_the_last_seen(store):
    base = "\n".join(f"riga numero {i} del documento" for i in range(20))
    store.observe(Observation(app="Pages", window="Report", text=base, ts=1000.0))
    text = base
    outcomes = []
    for step in range(10):
        text = text.replace(f"riga numero {step} del", f"riga modificata {step} del")
        outcomes.append(store.observe(Observation(app="Pages", window="Report", text=text, ts=2000.0 + step)).outcome)
    # Each single step changes 5% of lines and merges, but by the third step
    # the text has drifted past the threshold from what was *stored*.
    assert "stored" in outcomes
    assert store.stats()["rows"] >= 2


def test_secrets_never_reach_the_index(store):
    store.observe(Observation(app="Notes", window="Varie", text="Password: hunter2\nnote di lavoro importanti"))
    hits, _ = store.search("hunter2")
    assert hits == []


# ---------------------------------------------------------------- search


def test_search_finds_the_iban_marco_sent(store):
    store.observe(Observation(app="Mail", window="Preventivo revisione", text=MARCO))
    store.observe(Observation(app="Safari", window="News", text="Le notizie del giorno su economia e politica"))
    hits, terms = store.search("qual era l'IBAN che mi ha mandato Marco?")
    assert hits and hits[0].app == "Mail"
    assert "IT60" in hits[0].excerpt(terms)


def test_italian_plural_finds_singular(store):
    store.observe(Observation(app="Mail", window="Preventivo revisione", text=MARCO))
    hits, _ = store.search("preventivi")
    assert len(hits) == 1


def test_recency_breaks_ties_but_does_not_beat_a_better_match(store):
    now = time.time()
    store.observe(Observation(app="Notes", window="old", text="fattura atlas cloud numero INV-2041 pagata", ts=now - 40 * 86400))
    store.observe(Observation(app="Notes", window="new", text="promemoria generico sulla fattura", ts=now))
    hits, _ = store.search("fattura atlas INV-2041", now=now)
    assert hits[0].window == "old"


def test_search_can_be_scoped_to_an_app(store):
    store.observe(Observation(app="Mail", window="a", text="riunione di progetto giovedì alle dieci"))
    store.observe(Observation(app="Slack", window="b", text="riunione spostata a venerdì mattina"))
    hits, _ = store.search("riunione", app="Slack")
    assert [h.app for h in hits] == ["Slack"]


def test_empty_or_stopword_query_returns_nothing(store):
    store.observe(Observation(app="Mail", window="x", text=MARCO))
    assert store.search("what is the")[0] == []


# ---------------------------------------------------------------- deletion and retention


def test_delete_by_app_by_row_and_by_query(store):
    a = store.observe(Observation(app="Mail", window="a", text="primo messaggio con contenuto lungo"))
    store.observe(Observation(app="Mail", window="b", text="secondo messaggio sulla vacanza in montagna"))
    store.observe(Observation(app="Slack", window="c", text="canale generale discussione sul budget"))
    assert store.delete(row_id=a.row_id) == 1
    assert store.delete(query="vacanza montagna") == 1
    assert store.delete(app="Slack") == 1
    assert store.stats()["rows"] == 0
    assert store.search("budget")[0] == []


def test_delete_needs_a_scope(store):
    with pytest.raises(ValueError):
        store.delete()


def test_sweep_forgets_what_was_not_seen_within_retention(store):
    now = time.time()
    store.observe(Observation(app="Mail", window="old", text="messaggio vecchio da dimenticare", ts=now - 40 * 86400))
    store.observe(Observation(app="Mail", window="new", text="messaggio recente da ricordare", ts=now))
    assert store.sweep(30, now=now) == 1
    assert [h.window for h in store.recent()] == ["new"]


def test_delete_everything_then_compact(store):
    store.observe(Observation(app="Mail", window="x", text=MARCO))
    assert store.delete(everything=True) == 1
    store.compact()
    assert store.stats()["rows"] == 0


def test_database_file_is_owner_only(tmp_path):
    s = MemoryStore(tmp_path / "m.db")
    assert (tmp_path / "m.db").stat().st_mode & 0o777 == 0o600
    s.close()
