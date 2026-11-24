"""Studio: turn every audio file in inbox/ into library/<song-id>/ (stems + song.json).
Files in inbox-backing/ also get the vocals split into lead + backing (opt-in: on songs
without real backing vocals the karaoke model mislabels parts of the lead as backing).

Usage:  uv run studio.py
"""
import json
import re
import shutil
import tempfile
import time
from pathlib import Path

import librosa
import numpy as np

ROOT = Path(__file__).resolve().parent.parent
INBOX, INBOX_BACKING = ROOT / "inbox", ROOT / "inbox-backing"
LIBRARY, MODELS = ROOT / "library", ROOT / "models"
AUDIO_EXT = {".mp3", ".flac", ".wav", ".m4a", ".ogg", ".opus", ".aac"}
SEPARATION_MODEL = "model_bs_roformer_ep_317_sdr_12.9755.ckpt"
BACKING_MODEL = "mel_band_roformer_karaoke_becruily.ckpt"  # Ryan's pick by ear over frazer-becruily BS
SCHEMA_VERSION = 1

# Krumhansl-Kessler key profiles, index 0 = tonic.
MAJOR = np.array([6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88])
MINOR = np.array([6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17])
NOTES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]


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


def detect_key_bpm(path: Path) -> tuple[str, float]:
    y, sr = librosa.load(path, sr=22050, mono=True)
    chroma = librosa.feature.chroma_cqt(y=y, sr=sr).mean(axis=1)
    scores = [
        (np.corrcoef(chroma, np.roll(profile, tonic))[0, 1], f"{NOTES[tonic]}{suffix}")
        for profile, suffix in ((MAJOR, ""), (MINOR, "m"))
        for tonic in range(12)
    ]
    tempo, _ = librosa.beat.beat_track(y=y, sr=sr)
    return max(scores)[1], round(float(np.atleast_1d(tempo)[0]), 1)


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
