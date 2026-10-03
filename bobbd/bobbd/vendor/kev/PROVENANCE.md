# Kev inference provenance

Upstream: https://github.com/jaredpalmer/kev/tree/90512f1c517d977741f2104470a40635408236c9
License: Apache-2.0 (LICENSE in this directory).

`model.py` and `mlx_model.py` are copied without changes from this revision.
Bobb loads the merged 8-bit checkpoint described in its pinned model manifest,
uses the architecture's actual hidden dimension for quantized embeddings, caps
state inputs at 4,096 tokens (refusing overflow), prefills in 512-token chunks,
and evaluates independent question branches one at a time. The pointer head,
delimiters, encoder, hidden-state readout and checkpoint temperature are Kev's.
The runtime adapter is in `bobbd/kev.py`. No serving or training dependencies
are vendored. A different upstream revision requires parity and workload tests.
