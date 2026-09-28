# Leonard — the governing logic

This is the product's constitution. Everything else in `docs/` is subordinate
to it. When a technical decision and this document disagree, this document
wins and the decision gets revisited.

Gabriele's statement of it, 2026-09-20, kept verbatim because the paraphrase
kept losing things:

> Per la parte di browser potrebbe usare https://github.com/browser-use/jev-ultrafast
> e lo stesso principio dovrebbe essere usato per usare qualsiasi app, così da
> renderlo velocissimo, non deve integrarsi dentro nessuna app, semplicemente
> deve usarla e ogni volta che qualcosa viene fatto vedere sullo schermo, deve
> memorizzarla, qualsiasi informazione mostrata a schermo quindi senza entrare
> dentro o essere embedded dentro l'app email per esempio, deve solo imparare
> da quello che fa l'utente e memorizzare quello che fa l'utente e le
> informazioni a schermo, per il resto deve essere solo veloce a eseguire e
> prendere decisioni e in più deve poter generare testo in output (al
> contrario di jev), potrebbero essere anche più modelli in locale, uno che
> prende solo decisioni e sa usare le app ed è velocissimo e uno che sa
> generare testo basandosi sulle informazioni che si conoscono. Deve essere in
> grado dopo aver memorizzato e visto come l'utente usa il pc, di eseguire
> qualsiasi lavoro e aiutare l'utente in qualsiasi lavoro, dalla scrittura di
> email, all'aprire una playlist su Spotify, ad analizzare dati in Excel, a
> scrivere codice, a scrivere e/o modificare documenti, a fare tutto insomma,
> sul Mac deve comparire nei tool in alto a destra, così come fa Siri.

And, stated separately and just as firmly:

> Tutto deve essere locale per il momento, ricordalo.

## The seven rules this imposes

### 1. Never integrate. Only use.

Leonard is never embedded inside Mail, Excel, Spotify or anything else. No
plugin, no extension, no connector, no OAuth, no API key. It drives the
applications the way a person does, from outside.

Every integration we are tempted to build is a per-app cost that buys one app.
Driving from outside costs once and buys every app, including the ones that do
not exist yet.

### 2. Everything shown on screen is remembered.

Any information displayed is captured and stored. Not screenshots — the text
and structure the operating system already has. That store is the knowledge
base, and it is how Leonard comes to know the user without being told
anything.

See `SCREEN-MEMORY.md`.

### 3. Learn by watching, not by asking.

Leonard learns from what the user does. It does not have a training mode, it
does not ask the user to label anything, and it does not need to be taught.
Behaviour is the label.

See `SPECIALIST.md`.

### 4. Speed is a feature of the architecture, not an optimization.

The `jev-ultrafast` principle, applied to every application and not only the
browser: no screenshots in the loop, an indexed table of elements from
structured state, and the operation and the target decided **together in one
pass**. Not a fast model doing a slow thing — a shape that removes the work.

### 5. Two local models, one job each.

| | Job |
|---|---|
| Decision model | Picks the operation and the target. Knows how to use applications. Extremely fast. |
| Text model | Writes, using what the memory knows. |

Jev gives up text generation entirely. That is right for a decision API and
wrong for an assistant, which has to write the email rather than conclude that
one should be written. This is where we depart from Jev on purpose.

### 6. Any job, not a list of jobs.

Write an email. Open a playlist on Spotify. Analyse data in Excel. Write code.
Write or edit a document. Everything.

Any feature list is a description of the MVP, never of the product. If a
design only works for email, it is wrong.

### 7. It lives in the menu bar, like Siri.

Top right, always there, quiet. That is the whole surface: no dock icon, no
window to manage, no app to open. The front door, not a status light.

## The constraint that cuts across all seven

**Everything local. For now, and by architecture, not by policy.**

The daemon binds no network socket and a test fails the build if it can. No
hosted model on any hot path, Jev included. The screen memory never leaves the
machine. Model weights are resident and local.

This is not a privacy position bolted onto the product. It is what makes rules
2 and 3 possible at all: a product that remembers everything on your screen
and learns from everything you do is only sane if none of it ever leaves. The
moment it leaves, the product is indefensible — so it does not leave.

## How to use this document

Before building anything, check it against the seven. In particular:

- Does it integrate with an app, or does it use one? (1)
- Does it need a screenshot in the loop? (4)
- Does it need the user to teach it something? (3)
- Does it only work for email? (6)
- Does anything leave the machine? (the constraint)

A yes to any of those is a design that has drifted, and drift is what this
document exists to catch.
