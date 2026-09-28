# Review of `locali` — read-only, 2026-09-20

Written from Leonard, which depends on this technique. Nothing in `locali` was
modified; another session is working there. Hand this over rather than acting
on it here.

Reviewed at `6ea5746` on branch `system-one-decisions`: `gate.py`, `decide.py`,
`resident_mlx.py`, `schema.py`, `README.md`.

`decide.py` and `resident_mlx.py` hold up. `step_many` rebuilds the batched KV
clone per call and never mutates the caller's cache, so the multi-bucket loop
in `decide_many` is safe. Full-vocab softmax before the grouped sums is the
right order and is what makes `schema_mass` mean anything. Right-padding with
per-row logit picking is correct.

The findings are all in `gate.py`.

## 1. The default threshold is in the regime the README measures at 0% recall

`FrameGate.__init__` defaults to `threshold=0.02` with `metric="luminance"`.
The README's own table, for that metric:

| threshold | event recall |
|---:|---:|
| 0.002 | 100% |
| 0.005 | 100% |
| 0.010 | 0% |

0.02 is twice the value that already missed every event. A caller who
constructs `FrameGate()` and reads the README gets a gate the repository has
measured as detecting nothing.

The likely cause is that 0.02 was chosen for the `area` metric added in
`6ea5746` and the luminance default was not revisited. The two metrics are in
different units — mean absolute luminance difference versus fraction of pixels
that moved — so one shared default cannot be right for both.

Suggestion: default `threshold=None` and resolve per metric, 0.005 for
luminance and whatever the screen measurement supports for area.

## 2. The `area` metric has no measured operating point

`bench_frame.py` does not exercise `FrameGate` at all. There is no sweep for
`area` equivalent to the luminance table, so its threshold and its `epsilon`
default of 0.08 are unmeasured. Given that the whole argument of the README is
that a skip rate without a recall number beside it is a vanity metric, the new
metric shipping without that pair is the one place the repository is not
holding itself to its own standard.

## 3. `signature()` normalizes against frame content, not dtype

```python
peak = 255.0 if out.max() > 1.0 else 1.0
```

The scale is chosen from the frame's own contents. A frame dark enough that
every tile mean falls at or below 1.0 — a black desktop, a screensaver, a dark
room — is divided by 1.0 while its reference was divided by 255.0. The two
signatures are then 255x apart in scale and the distance between them is
meaningless: the gate fires, the dark frame becomes the reference at the wrong
scale, and the next normal frame fires too.

It is a narrow input range, but it is silent when it happens and it lands
exactly on the dark-screen case Leonard will hit constantly.

`changed_area` has the same construction. It is safer, because it takes the
peak from both frames together so at least they agree, but the sensitivity of
`epsilon` still moves with scene brightness: 0.08 against a 255 scale and 0.08
against a 1.0 scale are different thresholds.

Suggestion: take the scale from `frame.dtype` — 255.0 for `uint8`, 1.0 for
float — or accept it as an explicit argument. Never from the pixels.

## 4. The `area` path keeps the raw RGB frame and re-reduces it every check

`_signature` returns the frame unchanged when `metric == "area"`, so the
reference is a full RGB array, and `changed_area` runs `b.mean(axis=2)` over
it on every single call. At screen resolution that is roughly 17 MB retained
and a second full-frame reduction per frame, paid to recompute a value that
never changes between references.

Storing the grayscale reduction as the reference halves both the memory and
the per-frame work, and `changed_area` would take the already-reduced
reference.

## 5. The module docstring and the README describe only the luminance design

`gate.py`'s module docstring argues the fixed-reference and `max_age` design
entirely in camera terms. The screen argument — that magnitude cannot separate
a blinking caret from a changed word, while area separates them by 9x — lives
only in `changed_area`'s docstring, and the README's frame-skipping section
has not been updated for the metric at all. The 9x measurement is the most
interesting result in the file and it is the hardest one to find.

## Not a bug, but relevant to Leonard

`signature()` loops 256 times in Python per frame. At camera resolution that
is the few hundred microseconds the docstring claims. At 3024x1964 it is worth
re-measuring, and it vectorizes cleanly by reshaping when the dimensions
divide evenly.

`decide_many` raises `ValueError` when `schema_mass` is exactly zero. For a
batch pipeline that is right. For Leonard it would take down a decision cycle,
so Leonard catches it and degrades to `wait` rather than letting it propagate.
