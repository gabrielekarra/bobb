"""Honest measurement of task steps across every kind of application.

VISION rule 6: any job, not a list of jobs. This fixture is the check that
the step engine is not secretly an email-and-chat engine: one step each
from file managers, spreadsheets, word processors, browsers and web forms,
code editors, the terminal, notes, calendars, reminders, system settings,
viewers, media players, presentations, photo libraries, contacts, maps,
dialogs, open pop-up menus, and apps that expose no accessibility tree and
are read from their pixels.

Each case is one decision point of a real task, written the way the app
presents it to the daemon: the request, the plan, what was done so far,
the window's text, and the ranked candidates with the words the
accessibility tree gives them — distractors included. The expected answer
is every operation-and-target a careful person would accept.

`run()` scores every case through `agent.score_step` at floor 0 (so the
raw pick and its confidence are visible), then reconstructs what the
shipped floor would have done: a wrong pick above the floor is an action
Leonard would have taken wrongly; below it, a stop. The two are reported
separately, because they cost different things.

This module measures; it does not tune anything to look better.
"""

from __future__ import annotations

import time
from collections.abc import Callable
from dataclasses import dataclass

from . import agent

# ---------------------------------------------------------------- builders


def press(id: str, label: str, role: str = "button", where: str = "", **extra) -> dict:
    return {"id": id, "label": label, "role": role, "kind": "press", "where": where, **extra}


def menu(id: str, path: str) -> dict:
    return press(id, path, role="menu item", where="menu bar")


def row(id: str, label: str, where: str = "", **extra) -> dict:
    return press(id, label, role="row", where=where, **extra)


def field(id: str, label: str, role: str = "text field", value: str = "", focused: bool = False, where: str = "") -> dict:
    return {"id": id, "label": label, "role": role, "kind": "text", "value": value, "focused": focused, "where": where}


def area(id: str, label: str, where: str = "") -> dict:
    return {"id": id, "label": label, "role": "scroll area", "kind": "scroll", "where": where}


def seen(id: str, label: str) -> dict:
    """Words read from the pixels of an app with no accessibility tree."""
    return press(id, label, role="text on screen", where="read from the screen")


@dataclass(frozen=True)
class Case:
    id: str
    family: str
    lang: str
    goal: str
    plan: tuple[str, ...]
    app: str
    window: str
    candidates: tuple[dict, ...]
    # Every acceptable (operation, target ids). An empty tuple of ids means
    # the operation needs no target (DONE, WAIT).
    accept: tuple[tuple[str, tuple[str, ...]], ...]
    screen: str = ""
    history: tuple[tuple[str, str, str], ...] = ()
    apps: tuple[str, ...] = ()
    # For DONE on a question: words the report must contain.
    report_contains: tuple[str, ...] = ()

    def observation(self) -> dict:
        return {
            "id": f"obs_{self.id}",
            "task_id": f"task_{self.id}",
            "step": len(self.history) + 1,
            "app": self.app,
            "window": self.window,
            "digest": f"d_{self.id}",
            "screen_text": self.screen,
            "candidates": list(self.candidates),
            "apps": [{"id": f"app{i + 1}", "label": name} for i, name in enumerate(self.apps)],
        }

    def session(self) -> agent.TaskSession:
        s = agent.TaskSession(id=f"task_{self.id}", goal=self.goal, plan=list(self.plan), app=self.app)
        for i, (operation, target, outcome) in enumerate(self.history, 1):
            s.record(agent.StepRecord(step=i, operation=operation, target=target, outcome=outcome, digest=f"h{i}"))
        return s


FINDER_SIDEBAR = (
    row("sb1", "Recenti", where="sidebar"),
    row("sb2", "Applicazioni", where="sidebar"),
    row("sb3", "Scrivania", where="sidebar"),
    row("sb4", "Documenti", where="sidebar", selected=True),
    row("sb5", "Download", where="sidebar"),
)

