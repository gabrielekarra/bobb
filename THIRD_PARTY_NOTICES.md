# Third-party notices

Bobb's source code is distributed under the MIT License (see LICENSE).
It includes, or downloads with your
permission, the following third-party components under their own licenses.

## The language model

**Llama 3.2 3B Instruct** (4-bit MLX conversion by `mlx-community`,
revision `7f0dc925e0d0afb0322d96f9255cfddf2ba5636e`), downloaded once, with
your consent, during setup.

> Llama 3.2 is licensed under the Llama 3.2 Community License, Copyright ©
> Meta Platforms, Inc. All Rights Reserved.

**Built with Llama.** Use of the model is subject to the
[Llama 3.2 Community License](https://www.llama.com/llama3_2/license/) and
the [Acceptable Use Policy](https://www.llama.com/llama3_2/use-policy/).
Leonard ships only the text model; the license restrictions that apply to
the multimodal Llama 3.2 models do not apply to it.

## Bundled with the on-device engine (`leonardd`)

| Component | License |
|---|---|
| CPython 3.12 (python-build-standalone) | Python Software Foundation License; build scripts MPL-2.0 |
| MLX, mlx-metal | MIT, © Apple Inc. |
| mlx-lm | MIT, © Apple Inc. |
| Transformers, Tokenizers, Safetensors, huggingface_hub, hf-xet | Apache-2.0, © Hugging Face |
| NumPy | BSD-3-Clause |
| Pillow | MIT-CMU (HPND) |
| SentencePiece | Apache-2.0, © Google |
| protobuf | BSD-3-Clause, © Google |
| Jinja2, MarkupSafe, click | BSD-3-Clause, © Pallets |
| PyYAML | MIT |
| regex | Apache-2.0 |
| tqdm | MPL-2.0 and MIT |
| rich, markdown-it-py, mdurl, Pygments, typer, shellingham, colorama | MIT / BSD |
| httpx, httpcore, h11, anyio, idna, certifi, filelock, fsspec, packaging, typing-extensions, annotated-doc | BSD / MIT / Apache-2.0 / MPL-2.0 |

The full license text of every bundled Python package is included inside the
application at `Contents/Resources/daemon/python/lib/python3.12/site-packages/*.dist-info/`.

Network libraries (`httpx`, `huggingface_hub`) are present only because the
model libraries depend on them. Leonard's engine starts with the Hugging
Face libraries in offline mode and cannot open a network connection; this is
enforced by a test that fails the build if it ever could
(`leonardd/tests/test_no_network.py`).

## Research components (not shipped in the app)

The personal specialist in `specialist/` adapts the architecture of
**CUA-S1-FORMS** (`cua_s1/model.py`), MIT License, © Cua AI, Inc.
