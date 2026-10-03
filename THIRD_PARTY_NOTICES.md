# Third-party notices

Bobb's original source code is distributed under the Bobb Source Available License 1.0 (see LICENSE). Third-party materials are excluded from that license and retain their own permissions and obligations.
It includes or downloads the following third-party components under their own licenses.

## Local models and decision runtime

The app downloads pinned weights at first launch and verifies every file's
SHA-256. See `bobbd/bobbd/model-manifest.json` for the complete file list.

- **Qwen3.5 4B**, MLX 4-bit conversion by `mlx-community`, revision
  `0e7ffd5c629ef7719d4cbc04069232580bfa9d9c`. Apache-2.0.
  [Model and license](https://huggingface.co/mlx-community/Qwen3.5-4B-4bit).
- **Kev 4B**, community merged MLX 8-bit conversion by `RoderickQiu`, revision
  `6929ac37119fb11c2db74eb66b10a886c6d0dd3a`. Apache-2.0.
  [Conversion and provenance](https://huggingface.co/RoderickQiu/kev-4b-mlx-8bit).
  The trained fp32 pointer head is preserved and separately checksum-verified.
- **Kev inference source**, © Jared Palmer and contributors, Apache-2.0,
  upstream commit `90512f1c517d977741f2104470a40635408236c9`. Source,
  license and provenance are bundled in `bobbd/bobbd/vendor/kev/`.
  [Upstream](https://github.com/jaredpalmer/kev).

## Bundled with the on-device engine (`bobbd`)

- **Kokoro 82M**, ONNX int8 neural speech weights, Apache-2.0;
  [model](https://huggingface.co/hexgrad/Kokoro-82M). The model and voice bank
  come from the pinned `model-files-v1.0` release of
  [kokoro-onnx](https://github.com/thewh1teagle/kokoro-onnx), whose runtime is MIT.
- **CUA Driver 0.31.0**, macOS ARM64, MIT, © Cua AI, Inc.;
  [source and license](https://github.com/trycua/cua/tree/main/libs/cua-driver).
  Its license is included at `Contents/Resources/drivers/LICENSE`.
- **phonemizer**, GPL-3.0; [source](https://github.com/bootphon/phonemizer).
  **eSpeak NG**, GPL-3.0-or-later; [source](https://github.com/espeak-ng/espeak-ng).
  The eSpeak shared library and data are provided by **espeakng-loader**,
  [source and build instructions](https://github.com/thewh1teagle/espeakng-loader).
  These speech components retain their own licenses; their license files
  remain in the bundled package distributions.

| Component | License |
|---|---|
| CPython 3.12 (python-build-standalone) | Python Software Foundation License; build scripts MPL-2.0 |
| MLX, mlx-metal | MIT, © Apple Inc. |
| mlx-lm | MIT, © Apple Inc. |
| Transformers, Tokenizers, Safetensors, huggingface_hub, hf-xet | Apache-2.0, © Hugging Face |
| PyTorch | BSD-3-Clause |
| NetworkX, SymPy | BSD-3-Clause |
| mpmath, setuptools | BSD / MIT |
| NumPy | BSD-3-Clause |
| ONNX Runtime | MIT |
| kokoro-onnx, espeakng-loader | MIT (eSpeak NG itself GPL-3.0-or-later) |
| phonemizer | GPL-3.0 |
| attrs, cloudpickle, dlinfo, flatbuffers, joblib | MIT / BSD / Apache-2.0 |
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
model libraries depend on them. Bobb's engine starts with the Hugging
Face libraries in offline mode and cannot open a network connection; this is
enforced by a test that fails the build if it ever could
(`bobbd/tests/test_no_network.py`).

## Research components (not shipped in the app)

The personal specialist in `specialist/` adapts the architecture of
**CUA-S1-FORMS** (`cua_s1/model.py`), MIT License, © Cua AI, Inc.