FIXTURE: list[Case] = [
    # ------------------------------------------------------------ files
    Case(
        id="finder_open_file", family="files", lang="it",
        goal="apri il contratto Rossi che è in Documenti",
        plan=("Apri la cartella Documenti in Finder", "Apri il file del contratto Rossi"),
        app="Finder", window="Documenti",
        screen="Documenti\nNome  Data di modifica  Dimensioni\nBilancio 2025.numbers\nContratto Rossi.pdf\nFattura 118.pdf\nPreventivo Bianchi.pages",
        candidates=FINDER_SIDEBAR + (
            row("f1", "Bilancio 2025.numbers", where="Documenti"),
            row("f2", "Contratto Rossi.pdf", where="Documenti"),
            row("f3", "Fattura 118.pdf", where="Documenti"),
            row("f4", "Preventivo Bianchi.pages", where="Documenti"),
            press("t1", "Indietro", where="toolbar"),
            press("t2", "Vista", role="pop-up menu", where="toolbar"),
            field("s1", "Cerca", role="search field", where="toolbar"),
        ),
        accept=(("OPEN", ("f2",)),),
    ),
    Case(
        id="finder_new_folder", family="files", lang="it",
        goal="crea una nuova cartella chiamata Fatture 2026 in Documenti",
        plan=("Crea una nuova cartella in Documenti", "Chiamala Fatture 2026"),
        app="Finder", window="Documenti",
        screen="Documenti\nBilancio 2025.numbers\nContratto Rossi.pdf",
        candidates=FINDER_SIDEBAR + (
            row("f1", "Bilancio 2025.numbers", where="Documenti"),
            row("f2", "Contratto Rossi.pdf", where="Documenti"),
            menu("m1", "Archivio › Nuova cartella"),
            menu("m2", "Archivio › Nuova cartella con selezione"),
            menu("m3", "Archivio › Nuova finestra Finder"),
            press("t1", "Indietro", where="toolbar"),
            field("s1", "Cerca", role="search field", where="toolbar"),
        ),
        accept=(("CLICK", ("m1",)),),
    ),
    Case(
        id="finder_name_folder", family="files", lang="it",
        goal="crea una nuova cartella chiamata Fatture 2026 in Documenti",
        plan=("Crea una nuova cartella in Documenti", "Chiamala Fatture 2026"),
        history=(("CLICK", "Archivio › Nuova cartella", "ok"),),
        app="Finder", window="Documenti",
        screen="Documenti\nBilancio 2025.numbers\nContratto Rossi.pdf\ncartella senza titolo",
        candidates=FINDER_SIDEBAR + (
            row("f1", "Bilancio 2025.numbers", where="Documenti"),
            row("f2", "Contratto Rossi.pdf", where="Documenti"),
            field("n1", "cartella senza titolo", value="cartella senza titolo", focused=True, where="Documenti"),
            field("s1", "Cerca", role="search field", where="toolbar"),
        ),
        accept=(("TYPE", ("n1",)),),
    ),
    # ------------------------------------------------------------ spreadsheets
    Case(
        id="numbers_sum_cell", family="spreadsheet", lang="it",
        goal="nella cella B14 metti il totale delle spese da B2 a B13",
        plan=("Seleziona la cella B14", "Scrivi la formula della somma"),
        history=(("CLICK", "B14", "ok"),),
        app="Numbers", window="Spese 2026",
        screen="Spese 2026\nMese | Spesa\nGennaio | 820\nFebbraio | 640\nMarzo | 910\nAprile | 700\nMaggio | 1.050\n"
               "Giugno | 980\nLuglio | 1.200\nAgosto | 450\nSettembre | 1.240\nOttobre | 890\nNovembre | 760\nDicembre | 1.310",
        candidates=(
            field("c0", "Where the cursor is — cell B14", role="cell", focused=True, where="Tabella 1"),
            press("t1", "Inserisci", role="pop-up menu", where="toolbar"),
            press("t2", "Tabella", where="toolbar"),
            press("t3", "Grafico", where="toolbar"),
            press("t4", "Formato", where="toolbar"),
            press("t5", "Ordina e filtra", where="toolbar"),
            menu("m1", "Inserisci › Formula › Somma"),
            field("fb", "Barra della formula", where="Tabella 1"),
        ),
        accept=(("TYPE", ("c0", "fb")), ("CLICK", ("m1",))),
    ),
    Case(
        id="excel_sort", family="spreadsheet", lang="en",
        goal="sort this table by amount, largest first",
        plan=("Select the table", "Sort by the Amount column, descending"),
        app="Microsoft Excel", window="Invoices.xlsx",
        screen="Invoices.xlsx\nClient | Date | Amount\nRossi | 02/09 | 1,200\nBianchi | 05/09 | 340\nVerdi | 11/09 | 2,780",
        candidates=(
            field("c0", "Where the cursor is — cell C1", role="cell", focused=True, where="Sheet1"),
            menu("m1", "Data › Sort…"),
            menu("m2", "Data › Sort Descending"),
            menu("m3", "Data › Filter"),
            press("r1", "Home", role="tab", where="ribbon"),
            press("r2", "Insert", role="tab", where="ribbon"),
            press("r3", "Data", role="tab", where="ribbon"),
            press("b1", "Sort & Filter", role="pop-up menu", where="ribbon"),
            press("b2", "AutoSum", where="ribbon"),
        ),
        accept=(("CLICK", ("m1", "m2", "b1")),),
    ),
    Case(
        id="numbers_next_cell", family="spreadsheet", lang="it",
        goal="aggiungi una riga con Mario Rossi, 35 anni, Milano",
        plan=("Scrivi Mario Rossi nella prima cella libera", "Passa alla cella successiva", "Scrivi 35", "Scrivi Milano"),
        history=(("CLICK", "A5", "ok"), ("TYPE", "Where the cursor is — cell A5", "ok")),
        app="Numbers", window="Clienti",
        screen="Clienti\nNome | Età | Città\nAnna Verdi | 41 | Torino\nLuca Neri | 29 | Roma\nSara Blu | 52 | Napoli\nMario Rossi",
        candidates=(
            field("c0", "Where the cursor is — cell A5", role="cell", value="Mario Rossi", focused=True, where="Tabella 1"),
            press("t1", "Inserisci", role="pop-up menu", where="toolbar"),
            press("t2", "Tabella", where="toolbar"),
            menu("m1", "Tabella › Aggiungi riga sotto"),
        ),
        accept=(("KEY", ("tab",)),),
    ),
    Case(
        id="numbers_answer", family="spreadsheet", lang="it",
        goal="in che mese ho speso di più quest'anno?",
        plan=("Guarda la tabella delle spese", "Trova il mese con la spesa più alta"),
        app="Numbers", window="Spese 2026",
        screen="Spese 2026\nMese | Spesa\nGennaio | 820\nFebbraio | 640\nMarzo | 910\nAprile | 700\nMaggio | 1.050\n"
               "Giugno | 980\nLuglio | 1.200\nAgosto | 450\nSettembre | 1.240\nOttobre | 890\nNovembre | 760\nDicembre | 1.310",
        candidates=(
            field("c0", "Where the cursor is — cell A1", role="cell", focused=True, where="Tabella 1"),
            press("t1", "Inserisci", role="pop-up menu", where="toolbar"),
            press("t3", "Grafico", where="toolbar"),
            press("t5", "Ordina e filtra", where="toolbar"),
        ),
        accept=(("DONE", ()),),
        report_contains=("Dicembre",),
    ),
    # ------------------------------------------------------------ documents
    Case(
        id="pages_bold", family="documents", lang="it",
        goal="metti in grassetto il titolo",
        plan=("Seleziona il titolo", "Applica il grassetto"),
        history=(("CLICK", "Relazione trimestrale", "ok"),),
        app="Pages", window="Relazione Q3",
        screen="Relazione trimestrale\nIl terzo trimestre si è chiuso con ricavi in crescita dell'8%.",
        candidates=(
            field("d0", "Corpo del documento", role="text area", value="Relazione trimestrale\nIl terzo trimestre…",
                  focused=True, where="Relazione Q3"),
            menu("m1", "Formato › Font › Grassetto"),
            menu("m2", "Formato › Font › Corsivo"),
            press("t1", "Inserisci", role="pop-up menu", where="toolbar"),
            press("t2", "Tabella", where="toolbar"),
            press("i1", "Formato", where="toolbar"),
            press("i2", "Grassetto", role="checkbox", where="Formato"),
            press("i3", "Corsivo", role="checkbox", where="Formato"),
        ),
        accept=(("CLICK", ("m1", "i2")),),
    ),
    Case(
        id="word_save", family="documents", lang="en",
        goal="save this document",
        plan=("Save the document",),
        app="Microsoft Word", window="Proposal draft",
        screen="Proposal draft\nDear Ms Bianchi,\nplease find below our proposal for the renovation.",
        candidates=(
            field("d0", "Document body", role="text area", value="Dear Ms Bianchi, please find below…", focused=True),
            menu("m1", "File › Save"),
            menu("m2", "File › Save As…"),
            press("r1", "Home", role="tab", where="ribbon"),
            press("r2", "Insert", role="tab", where="ribbon"),
            press("b1", "Share", where="toolbar"),
        ),
        accept=(("KEY", ("cmd_s",)), ("CLICK", ("m1",))),
    ),
    Case(
        id="save_dialog_name", family="dialogs", lang="it",
        goal="salva il documento come Relazione finale",
        plan=("Apri Salva", "Scrivi il nome Relazione finale", "Premi Salva"),
        history=(("CLICK", "Archivio › Salva…", "ok"),),
        app="Pages", window="Senza titolo",
        screen="Salva con nome:\nTag:\nPosizione: Documenti",
        candidates=(
            field("n1", "Salva con nome:", value="Senza titolo", focused=True, where="dialog"),
            field("n2", "Tag:", where="dialog"),
            press("p1", "Posizione", role="pop-up menu", where="dialog"),
            press("b1", "Annulla", where="dialog"),
            press("b2", "Salva", where="dialog"),
        ),
        accept=(("TYPE", ("n1",)),),
    ),
    Case(
        id="save_dialog_confirm", family="dialogs", lang="it",
        goal="salva il documento come Relazione finale",
        plan=("Apri Salva", "Scrivi il nome Relazione finale", "Premi Salva"),
        history=(("CLICK", "Archivio › Salva…", "ok"), ("TYPE", "Salva con nome:", "ok")),
        app="Pages", window="Senza titolo",
        screen="Salva con nome: Relazione finale\nTag:\nPosizione: Documenti",
        candidates=(
            field("n1", "Salva con nome:", value="Relazione finale", focused=True, where="dialog"),
            field("n2", "Tag:", where="dialog"),
            press("p1", "Posizione", role="pop-up menu", where="dialog"),
            press("b1", "Annulla", where="dialog"),
            press("b2", "Salva", where="dialog"),
        ),
        accept=(("CLICK", ("b2",)), ("KEY", ("return",))),
    ),
    Case(
        id="font_popup_open", family="menus", lang="it",
        goal="usa il font Helvetica per questo paragrafo",
        plan=("Apri il menu dei font", "Scegli Helvetica"),
        history=(("CLICK", "Font", "ok"),),
        app="Pages", window="Relazione Q3",
        screen="Relazione trimestrale",
        candidates=(
            press("o1", "Avenir Next", role="menu item", where="open menu"),
            press("o2", "Futura", role="menu item", where="open menu"),
            press("o3", "Georgia", role="menu item", where="open menu"),
            press("o4", "Helvetica", role="menu item", where="open menu"),
            press("o5", "Helvetica Neue", role="menu item", where="open menu"),
            press("o6", "Times New Roman", role="menu item", where="open menu"),
            press("i1", "Font", role="pop-up menu", where="Formato"),
            press("i2", "Grassetto", role="checkbox", where="Formato"),
        ),
        accept=(("CLICK", ("o4",)),),
    ),
    # ------------------------------------------------------------ browsers and the web
    Case(
        id="safari_search", family="browser", lang="it",
        goal="cerca voli per Londra a novembre",
        plan=("Vai alla barra degli indirizzi di Safari", "Cerca voli per Londra a novembre"),
        app="Safari", window="Pagina iniziale",
        screen="Preferiti\nApple  iCloud  Google  Wikipedia\nFrequentemente visitati",
        candidates=(
            field("a1", "Indirizzo e ricerca", role="text field", where="toolbar"),
            press("t1", "Indietro", where="toolbar"),
            press("t2", "Mostra barra laterale", where="toolbar"),
            press("t3", "Condividi", where="toolbar"),
            press("t4", "Nuovo pannello", where="toolbar"),
            press("l1", "Google", role="link", where="Preferiti"),
            press("l2", "Wikipedia", role="link", where="Preferiti"),
        ),
        accept=(("TYPE", ("a1",)), ("KEY", ("cmd_l",))),
    ),
    Case(
        id="chrome_new_tab", family="browser", lang="en",
        goal="open a new tab",
        plan=("Open a new tab in Chrome",),
        app="Google Chrome", window="Inbox — Gmail",
        screen="Inbox\nCompose\nPrimary  Promotions  Social",
        candidates=(
            field("a1", "Address and search bar", where="toolbar"),
            press("t1", "Back", where="toolbar"),
            press("t2", "Reload", where="toolbar"),
            press("t3", "Inbox — Gmail", role="tab", where="tabs", selected=True),
            press("t4", "New Tab", where="tabs"),
            menu("m1", "File › New Tab"),
            press("g1", "Compose", where="Gmail"),
        ),
        accept=(("KEY", ("cmd_t",)), ("CLICK", ("t4", "m1"))),
    ),
    Case(
        id="web_form_name", family="web form", lang="it",
        goal="compila il modulo di iscrizione con il mio nome Gabriele Karra e la mail gabriele@karra.it",
        plan=("Scrivi il nome", "Scrivi il cognome", "Scrivi l'email", "Invia il modulo"),
        app="Safari", window="Iscrizione al corso — Scuola Arti",
        screen="Iscrizione al corso\nNome\nCognome\nEmail\nAccetto i termini\nInvia iscrizione",
        candidates=(
            field("w1", "Nome", where="Iscrizione al corso", focused=True),
            field("w2", "Cognome", where="Iscrizione al corso"),
            field("w3", "Email", where="Iscrizione al corso"),
            press("w4", "Accetto i termini", role="checkbox", where="Iscrizione al corso"),
            press("w5", "Invia iscrizione", where="Iscrizione al corso"),
            field("a1", "Indirizzo e ricerca", where="toolbar"),
        ),
        accept=(("TYPE", ("w1",)),),
    ),
    Case(
        id="find_in_page", family="browser", lang="it",
        goal="trova dove si parla di IVA in questa pagina",
        plan=("Apri la ricerca nella pagina", "Cerca IVA"),
        app="Safari", window="Guida fiscale 2026",
        screen="Guida fiscale 2026\nCapitolo 1 — Il regime forfettario\nCapitolo 2 — Le detrazioni",
        candidates=(
            field("a1", "Indirizzo e ricerca", where="toolbar"),
            press("t1", "Indietro", where="toolbar"),
            press("l1", "Capitolo 1 — Il regime forfettario", role="link", where="Guida fiscale 2026"),
            press("l2", "Capitolo 2 — Le detrazioni", role="link", where="Guida fiscale 2026"),
            menu("m1", "Composizione › Trova › Trova…"),
            area("s1", "Guida fiscale 2026"),
        ),
        accept=(("KEY", ("cmd_f",)), ("CLICK", ("m1",))),
    ),
    # ------------------------------------------------------------ code
    Case(
        id="vscode_write_function", family="code", lang="it",
        goal="aggiungi in fondo al file una funzione Python che somma due numeri",
        plan=("Vai in fondo al file", "Scrivi la funzione"),
        app="Code", window="utils.py — progetto",
        screen="utils.py\nimport math\n\ndef area(r):\n    return math.pi * r * r\n",
        candidates=(
            field("e0", "Where the cursor is — utils.py, line 6", role="cursor", focused=True, where="editor"),
            press("x1", "Explorer", role="tab", where="activity bar"),
            press("x2", "Search", role="tab", where="activity bar"),
            press("x3", "Run and Debug", role="tab", where="activity bar"),
            press("f1", "utils.py", role="tab", where="editor tabs", selected=True),
            press("f2", "main.py", role="tab", where="editor tabs"),
            menu("m1", "File › Save"),
        ),
        accept=(("TYPE", ("e0",)),),
    ),
    Case(
        id="xcode_run", family="code", lang="en",
        goal="build and run the app",
        plan=("Run the scheme in Xcode",),
        app="Xcode", window="Leonard — Leonard.xcodeproj",
        screen="Leonard\nBuild Succeeded | Today at 10:14",
        candidates=(
            press("t1", "Run", where="toolbar"),
            press("t2", "Stop", where="toolbar", enabled=True),
            press("t3", "Leonard", role="pop-up menu", where="toolbar"),
            menu("m1", "Product › Run"),
            menu("m2", "Product › Build"),
            press("n1", "Project navigator", role="tab", where="navigator"),
        ),
        accept=(("CLICK", ("t1", "m1")),),
    ),
    Case(
        id="terminal_list", family="terminal", lang="it",
        goal="mostrami quanto spazio occupa la cartella Download",
        plan=("Nel Terminale, calcola lo spazio della cartella Download",),
        app="Terminale", window="gabriele — zsh — 80×24",
        screen="Last login: Mon Sep 28 09:12:40 on ttys000\ngabriele@MacBook ~ %",
        candidates=(
            field("t0", "Terminale", role="text area", value="gabriele@MacBook ~ %", focused=True, where="zsh"),
            menu("m1", "Shell › Nuova finestra"),
            menu("m2", "Shell › Nuovo pannello"),
        ),
        accept=(("TYPE", ("t0",)),),
    ),
    # ------------------------------------------------------------ notes, calendar, reminders, contacts
    Case(
        id="notes_new", family="notes", lang="it",
        goal="crea una nota con la lista della spesa: latte, pane, uova",
        plan=("Crea una nuova nota", "Scrivi la lista della spesa"),
        app="Note", window="Note",
        screen="Note\nOggi\nIdee regalo\nRiunione lunedì",
        candidates=(
            press("n1", "Nuova nota", where="toolbar"),
            press("n2", "Elimina", where="toolbar"),
            press("n3", "Condividi", where="toolbar"),
            row("r1", "Idee regalo", where="Oggi", selected=True),
            row("r2", "Riunione lunedì", where="Oggi"),
            field("s1", "Cerca", role="search field", where="toolbar"),
            field("b1", "Idee regalo", role="text area", value="Idee regalo\nLibro per papà", where="nota"),
        ),
        accept=(("CLICK", ("n1",)), ("KEY", ("cmd_n",))),
    ),
    Case(
        id="notes_body", family="notes", lang="it",
        goal="crea una nota con la lista della spesa: latte, pane, uova",
        plan=("Crea una nuova nota", "Scrivi la lista della spesa"),
        history=(("CLICK", "Nuova nota", "ok"),),
        app="Note", window="Note",
        screen="Note\nOggi\nNuova nota\nIdee regalo",
        candidates=(
            press("n1", "Nuova nota", where="toolbar"),
            row("r0", "Nuova nota", where="Oggi", selected=True),
            row("r1", "Idee regalo", where="Oggi"),
            field("s1", "Cerca", role="search field", where="toolbar"),
            field("b1", "Corpo della nota", role="text area", focused=True, where="nota"),
        ),
        accept=(("TYPE", ("b1",)),),
    ),
    Case(
        id="calendar_new_event", family="calendar", lang="it",
        goal="aggiungi al calendario domani alle 15 una call con Marco",
        plan=("Crea un nuovo evento", "Scrivi Call con Marco domani alle 15"),
        app="Calendario", window="Calendario",
        screen="Settembre 2026\nLun 28  Mar 29  Mer 30\n10:00 Standup\n",
        candidates=(
            press("c1", "Aggiungi evento", where="toolbar"),
            press("c2", "Oggi", where="toolbar"),
            press("c3", "Giorno", role="tab", where="toolbar"),
            press("c4", "Settimana", role="tab", where="toolbar", selected=True),
            press("c5", "Mese", role="tab", where="toolbar"),
            field("s1", "Cerca", role="search field", where="toolbar"),
            menu("m1", "Archivio › Nuovo evento"),
        ),
        accept=(("CLICK", ("c1", "m1")), ("KEY", ("cmd_n",))),
    ),
    Case(
        id="reminders_add", family="reminders", lang="it",
        goal="ricordami di pagare l'affitto",
        plan=("Aggiungi un promemoria", "Scrivi Pagare l'affitto"),
        app="Promemoria", window="Promemoria",
        screen="Promemoria\nComprare le lampadine\nChiamare il dentista",
        candidates=(
            press("r0", "Aggiungi promemoria", where="toolbar"),
            row("r1", "Comprare le lampadine", where="Promemoria"),
            row("r2", "Chiamare il dentista", where="Promemoria"),
            press("l1", "Oggi", where="sidebar"),
            press("l2", "Programmati", where="sidebar"),
            field("s1", "Cerca", role="search field", where="sidebar"),
        ),
        accept=(("CLICK", ("r0",)), ("KEY", ("cmd_n",))),
    ),
    Case(
        id="contacts_add", family="contacts", lang="en",
        goal="add Marco Rossi to my contacts, phone 333 1234567",
        plan=("Create a new contact", "Fill in the name and phone"),
        app="Contacts", window="All Contacts",
        screen="All Contacts\nAnna Verdi\nLuca Neri",
        candidates=(
            press("k1", "Add", where="toolbar"),
            press("k2", "Share", where="toolbar"),
            row("k3", "Anna Verdi", where="All Contacts"),
            row("k4", "Luca Neri", where="All Contacts"),
            field("s1", "Search", role="search field", where="toolbar"),
            menu("m1", "File › New Card"),
        ),
        accept=(("CLICK", ("k1", "m1")), ("KEY", ("cmd_n",))),
    ),
    # ------------------------------------------------------------ system
    Case(
        id="settings_dark_mode", family="system settings", lang="it",
        goal="attiva la modalità scura",
        plan=("Apri Aspetto nelle Impostazioni di Sistema", "Scegli Scuro"),
        history=(("CLICK", "Aspetto", "ok"),),
        app="Impostazioni di Sistema", window="Aspetto",
        screen="Aspetto\nAspetto: Chiaro  Scuro  Automatico\nColore per evidenziare\nDimensioni icone barra laterale",
        candidates=(
            row("s1", "Wi-Fi", where="sidebar"),
            row("s2", "Bluetooth", where="sidebar"),
            row("s3", "Aspetto", where="sidebar", selected=True),
            row("s4", "Scrivania e Dock", where="sidebar"),
            press("a1", "Chiaro", role="option", where="Aspetto", selected=True),
            press("a2", "Scuro", role="option", where="Aspetto"),
            press("a3", "Automatico", role="option", where="Aspetto"),
            press("a4", "Colore per evidenziare", role="pop-up menu", where="Aspetto"),
        ),
        accept=(("CLICK", ("a2",)),),
    ),
    Case(
        id="settings_wifi_pane", family="system settings", lang="en",
        goal="show me the Wi-Fi settings",
        plan=("Open Wi-Fi in System Settings",),
        app="System Settings", window="General",
        screen="General\nAbout\nSoftware Update\nStorage",
        candidates=(
            row("s1", "Wi-Fi", where="sidebar"),
            row("s2", "Bluetooth", where="sidebar"),
            row("s3", "Network", where="sidebar"),
            row("s4", "General", where="sidebar", selected=True),
            press("g1", "About", where="General"),
            press("g2", "Software Update", where="General"),
            field("f1", "Search", role="search field", where="sidebar"),
        ),
        accept=(("CLICK", ("s1",)),),
    ),
    # ------------------------------------------------------------ viewers and media
    Case(
        id="preview_rotate", family="viewer", lang="it",
        goal="ruota questa foto verso sinistra",
        plan=("Ruota l'immagine a sinistra in Anteprima",),
        app="Anteprima", window="IMG_2041.jpeg",
        screen="IMG_2041.jpeg",
        candidates=(
            press("p1", "Ruota a sinistra", where="toolbar"),
            press("p2", "Mostra strumenti di markup", where="toolbar"),
            press("p3", "Condividi", where="toolbar"),
            press("p4", "Ingrandisci", where="toolbar"),
            press("p5", "Riduci", where="toolbar"),
            menu("m1", "Strumenti › Ruota a sinistra"),
            menu("m2", "Strumenti › Ruota a destra"),
        ),
        accept=(("CLICK", ("p1", "m1")),),
    ),
    Case(
        id="music_play_album", family="media", lang="en",
        goal="play the album Abbey Road",
        plan=("Find Abbey Road in the library", "Play it"),
        app="Music", window="Albums",
        screen="Albums\nAbbey Road — The Beatles\nBlue — Joni Mitchell\nKind of Blue — Miles Davis",
        candidates=(
            row("a1", "Abbey Road — The Beatles", where="Albums"),
            row("a2", "Blue — Joni Mitchell", where="Albums"),
            row("a3", "Kind of Blue — Miles Davis", where="Albums"),
            press("c1", "Play", where="playback controls"),
            press("c2", "Next", where="playback controls"),
            press("c3", "Shuffle", role="checkbox", where="playback controls"),
            field("s1", "Search", role="search field", where="sidebar"),
        ),
        accept=(("OPEN", ("a1",)), ("CLICK", ("a1",))),
    ),
    Case(
        id="spotify_pause_done", family="media", lang="it",
        goal="metti in pausa la musica",
        plan=("Premi Pausa",),
        history=(("CLICK", "Pausa", "ok"),),
        app="Spotify", window="Spotify Premium",
        screen="Focus Flow\nLofi Girl\n1:42  3:05",
        candidates=(
            press("c1", "Riproduci", where="controlli"),
            press("c2", "Successivo", where="controlli"),
            press("c3", "Precedente", where="controlli"),
            press("h1", "Home", where="sidebar"),
            field("s1", "Cosa vuoi ascoltare?", role="search field", where="toolbar"),
        ),
        accept=(("DONE", ()),),
    ),
    Case(
        id="keynote_add_slide", family="presentation", lang="it",
        goal="aggiungi una nuova slide dopo questa",
        plan=("Aggiungi una diapositiva in Keynote",),
        app="Keynote", window="Pitch 2026",
        screen="Pitch 2026\n1 Titolo\n2 Il problema\n3 La soluzione",
        candidates=(
            press("k1", "Aggiungi diapositiva", role="pop-up menu", where="toolbar"),
            press("k2", "Riproduci", where="toolbar"),
            press("k3", "Tabella", where="toolbar"),
            press("k4", "Grafico", where="toolbar"),
            row("s1", "Il problema", where="navigatore diapositive", selected=True),
            row("s2", "La soluzione", where="navigatore diapositive"),
            menu("m1", "Diapositiva › Nuova diapositiva"),
        ),
        accept=(("CLICK", ("k1", "m1")),),
    ),
    Case(
        id="photos_favorites", family="photos", lang="it",
        goal="mostrami le foto preferite",
        plan=("Apri Preferiti in Foto",),
        app="Foto", window="Libreria",
        screen="Libreria\nAnni  Mesi  Giorni  Tutte le foto",
        candidates=(
            row("f1", "Libreria", where="sidebar", selected=True),
            row("f2", "Preferiti", where="sidebar"),
            row("f3", "Recenti", where="sidebar"),
            row("f4", "Persone e animali", where="sidebar"),
            press("f5", "Anni", role="tab", where="toolbar"),
            press("f6", "Mesi", role="tab", where="toolbar"),
            field("s1", "Cerca", role="search field", where="toolbar"),
        ),
        accept=(("CLICK", ("f2",)),),
    ),
    Case(
        id="maps_directions", family="maps", lang="it",
        goal="indicazioni per Milano Centrale",
        plan=("Cerca Milano Centrale in Mappe", "Chiedi le indicazioni"),
        app="Mappe", window="Mappe",
        screen="Mappe\nPreferiti\nCasa  Lavoro",
        candidates=(
            field("m0", "Cerca in Mappe", role="search field", where="sidebar"),
            press("m1", "Indicazioni", where="toolbar"),
            press("m2", "Casa", where="Preferiti"),
            press("m3", "Lavoro", where="Preferiti"),
            press("m4", "Mostra la posizione attuale", where="toolbar"),
        ),
        accept=(("TYPE", ("m0",)), ("CLICK", ("m1",))),
    ),
    # ------------------------------------------------------------ mail, as one app among many
    Case(
        id="mail_reply", family="mail", lang="it",
        goal="rispondi a Marco che va bene giovedì",
        plan=("Rispondi al messaggio di Marco", "Scrivi che giovedì va bene"),
        app="Mail", window="Riunione giovedì — Marco Rossi",
        screen="Marco Rossi\nRiunione giovedì\nCiao, ti va bene giovedì alle 10?",
        candidates=(
            press("b1", "Rispondi", where="toolbar"),
            press("b2", "Rispondi a tutti", where="toolbar"),
            press("b3", "Inoltra", where="toolbar"),
            press("b4", "Archivia", where="toolbar"),
            press("b5", "Elimina", where="toolbar"),
            row("r1", "Marco Rossi — Riunione giovedì", where="In arrivo", selected=True),
            field("s1", "Cerca", role="search field", where="toolbar"),
        ),
        accept=(("CLICK", ("b1",)),),
    ),
    # ------------------------------------------------------------ between apps
    Case(
        id="copy_table", family="between apps", lang="it",
        goal="copia la tabella delle spese e incollala nella mail per il commercialista",
        plan=("Seleziona la tabella in Numbers", "Copiala", "Vai alla mail in Mail", "Incollala nel messaggio"),
        history=(("CLICK", "Tabella 1", "ok"), ("KEY", "⌘A — select all", "ok")),
        app="Numbers", window="Spese 2026",
        screen="Spese 2026\nMese | Spesa\nGennaio | 820\nFebbraio | 640",
        candidates=(
            field("c0", "Where the cursor is — cells A1:B13", role="cell", focused=True, where="Tabella 1"),
            press("t1", "Inserisci", role="pop-up menu", where="toolbar"),
            menu("m1", "Composizione › Copia"),
            menu("m2", "Composizione › Taglia"),
        ),
        accept=(("KEY", ("cmd_c",)), ("CLICK", ("m1",))),
        apps=("Mail",),
    ),
    Case(
        id="paste_in_mail", family="between apps", lang="it",
        goal="copia la tabella delle spese e incollala nella mail per il commercialista",
        plan=("Seleziona la tabella in Numbers", "Copiala", "Vai alla mail in Mail", "Incollala nel messaggio"),
        history=(("CLICK", "Tabella 1", "ok"), ("KEY", "⌘A — select all", "ok"), ("KEY", "⌘C — copy the selection", "ok"),
                 ("OPEN_APP", "Mail", "ok")),
        app="Mail", window="Spese 2026 — per il commercialista",
        screen="A: studio@commercialista.it\nOggetto: Spese 2026\nCiao, ecco le spese:",
        candidates=(
            field("m1", "A:", value="studio@commercialista.it", where="messaggio"),
            field("m2", "Oggetto:", value="Spese 2026", where="messaggio"),
            field("m3", "Corpo del messaggio", role="text area", value="Ciao, ecco le spese:", focused=True, where="messaggio"),
            press("b1", "Invia", where="toolbar"),
            press("b2", "Allega", where="toolbar"),
        ),
        accept=(("KEY", ("cmd_v",)),),
    ),
    Case(
        id="open_other_app", family="between apps", lang="it",
        goal="apri la calcolatrice",
        plan=("Apri Calcolatrice",),
        app="Finder", window="Documenti",
        screen="Documenti",
        candidates=FINDER_SIDEBAR,
        apps=("Calcolatrice (Calculator)", "Calendario (Calendar)"),
        accept=(("OPEN_APP", ("app1",)),),
    ),
    # ------------------------------------------------------------ lists that scroll
    Case(
        id="scroll_to_find", family="lists", lang="it",
        goal="apri la bolletta Enel di agosto",
        plan=("Trova la bolletta Enel di agosto nella lista", "Aprila"),
        app="Finder", window="Bollette",
        screen="Bollette\nA2A gennaio.pdf\nA2A febbraio.pdf\nA2A marzo.pdf\nAcqua aprile.pdf",
        candidates=FINDER_SIDEBAR + (
            row("f1", "A2A gennaio.pdf", where="Bollette"),
            row("f2", "A2A febbraio.pdf", where="Bollette"),
            row("f3", "A2A marzo.pdf", where="Bollette"),
            row("f4", "Acqua aprile.pdf", where="Bollette"),
            area("a1", "Bollette", where="Bollette"),
            field("s1", "Cerca", role="search field", where="toolbar"),
        ),
        accept=(("SCROLL_DOWN", ("a1",)), ("TYPE", ("s1",))),
    ),
    # ------------------------------------------------------------ no accessibility tree: read from the pixels
    Case(
        id="figma_export", family="pixels", lang="it",
        goal="esporta il frame Home come PNG",
        plan=("Seleziona il frame Home", "Apri Esporta", "Esporta come PNG"),
        history=(("CLICK", "Home", "ok"),),
        app="Figma", window="Sito — Figma",
        screen="Livelli\nHome\nChi siamo\nContatti\nEsporta\nPNG 1x\nEsporta Home",
        candidates=(
            seen("v1", "Livelli"),
            seen("v2", "Home"),
            seen("v3", "Chi siamo"),
            seen("v4", "Contatti"),
            seen("v5", "Esporta"),
            seen("v6", "PNG 1x"),
            seen("v7", "Esporta Home"),
        ),
        accept=(("CLICK", ("v7",)),),
    ),
    Case(
        id="remote_desktop_button", family="pixels", lang="en",
        goal="click Approve on the expense report in the remote session",
        plan=("Find the expense report", "Press Approve"),
        app="Windows App", window="Office PC",
        screen="Expense report #4471\nTotal 312.40 EUR\nApprove   Reject   Comment",
        candidates=(
            seen("v1", "Expense report #4471"),
            seen("v2", "Total 312.40 EUR"),
            seen("v3", "Approve"),
            seen("v4", "Reject"),
            seen("v5", "Comment"),
        ),
        accept=(("CLICK", ("v3",)),),
    ),
]


