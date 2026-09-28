# ADR-008 — Tier 0: a small, checked personal model first

Status: accepted, 2026-09-28

## Context

VISION rule 5 and SPECIALIST.md: a fast decision model beside the text
model, minted on the Mac from the user's own behaviour. The research model
in `specialist/` is a 706,048-parameter byte-level transformer adapted from
CUA-S1-FORMS. It needs PyTorch (not in the bundle) and thousands of labels;
a person produces tens of answers a week.

## Decision

Ship tier 0 now as a weighted logistic regression over stable hashed
features — sender and domain, automated-sender markers, subject and body
words, thread length, time — trained with AdaGrad in NumPy
(`leonardd/specialist.py`). It learns one question for mail and chat
messages: would this person want to hear about this?

- **Labels by trust.** The user's approve and dismiss; implicit ones (a
  reply started to that message within three days, uncensored; a message
  left unread within seconds, weak); the resident model's own verdicts,
  weakly, as the prior. Its own tier-0 verdicts are never training data.
- **It earns the right to decide.** It turns itself on only after
  validation on the newest of the user's own labels it was not trained on:
  at least as accurate as the resident model on them, and right at least
  95% of the time when it says "stay quiet".
- **It only decides the safe side alone.** A confident "this can wait" is
  decided at tier 0 in well under a millisecond; everything else, and
  every "this needs you", still goes to the resident model, which also
  writes the card.
- **It keeps being checked.** 5% of what it would decide alone still goes
  to the resident model; every tier-1 decision records the specialist's
  probability. Mind shows agreement with the user and with the general
  model, how often it decided alone, and how fast.
- Retraining happens after twelve new answers or a day, off the event loop,
  in well under a second. Turning learning off turns tier 0 off.

## Consequences

The "gets faster the longer you use it" claim is real in 1.0 for the most
common decision, and measurable in Mind rather than asserted. The model is
calibrated by construction and small enough to reason about.

It will not capture the subtleties a sequence model could; that is the job
of the transformer when the data exists, trained on the same labels, behind
the same validation gate.
