# ADR-010: Local Kev decisions and menu bar start

Bobb starts as an accessory app with only a menu bar icon. There is no setup
window or onboarding flag. Missing models prepare automatically in the
background; the menu bar popover shows progress, errors and retry. macOS
permission prompts belong to the first feature that needs them. This does
not bypass the operating system's permission or code-signing requirements.

Qwen3.5 4B, MLX 4-bit, generates text with thinking disabled. Every typed
decision in the shipping daemon uses Kev's trained pointer head over a
merged 8-bit MLX Kev 4B backbone. This is a community conversion of the
official checkpoint. Both checkpoints and every file hash are pinned in
`bobbd/bobbd/model-manifest.json` and mirrored in Swift's `ModelManifest`.
The combined download is 7,553,749,645 bytes. The official fp32 head and its
temperature are preserved; `weights_only=True` and a pinned checksum guard
head loading. Upstream source and Apache-2.0 license are vendored.

The inference process cannot use IP sockets. Python remains the daemon's
host; Kev replaces the decision model, rather than the process language.
Legacy letter-logit readout and the NumPy specialist remain for research
and fake-engine tests; no shipping decision falls back to them. Adaptive
floors and sender mutes remain deterministic policy after Kev.

For the consumer memory budget, all assistants share the two models. Kev
prefill chunks are 512 tokens, only one question branch runs at a time,
and the MLX allocator cache is bounded to 256 MiB. State is limited to 4,096
tokens and each branch to 8,192; overflow is rejected rather than silently
discarding context. A 16 GB Mac runs one background assignment at a time.
Bobb's confidence contract is the selected option's probability, including
reversed-option averaging when requested. It does not use TypeSafe's
relative-to-uniform confidence as though it were a probability.

An offline synthetic smoke check on the development M4 with 24 GB passed
four EN/IT reply decisions, two Italian task routes and two Italian
rewrites. With both models resident, MLX peaked at 7.13 GB with the short
smoke prompts and 7.40 GB using the shipping rewrite prompts. An IPC probe
also verified startup and a rewrite preserving the recipient, actor and
deadline. These measure those workloads, not full app memory or general
decision quality; a physical
16 GB Mac and longer desktop workloads still need validation.

Laya is a promising smaller decision-model candidate. Replacing Kev requires
evaluation on the same Bobb workload, including Italian, negated requests,
abstention, screens with many candidates and consequential action boundaries.
Its public timing on a T4 and domain-tuned accuracy are not MacBook Air
performance or evidence of better general desktop decisions.
