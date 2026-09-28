# ADR-002 — The daemon binds no network socket

Status: accepted, 2026-09-20

## Context

Leonard reads the accessibility tree of whatever is in front of the user and,
when it must, the screen itself. That is the most sensitive data surface on a
personal computer: credentials, medical and financial records, unreleased
work, other people's confidential material that the user is merely a custodian
of.

A "we don't store it" policy does not survive a compromised dependency, a
misconfigured log sink, or an acquisition. The only claim worth making is one
that holds when the policy is ignored.

## Decision

`leonardd` communicates over a unix domain socket at mode 0600 and nothing
else. It binds no TCP port. It opens no outbound connection. Inference is a
resident 4-bit model in the same process.

This is enforced by `tests/test_no_network.py`, which monkeypatches
`socket.socket` to raise on any family other than `AF_UNIX` and then runs a
full decision cycle. The test failing is a release blocker.

Email bodies and screen contents exist in the event payload, in process
memory, and in the local audit store. They are not written to stdout, not
included in crash reports, and not passed to any provider.

## Alternatives rejected

**Cloud for the hard cases, local for the easy ones.** Attractive, and it is
what the original vision document proposes. Rejected for v0.1: the moment a
cloud path exists, the privacy claim becomes a configuration question, and the
interesting cases — the ones worth escalating — are exactly the ones with the
most sensitive context. The model router abstraction stays in the design so
this can be revisited; no remote provider is implemented.

**Local model, cloud telemetry.** Rejected. Decision metadata leaks content.
"Interrupted the user while they were reading a message from X about Y" is the
content.

## Consequences

Leonard cannot reach for a frontier model when the local one is uncertain. It
abstains instead, which is the behaviour ADR-001 already prescribes, so the
uncertain case has a defined outcome rather than a remote call.

Personalization must be local. The audit store is the training set and never
leaves the machine.

This is a competitive position, not only an ethical one. It is the claim that
a competitor building on a hosted API cannot make at any price.
