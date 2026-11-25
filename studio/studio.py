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


def draft_lyrics(dest: Path, language: str | None = None) -> dict | None:
    """Whisper lyric draft -> dest/lyrics.draft.lrc (low confidence; Ryan fixes it in the app).
    Never touches lyrics.roman/deva.lrc. Returns the song.json `lyrics_draft` entry, or None if skipped."""
    if language == "konkani":  # Whisper has no Konkani; manual sync
        return None
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
    segs, info = model.transcribe(np.frombuffer(raw, np.float32), vad_filter=True, condition_on_previous_text=False)
    lines, prev_end = [], None
    for seg in segs:
        if prev_end is not None and seg.start - prev_end > 6:  # long vocal gap = instrumental break
            lines.append(_stamp(prev_end + 0.5))
        lines.append(_stamp(seg.start) + seg.text.strip())
        prev_end = seg.end
    del model
    gc.collect()
    if info.language_probability < 0.5 or not lines:  # unsure what language: draft would be noise
        return None
    (dest / "lyrics.draft.lrc").write_text("\n".join(lines) + "\n", encoding="utf-8")
    return {"source": f"whisper-{WHISPER_MODEL}", "language": info.language, "confidence": "low"}


def done(src: Path) -> bool:
    return (LIBRARY / slug(src.stem) / "song.json").exists()


def process(src: Path, keep_backing: bool) -> None:
    dest = LIBRARY / slug(src.stem)
    print(f"{time.strftime('%H:%M:%S')} split {src.name} ...")
    started = time.monotonic()
    dest.mkdir(parents=True, exist_ok=True)
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
