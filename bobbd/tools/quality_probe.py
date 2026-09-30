"""Print what Bobb actually writes, for a human to read.

Runs a fixed set of drafting, answering and summarizing cases through the
CPU reference engine (`torch_reference.py`) and prints every output. There
is no score: the point is to read them. Used to catch failures a unit test
cannot, like a reply written in the sender's voice.

    PYTHONPATH=. uv run --no-sync python -u tools/quality_probe.py [title filter ...]
"""

from __future__ import annotations

import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from torch_reference import TorchEngine, torch_stream_text  # noqa: E402

from bobbd import compose  # noqa: E402
from bobbd.memory import MemoryStore, Observation  # noqa: E402

EMAILS = [
    ("it-quote", "Marco Rossi <marco@studiorossi.it>", "Preventivo revisione — mi confermi entro venerdì?",
     "Ciao Gabriele, ho rivisto i numeri del preventivo: il totale è 4.800 euro. Mi serve una conferma entro "
     "venerdì per bloccare la disponibilità del team. Fammi sapere, grazie! Marco"),
    ("en-recruiter", "Dana Whitfield <dana@apexsearch.co>", "Quick chat about a Head of Product role?",
     "Hi Gabriele, I'm working with a Series B fintech in London looking for a Head of Product. Would you be "
     "open to a 20-minute call next week? Best, Dana"),
    ("it-formal", "Avv. Maria Bianchi <m.bianchi@studiobianchi.it>", "Documentazione per la pratica 2291",
     "Gentile dott. Karra, le scrivo per chiederle di inviarci entro il 5 ottobre copia del contratto firmato e "
     "della visura camerale aggiornata, necessari per procedere con la pratica. Cordiali saluti, Maria Bianchi"),
]

MEMORY = [
    ("Slack", "#studio-rossi", "Giulia: il preventivo di Marco va bene, possiamo confermare. Budget approvato ieri."),
    ("Mail", "Fattura Atlas Cloud INV-2041", "Atlas Cloud: la fattura INV-2041 di 312,40 euro scade il 30 settembre."),
    ("Safari", "Contratto quadro — Google Docs", "Clausola 7: vesting di 4 anni con cliff di 12 mesi per i fondatori."),
]


def main() -> None:
    engine = TorchEngine(threads=4)
    tmp = Path(tempfile.mkdtemp())
    memory = MemoryStore(tmp / "m.db")
    for app, window, text in MEMORY:
        memory.observe(Observation(app=app, window=window, text=text))

    only = sys.argv[1:]

    def run(title: str, task: compose.Task) -> None:
        if only and not any(word in title for word in only):
            return
        started = time.perf_counter()
        out = torch_stream_text(engine, task.messages, max_tokens=min(task.max_tokens, 160),
                                temperature=task.temperature, prefix=task.prefix)
        print(f"\n=== {title} ({out.tokens} tok, {time.perf_counter() - started:.0f}s CPU)")
        print(out.text)
        if task.sources:
            print("sources:", [f"[{s.n}] {s.app} {s.window}" for s in compose.cited(out.text, task.sources)])
        sys.stdout.flush()

    for key, sender, subject, body in EMAILS:
        event = {"kind": "mail.opened", "app": "Mail", "payload": {"sender": sender, "subject": subject, "body": body}}
        run(f"draft {key}", compose.draft_reply(event, memory, "it"))
    quote = {"kind": "mail.opened", "app": "Mail", "payload": {"sender": EMAILS[0][1], "subject": EMAILS[0][2], "body": EMAILS[0][3]}}
    run("draft it-quote / decline", compose.draft_reply(quote, memory, "it", instruction="decline"))
    run("ask it: quando scade la fattura Atlas?", compose.for_request(compose.Request(prompt="Quando scade la fattura di Atlas e quanto è?"), memory, "it"))
    run("ask en: vesting cliff?", compose.for_request(compose.Request(prompt="What was the cliff in the vesting clause?"), memory, "en"))
    run("ask it: unknown", compose.for_request(compose.Request(prompt="Qual è il numero di telefono di Dana?"), memory, "it"))
    run("summarize notice", compose.summarize_notice({"payload": {"sender": "Atlas Cloud <billing@atlascloud.io>",
        "subject": "Payment overdue — service suspension on Oct 3",
        "body": "Your invoice INV-2041 (EUR 312.40) is 14 days overdue. To avoid suspension of your workspace on "
                "October 3, please update your payment method in the billing dashboard."}}, "it"))
    run("translate", compose.for_request(compose.Request(prompt="", mode="translate",
        selection="Ti confermo che il preventivo va bene, possiamo partire lunedì."), memory, "it"))
    run("tone", compose.review_tone({"payload": {"to": "Marco", "subject": "Ritardo",
        "draft": "Marco, è la terza volta che mandi i file in ritardo. Così non si può lavorare. Sistemate."}}, "it"))


if __name__ == "__main__":
    main()
