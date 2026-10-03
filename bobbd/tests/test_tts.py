import io
import wave
import numpy as np
import pytest
from bobbd.tts import LocalVoice,chunks,spoken_text

def test_spoken_text_keeps_message_and_numbers_without_reading_code_or_urls():
    text="## Risultato\nIl prezzo è **200 €**. [Dettagli](https://example.com)\n```sh\nprivate command\n```"
    assert spoken_text(text)=="Risultato\nIl prezzo è 200 €. Dettagli"

def test_long_response_is_split_without_losing_its_words_or_limit():
    text=" ".join(["Una risposta italiana con numeri 200 e 2027."]*50)
    parts=list(chunks(text))
    assert all(0<len(p)<=280 for p in parts)
    assert " ".join(parts)==text

def test_audio_output_is_mono_pcm_wav_and_invalid_samples_are_refused():
    voice=LocalVoice.__new__(LocalVoice)
    class Model:
        def create(self,*a,**kw):return np.array([0.,.5,-.5],dtype=np.float32),24000
    voice.model=Model()
    with wave.open(io.BytesIO(voice.synthesize("Ciao","it")),"rb") as f:
        assert (f.getnchannels(),f.getsampwidth(),f.getframerate(),f.getnframes())==(1,2,24000,3)
    with pytest.raises(ValueError):voice.synthesize("Ciao","unsupported")
    voice.model.create=lambda *a,**kw:(np.array([np.nan]),24000)
    with pytest.raises(ValueError):voice.synthesize("Ciao")
