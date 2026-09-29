# ADR-007 — Acting from outside, under a permission engine

Status: accepted, 2026-09-28

## Context

VISION rules 1, 4 and 6: Leonard uses applications, never integrates with
them; speed comes from the architecture; any job, not a list of jobs. An
assistant that can only draft is a feature. The product has to do the work —
open the playlist, fill in the sheet, send the message — in whatever app
the user uses, including ones that do not exist yet.

Two ways were available. Plugins and APIs per app are reliable where they
exist and cost one integration per app forever. Driving the interface from
outside, the way a person or VoiceOver does, costs once and covers every
app that exposes an accessibility tree, which on the Mac is nearly all of
them.

The risk of the second is obvious: a model pressing buttons in the user's
apps.

## Decision

Leonard drives applications from outside through the accessibility tree,
one step at a time, with the safety in the shape rather than in the model:

1. **The model never sees or returns anything it could misuse.** Each step
   the app offers opaque ids, fresh per observation, with the words a
   person would use ("“Send” (button, toolbar)"). The engine returns an
   operation and one of those ids. No coordinate, path, command or tool
   name exists in its output space (`leonardd/agent.py`, `act_frame`).
2. **Targets are typed.** A separate question per kind (things to press,
   fields, scroll areas, apps), each with "none of these". Typing into a
   button is not scored badly; it cannot be expressed.
3. **The app re-resolves every id against the live tree** before acting and
   refuses one that has gone, turned secure, or changed kind.
4. **A permission engine judges the real action, not the model's intent**
   (`LeonardCore/Agent/ActionPolicy.swift`): deny in protected apps and
   secure fields; ask before anything whose words mean sending, paying,
   deleting, publishing, signing, running a command, or pressing Return in
   a message box; allow the rest, which only moves focus or can be undone.
   "Always in this app" is remembered per action and label, visible and
   removable in Settings. A stricter mode asks before every step.
5. **The user is always in charge.** ⎋ stops a task anywhere; the panel
   shows the plan, every step and its outcome; Undo uses the field's
   previous value or the app's own ⌘Z. Every task and step is audited and
   listed in Mind.
6. **Blocking beats guessing.** Below the confidence floor, on "none of
   these", on a step that changes nothing, or after thirty steps, the task
   stops and says why — and offers "Show me how".

## Consequences

Any app with an accessibility tree is usable on day one, including Electron
apps (Leonard asks them to build their tree, as VoiceOver does). Apps that
draw everything as pixels are not drivable; their text can still be read
when the user allows OCR.

A 3B model plans and picks worse than a frontier model. The loop is built
so that this costs a stop, not a wrong send: the worst a wrong pick can do
is press something already on screen that the permission engine allowed.

Learned procedures (VISION rule 3) plug into the same loop as guides, never
as replayed macros: each step is still decided on the live screen and
checked by the same engine.