# Requests typed into the command bar, from every kind of work: to do on
# the Mac, or to answer.
ROUTES: list[tuple[str, str]] = [
    ("apri il contratto Rossi in Documenti", "do"),
    ("crea una cartella Fatture 2026 sulla Scrivania", "do"),
    ("ordina la tabella per importo", "do"),
    ("metti in grassetto il titolo", "do"),
    ("attiva la modalità scura", "do"),
    ("aggiungi una slide dopo questa", "do"),
    ("open a new tab and search for flights to London", "do"),
    ("add Marco Rossi to my contacts", "do"),
    ("in che mese ho speso di più?", "answer"),
    ("cosa fa questa funzione?", "answer"),
    ("riassumi questo documento in tre punti", "answer"),
    ("what does this error mean?", "answer"),
    ("traduci in inglese: grazie per la pazienza", "answer"),
    ("quando scade la fattura di Enel?", "answer"),
]


# ---------------------------------------------------------------- scoring


def judge(case: Case, verdict: agent.StepVerdict) -> str:
    """"right", "stopped" (BLOCKED where something was expected) or "wrong"."""
    for operation, targets in case.accept:
        if verdict.operation == operation and (not targets or verdict.candidate_id in targets):
            return "right"
    if verdict.operation == "BLOCKED" and not any(op == "BLOCKED" for op, _ in case.accept):
        return "stopped"
    return "wrong"


