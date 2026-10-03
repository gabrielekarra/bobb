# ADR-011: One general agent loop, CUA and neural local speech

All browser and native tasks share one planning/execution contract. User
examples belong in tests, not in site-specific or travel-specific handlers.
The previous video-site completion shortcut has been removed.

Qwen produces task constraints, clarification questions and up to four next
action alternatives referencing exact offered ids. The host rejects unknown
operations, fabricated targets and incompatible element kinds. Kev selects
one joint operation/target option. The host's existing action policy still
controls execution. Repeated unchanged observations inform replanning.

Completion requires exact evidence excerpts from recent observations and a
separate Kev check against the original goal. These checks reduce unsupported
success reports; they do not prove that a small model understands every task
or every comparison correctly. Clarification tokens are scoped to one
connection and expire after fifteen minutes. Explicit user URLs are preserved,
including their HTTP/HTTPS scheme.

The production browser choice below is superseded by [ADR-012](ADR-012-user-applications.md): tasks now use the user's actual browser through native controls. Isolated browser adapters remain explicit developer fixtures. The earlier validation results below refer to those isolated adapters.

CUA Driver 0.31.0 is packaged as a local child process using legacy MCP
2025-06-18, embedded host attribution and disabled telemetry. Browser tasks
use driver-owned isolated Chromium profiles and exact native window/tab
bindings. The adapter exposes bounded click, type and scroll operations,
not arbitrary JSON tools to the model. Native Accessibility is primary;
an additional CUA adapter can serve surfaces it cannot observe. Linux,
Windows, VM/cloud and optional visual-parser components are outside this
consumer Mac package. OS permissions remain necessary for native access.

Kokoro 82M int8 ONNX replaces the system speech synthesizer. Its Italian
`if_sara` and English `af_heart` voices run on two CPU threads in a lazy,
separate worker. The pinned model and voice bank total 120,575,669 bytes.
Playback is scoped to the current request submitted through the microphone.
The command bar owns the voice worker; typed requests, iMessage replies,
suggestions and assignment reports have no speech path. Closing, cancelling,
typing or beginning another turn revokes audio permission and stops queued
playback. The legacy global speech toggle is ignored when loading settings.
MisoTTS's English-only 8B local configuration does not fit this product's
16 GB target alongside the language/decision models.

Validation on this M4 with 24 GB: the actual CUA browser adapter typed a
synthetic query, submitted it and read back its result without the user's
browser profile. The production command field → IPC → local Qwen/Kev →
TaskLoop → CUA pipeline also completed a synthetic local website search,
including typing, clicking, observing and grounded completion. Real local
inference chose valid text-field and Save
actions, generated website destinations without site-specific URL code,
and verified a saved-document observation. The voice worker generated
Italian and English WAVs with IP connections forbidden, at about 437 MB
process peak. These results are not a 16 GB device benchmark or proof of
reliable open-ended automation. Some goal interpretation remains incorrect
in real-model probes, including ambiguous search completion.

CUA-S1 `4b-0.2` is a potential replacement for Kev, distinct from the narrow
Forms and Nano checkpoints. No model switch is made based on the family
name: it needs a quantized Apple silicon runtime and comparison on the same
tasks, including abstention, memory, latency and observed effects.

The [local decision comparison](benchmarks/decision-models-2026-10-01.md)
now covers 48 synthetic text scenarios, evaluated twice with Qwen resident.
Kev scored 91/96, the official CUA-S1 MPS runtime 85/96, and the experimental
4-bit MLX CUA-S1 port 86/96. The unquantized MLX port agreed with MPS on all
96 selections. This evidence supports keeping Kev as the default for now;
it does not measure end-to-end task success or performance on a 16 GB Mac.
