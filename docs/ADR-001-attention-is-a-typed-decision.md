# ADR-001 — The attention engine is a typed decision, not a prompt

Status: accepted, 2026-09-20

## Context

Bobb must decide, many times a minute, whether to stay silent. The obvious
implementation asks a model in prose and parses what comes back.

That fails for a reason that is structural rather than fixable. Prose gives no
quantity to threshold. A model that writes "I'm fairly confident you'll want to
reply" has produced a token sequence, not a probability; the words are
uncorrelated with the model's actual uncertainty, and nothing downstream can
tune on them. Without a threshold there is no way to trade coverage for
accuracy, and without that trade the product has only one setting: speak every
time, which is the failure mode of every proactive assistant shipped so far.

## Decision

Every attention judgement is a question with a closed answer set, resolved by
a single constrained readout: prefill the system prefix once, fork the KV
cache per question, one forward pass, read logits at one position masked to
the token ids that can begin a valid option, softmax over those alone.

The returned probability is the model's own distribution over the answers,
which is a quantity that can be calibrated against what the user did next.

Three consequences we accept deliberately:

**`schema_mass` is reported, never hidden.** It is the share of the full
vocabulary's probability that landed on any valid option. Renormalizing
without reporting it turns a model answering off-schema into a confident
wrong answer. In the reference implementation this number caught three silent
failures: a readout aimed at a token holding none of the mass, an instruct
model fed a bare completion prompt, and a reasoning model answering `<think>`.
A readout below 0.5 is a failed readout and forces `wait`.

**A confidence floor gates every action.** Below it, the action is downgraded
to `wait` and marked abstained. The floor is user-facing.

**The model is chosen on separation, not accuracy.** Separation is mean
confidence when correct minus mean confidence when wrong, and it is what
decides whether a threshold can gate anything at all. Llama-3.2-3B measures
+0.174 [+0.102, +0.254] against Qwen3-4B's +0.055 [+0.005, +0.116], while
their accuracy difference is not resolvable on that sample. A model that is
slightly less accurate but knows when it is wrong is the better instrument for
a product whose entire mechanism is a threshold.

## Consequences

Bobb cannot use a hosted API for the attention path. See ADR-002. Adding a
new event kind means writing questions, not a prompt, which is more work and a
narrower failure surface. Calibration needs labelled data, which the audit
store is designed to accumulate from real accept/dismiss behaviour.