def run(engine, *, write: Callable | None = None, report: Callable | None = None,
        floor: float = agent.DEFAULT_FLOOR, cases: list[Case] | None = None, log: Callable[[str], None] = print) -> dict:
    rows = []
    for case in cases or FIXTURE:
        started = time.perf_counter()
        verdict = agent.score_step(engine, case.session(), case.observation(), floor=0.0, write=write, report=report)
        raw = judge(case, verdict)
        # What the shipped floor would have done with the same readout.
        shipped = raw
        if verdict.operation not in ("DONE", "BLOCKED") and verdict.confidence < floor:
            shipped = "stopped"
        text_ok = None
        if case.report_contains and verdict.operation == "DONE":
            text_ok = bool(verdict.text) and all(w.lower() in verdict.text.lower() for w in case.report_contains)
        row = {
            "id": case.id, "family": case.family, "lang": case.lang, "goal": case.goal,
            "operation": verdict.operation, "target": verdict.target_label, "candidate_id": verdict.candidate_id,
            "confidence": round(verdict.confidence, 4), "schema_mass": round(verdict.schema_mass, 4),
            "operation_probabilities": {k: round(v, 3) for k, v in sorted(verdict.operation_probabilities.items(),
                                                                         key=lambda kv: -kv[1])[:4]},
            "text": verdict.text, "text_ok": text_ok, "reason": verdict.reason,
            "raw": raw, "shipped": shipped, "seconds": round(time.perf_counter() - started, 1),
        }
        rows.append(row)
        log(f"{case.id:24s} {raw:8s} {shipped:8s} {verdict.operation:11s} {verdict.target_label[:40]:40s} "
            f"p={verdict.confidence:.2f}" + (f"  “{verdict.text[:70]}”" if verdict.text else ""))
    return {"rows": rows, "summary": summarize(rows, floor)}


