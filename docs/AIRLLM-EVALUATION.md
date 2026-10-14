# AirLLM and stronger local models

Evaluated 2026-10-14 against
[lyogavin/airllm](https://github.com/lyogavin/airllm) commit
`0f679cca50a062113ccf27b9c120dda2679c35c6`.

AirLLM can make a model larger than available accelerator memory runnable by
streaming layers from disk. Its README explicitly identifies disk loading as
the bottleneck. Low advertised GPU memory is not the total disk, host-memory,
KV-cache or latency budget. Its large-model CUDA examples are not Mac benchmarks.

The inspected [AutoModel route](https://github.com/lyogavin/airllm/blob/0f679cca50a062113ccf27b9c120dda2679c35c6/air_llm/airllm/auto_model.py)
returns `AirLLMLlamaMlx` unconditionally on Darwin, before architecture dispatch.
That [MLX implementation](https://github.com/lyogavin/airllm/blob/0f679cca50a062113ccf27b9c120dda2679c35c6/air_llm/airllm/airllm_llama_mlx.py)
builds a Llama-style transformer and reloads embedding, layers, norm and output
through the token loop. The README's broad model-family list therefore does
not establish compatibility with Bobb's Qwen3.5 generation or Kev decision
checkpoint on macOS. This is a source-code assessment, not a hardware benchmark.

Bobb keeps Qwen3.5 4B 4-bit and Kev 4B 8-bit as its defaults. A downloaded MLX
generation checkpoint is already selectable in Bobb → Brain. Size suggestions
are conservative RAM estimates, not certified model recommendations: 4B/16 GB,
7–8B/24 GB, 14B/32 GB, 30–32B/64 GB, 70B/128 GB. Kev, macOS, user applications
and context cache all need headroom. A model with more parameters is not
necessarily better at following Bobb's action and structured-output contract.

Before promoting a larger checkpoint, compare it with the default on the same
Mac, prompts and context: first-token and complete-response latency, peak memory
and pressure, exact JSON/schema adherence, tool/recipient selection, grounded
completion, Italian drafting quality and a multi-step screen task. Include cold
and warm runs. Keep the fast decision model and measure whether generation is
the actual bottleneck. Bobb's repository evaluation tools should provide the
baseline; no unmeasured token-rate claims are made here.

AirLLM remains a possible isolated experiment for noninteractive background
analysis after model-architecture compatibility and resource limits are proven.
It is not installed into Bobb's action loop, dependency lockfile or distribution.
No selected model, inference endpoint or user preference was changed by this
assessment.
