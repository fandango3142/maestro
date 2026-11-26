"""Studio: turn every audio file in inbox/ into library/<song-id>/ (stems + song.json).
Files in inbox-backing/ also get the vocals split into lead + backing (opt-in: on songs
without real backing vocals the karaoke model mislabels parts of the lead as backing).

Usage:  uv run studio.py
"""
import gc
import json
import re
import shutil
import subprocess
import tempfile
import time
from pathlib import Path

import torch

ROOT = Path(__file__).resolve().parent.parent
INBOX, INBOX_BACKING = ROOT / "inbox", ROOT / "inbox-backing"
LIBRARY, MODELS = ROOT / "library", ROOT / "models"
AUDIO_EXT = {".mp3", ".flac", ".wav", ".m4a", ".ogg", ".opus", ".aac"}
SEPARATION_MODEL = "model_bs_roformer_ep_317_sdr_12.9755.ckpt"
WHISPER_MODEL = "large-v3-turbo"  # lyric drafts; measured 99% words heard, line starts ~0.5s off
BACKING_MODEL = "mel_band_roformer_karaoke_becruily.ckpt"  # Ryan's pick by ear over frazer-becruily BS
SCHEMA_VERSION = 1

def slug(name: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")


def separate(src: Path, dest: Path, model: str, names: dict[str, str]) -> None:
    """Run [model] on [src]; names maps the separator's output label to a file name in [dest]."""
    from audio_separator.separator import Separator  # slow import; only when needed

    with tempfile.TemporaryDirectory() as tmp:
        # GTX 1650, 4-min song: overlap 4 = ~16 min, overlap 2 = 452s (output diff SNR 39 dB, inaudible).
        # fp16 autocast was ~2x SLOWER. 30s clip: batch 1/2 and cudnn.benchmark all 48.9-49.6s,
        # 1.6 GB VRAM -> GPU is compute-bound, no free speed left in settings.
        sep = Separator(
            output_dir=tmp, output_format="FLAC", model_file_dir=str(MODELS),
            mdxc_params={"segment_size": 256, "override_model_segment_size": False,
                         "batch_size": 1, "overlap": 2, "pitch_shift": 0},
        )
        sep.load_model(model)
        for out in sep.separate(str(src)):
            name = next(v for k, v in names.items() if k in out.lower())
            shutil.move(Path(tmp) / Path(out).name, dest / name)
        # Free VRAM before the next model loads: two RoFormers don't fit in 4 GB together.
        del sep
        gc.collect()
        torch.cuda.empty_cache()


def detect_key_bpm(path: Path) -> tuple[str, float]:
    """Essentia (wheel-first): edma profile got Queen right (D major, 153 BPM) where our own
    Krumhansl-on-chroma said Em/76. BPM can still be half/double on ballads; editable in the app."""
    import essentia.standard as es  # Linux-only wheel; Studio runs on the GPU box

    audio = es.MonoLoader(filename=str(path), sampleRate=44100)()
    key, scale, _strength = es.KeyExtractor(profileType="edma")(audio)
    bpm = es.RhythmExtractor2013(method="multifeature")(audio)[0]
    return key + ("m" if scale == "minor" else ""), round(float(bpm), 1)


def _stamp(sec: float) -> str:
    cs = round(sec * 100)
    return f"[{cs // 6000:02d}:{cs // 100 % 60:02d}.{cs % 100:02d}]"


def draft_lyrics(dest: Path) -> dict | None:
    """Whisper lyric draft -> dest/lyrics.draft.lrc (low confidence; Ryan fixes it in the app).
    Never touches lyrics.roman/deva.lrc. Runs for every language incl. Konkani (Ryan: "still pass it");
    language_probability tells the app how unsure Whisper was. Returns the `lyrics_draft` entry."""
    import ctypes, glob, nvidia.cublas, nvidia.cudnn  # CTranslate2 needs the pip CUDA 12 libs preloaded
    for pkg in (nvidia.cublas, nvidia.cudnn):
        for so in sorted(glob.glob(list(pkg.__path__)[0] + "/lib/lib*.so*")):
            try:
                ctypes.CDLL(so, mode=ctypes.RTLD_GLOBAL)
            except OSError:
                pass
    import numpy as np
    from faster_whisper import WhisperModel

    # Decode with ffmpeg ourselves (faster-whisper's PyAV path breaks on newer av releases).
    raw = subprocess.run(["ffmpeg", "-v", "error", "-i", str(dest / "vocals.flac"), "-ac", "1", "-ar", "16000",
                          "-f", "f32le", "-"], capture_output=True, check=True).stdout
    model = WhisperModel(WHISPER_MODEL, device="cuda", compute_type="int8")
    segs, info = model.transcribe(np.frombuffer(raw, np.float32), vad_filter=True,
                                  condition_on_previous_text=False, word_timestamps=True)
    # Re-split into stage-sized lines: new line at a pause (>0.5s), after a comma/full stop once
    # the line has 5+ words, or at 10 words. Whisper's own segments can run 30+ words.
    lines, cur, prev_end = [], [], None
    for w in (w for seg in segs for w in seg.words):
        gap = w.start - prev_end if prev_end is not None else 0
        if cur and (gap > 0.5 or len(cur) >= 10 or (len(cur) >= 5 and cur[-1][1].rstrip()[-1:] in ",.!?")):
            lines.append(_stamp(cur[0][0]) + "".join(t for _, t in cur).strip())
            cur = []
        if gap > 6:  # long vocal gap = instrumental break
            lines.append(_stamp(prev_end + 0.5))
        cur.append((w.start, w.word))
        prev_end = w.end
    if cur:
        lines.append(_stamp(cur[0][0]) + "".join(t for _, t in cur).strip())
    del model
    gc.collect()
    if not lines:
        return None
    text = "\n".join(lines) + "\n"
    (dest / "lyrics.draft.lrc").write_text(text, encoding="utf-8")
    # Whisper writes Hindi (and often Konkani) in Devanagari; tell the app which script the draft is in.
    deva = sum("ऀ" <= c <= "ॿ" for c in text) > sum(c.isascii() and c.isalpha() for c in text)
    return {"source": f"whisper-{WHISPER_MODEL}", "language": info.language,
            "language_probability": round(info.language_probability, 2),
            "script": "deva" if deva else "latin", "confidence": "low"}


def unload_ollama() -> None:
    """Ollama shares the 4 GB GPU: unload any model it holds so a separation can't run out of VRAM.
    keep_alive=0 unloads without stopping the service (no sudo). Silent if Ollama isn't running."""
    import urllib.request

    api = "http://localhost:11434/api"
    try:
        for m in json.load(urllib.request.urlopen(f"{api}/ps", timeout=3))["models"]:
            req = json.dumps({"model": m["name"], "keep_alive": 0}).encode()
            urllib.request.urlopen(urllib.request.Request(f"{api}/generate", req), timeout=30)
            print(f"{time.strftime('%H:%M:%S')} unloaded Ollama model {m['name']} to free the GPU")
    except OSError:
        pass


def done(src: Path) -> bool:
    return (LIBRARY / slug(src.stem) / "song.json").exists()


def process(src: Path, keep_backing: bool) -> None:
    dest = LIBRARY / slug(src.stem)
    print(f"{time.strftime('%H:%M:%S')} split {src.name} ...")
    started = time.monotonic()
    dest.mkdir(parents=True, exist_ok=True)
    unload_ollama()
    separate(src, dest, SEPARATION_MODEL, {"(vocals)": "vocals.flac", "(instrumental)": "instrumental.flac"})
    if keep_backing:  # on the vocal stem: "Vocals" = lead, "Instrumental" = everything else = backing
        separate(dest / "vocals.flac", dest, BACKING_MODEL,
                 {"(vocals)": "lead_vocals.flac", "(instrumental)": "backing_vocals.flac"})
    key, bpm = detect_key_bpm(dest / "instrumental.flac")
    song = {
        "schema_version": SCHEMA_VERSION,
        "id": dest.name,
        "title": src.stem,
        "source_file": src.name,
        "original_key": key,
        "bpm": bpm,
        "separation_model": SEPARATION_MODEL,
    }
    if keep_backing:
        song["backing_model"] = BACKING_MODEL
    try:  # a failed draft must not fail the song
        if draft := draft_lyrics(dest):
            song["lyrics_draft"] = draft
    except Exception as e:
        print(f"{time.strftime('%H:%M:%S')} lyrics draft skipped: {e}")
    # Written last: its existence means the song is complete.
    (dest / "song.json").write_text(json.dumps(song, indent=2, ensure_ascii=False), encoding="utf-8")
    print(f"{time.strftime('%H:%M:%S')} done  {dest.name}: key {key}, {bpm} bpm, {time.monotonic() - started:.0f}s")


if __name__ == "__main__":
    # Re-scan after every song so files dropped in mid-run get picked up too.
    INBOX_BACKING.mkdir(exist_ok=True)
    failed: set[Path] = set()
    while todo := [
        f for d in (INBOX, INBOX_BACKING) for f in sorted(d.iterdir())
        if f.suffix.lower() in AUDIO_EXT and f not in failed and not done(f)
    ]:
        f = todo[0]
        if time.time() - f.stat().st_mtime < 10:  # still being copied in
            time.sleep(10)
            continue
        try:
            process(f, keep_backing=f.parent == INBOX_BACKING)
        except Exception as e:  # one bad file must not stop the batch
            print(f"{time.strftime('%H:%M:%S')} FAILED {f.name}: {e}")
            failed.add(f)
    print(f"{time.strftime('%H:%M:%S')} inbox empty, {len(failed)} failed")
