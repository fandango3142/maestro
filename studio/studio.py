"""Studio: turn every audio file in inbox/ into library/<song-id>/ (stems + song.json).

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
INBOX, LIBRARY, MODELS = ROOT / "inbox", ROOT / "library", ROOT / "models"
AUDIO_EXT = {".mp3", ".flac", ".wav", ".m4a", ".ogg", ".opus", ".aac"}
SEPARATION_MODEL = "model_bs_roformer_ep_317_sdr_12.9755.ckpt"
SCHEMA_VERSION = 1

# Krumhansl-Kessler key profiles, index 0 = tonic.
MAJOR = np.array([6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88])
MINOR = np.array([6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17])
NOTES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]


def slug(name: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")


def separate(src: Path, dest: Path) -> None:
    """Write dest/instrumental.flac and dest/vocals.flac. The only place that knows the model."""
    from audio_separator.separator import Separator  # slow import; only when needed

    with tempfile.TemporaryDirectory() as tmp:
        # ponytail: library defaults for chunk size; tune mdxc_params on the 4GB GPU box if it OOMs.
        sep = Separator(output_dir=tmp, output_format="FLAC", model_file_dir=str(MODELS))
        sep.load_model(SEPARATION_MODEL)
        for out in sep.separate(str(src)):
            stem = "vocals" if "(vocals)" in out.lower() else "instrumental"
            shutil.move(Path(tmp) / Path(out).name, dest / f"{stem}.flac")


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


def process(src: Path) -> None:
    dest = LIBRARY / slug(src.stem)
    print(f"{time.strftime('%H:%M:%S')} split {src.name} ...")
    started = time.monotonic()
    dest.mkdir(parents=True, exist_ok=True)
    separate(src, dest)
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
    # Written last: its existence means the song is complete.
    (dest / "song.json").write_text(json.dumps(song, indent=2, ensure_ascii=False), encoding="utf-8")
    print(f"{time.strftime('%H:%M:%S')} done  {dest.name}: key {key}, {bpm} bpm, {time.monotonic() - started:.0f}s")


if __name__ == "__main__":
    # Re-scan after every song so files dropped in mid-run get picked up too.
    failed: set[Path] = set()
    while todo := [
        f for f in sorted(INBOX.iterdir())
        if f.suffix.lower() in AUDIO_EXT and f not in failed and not done(f)
    ]:
        f = todo[0]
        if time.time() - f.stat().st_mtime < 10:  # still being copied in
            time.sleep(10)
            continue
        try:
            process(f)
        except Exception as e:  # one bad file must not stop the batch
            print(f"{time.strftime('%H:%M:%S')} FAILED {f.name}: {e}")
            failed.add(f)
    print(f"{time.strftime('%H:%M:%S')} inbox empty, {len(failed)} failed")