def summarize(rows: list[dict], floor: float) -> dict:
    def share(key: str, value: str, subset: list[dict]) -> float:
        return round(sum(1 for r in subset if r[key] == value) / max(1, len(subset)), 3)

    families = sorted({r["family"] for r in rows})
    return {
        "cases": len(rows),
        "floor": floor,
        "raw_right": share("raw", "right", rows),
        "shipped_right": share("shipped", "right", rows),
        "shipped_stopped": share("shipped", "stopped", rows),
        "shipped_wrong": share("shipped", "wrong", rows),
        "by_family": {f: share("shipped", "right", [r for r in rows if r["family"] == f]) for f in families},
        "reports_ok": [r["id"] for r in rows if r["text_ok"]],
        "reports_missed": [r["id"] for r in rows if r["text_ok"] is False],
    }


def run_routes(engine) -> dict:
    rows = []
    for prompt, expected in ROUTES:
        route, p = agent.route_request(engine, prompt)
        rows.append({"prompt": prompt, "expected": expected, "route": route, "p": round(p, 3), "ok": route == expected})
    return {"rows": rows, "accuracy": round(sum(r["ok"] for r in rows) / len(rows), 3)}


__all__ = ["FIXTURE", "ROUTES", "Case", "judge", "run", "run_routes", "summarize"]
