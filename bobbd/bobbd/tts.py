"""Small local neural speech worker. No network, model Hub or system voice."""
from __future__ import annotations
import argparse
import base64
import io
import json
from pathlib import Path
import re
import sys
import wave
import numpy as np

MODEL_DIRECTORY = "Kokoro-82M-ONNX"
VOICES = {"it": ("if_sara", "it"), "en": ("af_heart", "en-us")}

def spoken_text(text: str) -> str:
    text = re.sub(r"```.*?```", "", text, flags=re.S)
    text = re.sub(r"\[([^\]]+)\]\([^)]*\)", r"\1", text)
    text = re.sub(r"https?://\S+", "", text)
    text = re.sub(r"(?m)^\s*(?:#+|[-*•])\s+", "", text)
    return re.sub(r"[*_`]+", "", text).strip()[:5000]

def chunks(text: str, limit: int = 280):
    remaining = spoken_text(text)
    while remaining:
        if len(remaining) <= limit:
            yield remaining; return
        candidates = list(re.finditer(r"[.!?;]\s+|\n+", remaining[:limit + 1]))
        end = candidates[-1].end() if candidates else remaining.rfind(" ", 0, limit)
        if end <= 0: end = limit
        yield remaining[:end].strip()
        remaining = remaining[end:].lstrip()

class LocalVoice:
    def __init__(self, models: Path):
        import onnxruntime as ort
        ort.disable_telemetry_events()
        from kokoro_onnx import Kokoro
        directory = models / MODEL_DIRECTORY
        options = ort.SessionOptions()
        options.intra_op_num_threads = 2; options.inter_op_num_threads = 1; options.log_severity_level = 3
        # CPU execution keeps this small model off the LLM's Metal budget.
        session = ort.InferenceSession(str(directory / "kokoro-v1.0.int8.onnx"), options,
                                       providers=["CPUExecutionProvider"])
        self.model = Kokoro.from_session(session, str(directory / "voices-v1.0.bin"))
    def synthesize(self, text: str, locale: str = "it") -> bytes:
        if locale not in VOICES: raise ValueError("unsupported voice language")
        voice, language = VOICES[locale]
        samples, rate = self.model.create(text, voice=voice, lang=language, speed=1.0)
        if rate != 24000 or not len(samples) or not np.isfinite(samples).all(): raise ValueError("invalid voice output")
        pcm = (np.clip(samples, -1, 1) * 32767).astype("<i2")
        output = io.BytesIO()
        with wave.open(output, "wb") as wav:
            wav.setnchannels(1); wav.setsampwidth(2); wav.setframerate(rate); wav.writeframes(pcm.tobytes())
        return output.getvalue()

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--models-dir", type=Path, required=True)
    args = parser.parse_args(); model = None
    for line in sys.stdin:
        if len(line) > 64000: return
        try:
            request = json.loads(line); text, locale = request["text"], request.get("locale", "it")
            if not isinstance(text, str) or locale not in VOICES: raise ValueError
            if model is None: model = LocalVoice(args.models_dir)
            for part in chunks(text):
                print(json.dumps({"audio": base64.b64encode(model.synthesize(part, locale)).decode("ascii")}), flush=True)
            print('{"done":true}', flush=True)
        except Exception:
            # Never echo private speech text in an error or log.
            print('{"error":"local_voice_unavailable"}', flush=True); return
if __name__ == "__main__": main()
