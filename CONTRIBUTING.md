# Contributing to Bobb

Bobb welcomes fixes, evaluations, accessibility improvements, translations and
real workflow reports. The source is available for inspection and contributions
under the [Bobb Source Available License](LICENSE), not an open source license.
You may fork and modify it to contribute to Bobb; redistribution as another
product or unofficial binary is not permitted. The license explains permitted
personal and internal professional use.

By intentionally submitting a contribution, you agree to section 5 of LICENSE:
you keep ownership and grant the maintainer the rights needed to incorporate,
distribute and relicense it as part of Bobb. Submit only work you are authorized
to license; identify third-party material and preserve its notices.

Read [README](README.md), [the capability guide](docs/BOBB.md) and
[the product review](docs/PRODUCT-REVIEW-2026-10-01.md). Use a branch and pull
request with the problem, resulting behavior and relevant validation. Keep app
exclusions and action boundaries ahead of side effects. Keep daemon network
isolation tests. Add meaningful regression tests for behavior changes.

For proactive suggestions, test both useful interventions and deliberate
silence. Include completed work, ambiguous requests, adversarial screen text,
pausing observation, revoked access, deleted sources and restart recovery.
Model confidence is not evidence of correctness; record actual outputs and
limits. Use synthetic or explicitly consented examples, never client data.

Do not commit accounts, API keys, SSH identities, model weights, macOS images,
personal data or runtime databases. Run relevant checks from
[CI](.github/workflows/ci.yml). New UI uses shared Liquid Glass components and
respects reduced transparency. Report app/version, expected outcome and the
observed failure when reporting an automation problem.
