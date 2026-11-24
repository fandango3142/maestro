# Karaoke: Living Spec

The single source of truth for this project. Update it whenever a decision changes; don't create other spec files.
Owner: Ryan (performer, the only user). Readers: Ryan, Claude, and any agent helping (e.g. UI).

## 0. Status and decisions

**Status (update as work lands)**
- Studio: vocal separation + key/BPM detection working on the GPU box. Drop folder (`~/Desktop/Karaoke Inbox` on the box) auto-processes songs.
- Studio next: backing-vocal split (Ryan picking between becruily mel-band and frazer-becruily BS models), verify key detection against known keys, lyrics (local LRCLIB copy, auto-sync, tap-to-sync), key/tempo render.
- App: mockups for 5 screens in `design/` (code.html + screen.png each); design tokens in `design/stage_ready_karaoke_manager/DESIGN.md`. Flutter app (`app/`) package 1 done: Library + one-screen Stage mode, reading `Documents/Karaoke/library`. Next: setlists, song editor + tap-to-sync, two-screen stage.

**Decisions**
| Decision | Why |
|---|---|
| Everything self-hosted; no third-party processing services, no scraping streaming sites | Their terms can change; copyright |
| Change key on real audio (no MIDI) | Sounds like the record |
| Vocal model: BS-RoFormer Viperx 1297, overlap 2 | Best instrumental quality; overlap 2 = 7.5 min per 4-min song on GTX 1650 (vs 16 min), inaudible difference |
| Key/tempo pre-rendered per song (Signalsmith Stretch, MIT) | Nothing heavy runs on stage |
| Plain files (song.json, LRC), no database | Enough for 500 songs; copies straight to the iPad |
| Git remote = the GPU box directly; audio never in git | Size, copyright |

**Machines**
- **Dev laptop** (Windows, AMD GPU, 24GB RAM): build here; app, lyrics database and lyric sync run here.
- **GPU box** (`ryan@192.168.29.71`, Linux Mint, GTX 1650 4GB, 8GB RAM): Studio batch processing in small daily batches.

## 1. Studio (processing pipeline, Python, `studio/`)

`studio.py` turns each audio file dropped into `inbox/` into `library/<song-id>/`. Steps:
1. Separate → `instrumental.flac`, `vocals.flac` (done)
2. Detect key + BPM → `song.json` (done)
3. Split vocals → `lead_vocals.flac`, `backing_vocals.flac` (testing models)
4. Lyrics: fetch from the local LRCLIB copy → align with ctc-forced-aligner on the vocal track (planned)
5. Render key/tempo/mix → `render/<hash>.flac` (planned)

Run on the box: drop files into the inbox (auto), or `~/karaoke/studio/run.sh`. Log: `tail -f ~/karaoke/studio.log`.

## 2. App: what this is

A dark, offline, stage-ready karaoke app for one performer. It manages a personal song library and setlists, then runs the show: plays the backing track and shows synced lyrics. Think **PowerPoint**. Presenter view on the laptop, lyrics on the audience/performer screen.

- **Platform:** Flutter. Windows laptop first, iPad later (same codebase, so layouts must work with both touch and keyboard).
- **Offline only.** No accounts, no cloud, no network calls. It must work in a venue with no Wi-Fi.
- **Self-contained.** One app with one data folder (default `Documents/Karaoke/`, changeable in Settings). Everything the app knows lives in that folder.
- **Scale:** 50 songs at launch, designed for 500.
- **Languages:** English, Hindi, Konkani, Spanish. Lyrics show in **Romanised** script by default, with **Devanagari** available per song. No script can ever fail to render: bundle Noto Sans + Noto Sans Devanagari.

## 3. App: out of scope for v1

Do not design these: streaming or importing from online services, singing scores, recording, mic effects/reverb, multi-user, cloud sync, and audio processing (vocal removal happens in a separate "Studio" pipeline on another machine; the app only reads its output).

## 4. Data contract (the app reads and writes these; don't invent others)

```
Karaoke/
  library/<song-id>/
    song.json              # metadata + Ryan's settings (below)
    instrumental.flac      # backing track (from Studio)
    vocals.flac            # full vocal stem (from Studio)
    lead_vocals.flac       # optional, from Studio
    backing_vocals.flac    # optional, from Studio
    lyrics.roman.lrc       # optional, Romanised synced lyrics
    lyrics.deva.lrc        # optional, Devanagari synced lyrics
    render/<hash>.flac     # cached audio rendered at Ryan's key/tempo/mix
  setlists/<setlist-id>.json
```

`song.json` (schema_version 1; Studio writes the first block, the app adds the rest and keeps unknown fields untouched):

```json
{
  "schema_version": 1,
  "id": "godacho-panv", "title": "godacho-panv", "source_file": "godacho-panv.mp3",
  "original_key": "Gm", "bpm": 129.2, "separation_model": "...",

  "artist": "", "language": "konkani", "tags": [],
  "key_shift": 0,            // semitones, -6..+6
  "tempo": 1.0,              // 0.80..1.20
  "backing_vocals": 0.0,     // 0..1 mix level
  "guide_vocal": 0.0,        // 0..1 lead vocal mix level
  "lyrics_script": "roman",  // roman | deva
  "notes": ""
}
```

`setlist.json`: `{ "schema_version": 1, "name": "", "date": "", "venue": "", "songs": [ { "id": "godacho-panv", "key_shift": null, "notes": "" } ] }`. A per-gig `key_shift` overrides the song default when set.

**Song status** is derived, not stored: `processing` (no song.json yet) → `needs_lyrics` → `needs_sync` (lyrics but no timings) → `ready`.

## 5. Screens

### 5.1 Library (home)
- A fast list or table of 500 songs: title, artist, language, key (original → shifted, e.g. "Gm → Am"), BPM, duration, status chip.
- Instant search across title and artist. Filters for language, status and tag. Sort by any column.
- One-click preview: play 15s of the rendered backing track.
- Actions: open song, add to setlist (multi-select).

### 5.2 Song editor
- **Settings:** key shift stepper (shows the resulting key), tempo slider, backing-vocals and guide-vocal level sliders, preview transport. Changing key or tempo shows a "rendering…" state until the cached file is ready (rendering takes seconds to minutes; the UI must not block).
- **Lyrics editor:** paste or type plain lyrics, with Romanised and Devanagari tabs and an auto-transliterate button between them.
- **Sync tools:**
  - **Tap-to-sync:** the song plays and Ryan taps Space (or a big on-screen button on iPad) at the start of each line. The current/next line is shown large.
  - **Fine-tune:** a timeline with draggable line markers, a nudge of ±0.1s, and loop on a single line.
  - **Auto-sync:** a button that sends the song to Studio. It shows a status only; the work happens elsewhere.

### 5.3 Setlists
- Create, rename, duplicate and delete setlists. Drag to reorder. The total running time is always visible.
- Per-song gig override for key, plus notes (e.g. "talk to crowd before").
- Validation: warn about any song not `ready`.

### 5.4 Stage mode (the critical screen)
Entered from a setlist. Fullscreen. Two layouts, chosen automatically:

**Two screens:**
- **Lyrics screen** (external display): lyrics only. Current line huge and highlighted, next 1–2 lines dimmed below. Word-level highlight if timings exist. Countdown dots or a bar during intros and instrumental breaks ("next line in 4…3…2…"). No chrome.
- **Presenter screen** (laptop): current and next lyric lines, the setlist queue with the current song marked, elapsed/remaining for the song and the set, current key/tempo, big play/pause, and a clock.

**One screen:** the lyrics layout with a minimal overlay (song title, time remaining, next song) that auto-hides.

**Controls** (keyboard + Bluetooth page-turner pedal, which sends PageDown/PageUp/arrows):

| Key | Action |
|---|---|
| Space / PageDown (tap) | Play / pause |
| → / PageDown (hold 1s) | Next song (cued, paused at start) |
| ← / PageUp (hold 1s) | Restart song / previous |
| B | Blackout the lyrics screen |
| Esc (hold 1s) | Exit stage mode |

Safety: during playback nothing skips or exits on a single accidental press; skipping or exiting requires a hold. There are no confirmation dialogs mid-song.

### 5.5 Settings
Data folder location, audio output device, lyric font size and line count, display assignment (which screen gets the lyrics), and a key-binding remap.

## 6. Visual direction
- **Dark by default.** Background near-black (not pure #000, to avoid glare on projectors), text off-white, **one** accent colour for the current line and primary actions. Status colours only for status chips.
- **Stage legibility first:** lyrics must be readable from 3m, so the current line is at least 64pt on a 1080p lyrics screen. High contrast, no thin weights, no busy backgrounds, and no animation except the line/word highlight and countdown.
- **Calm manager screens:** dense but tidy tables, generous row height, and keyboard-navigable throughout.
- **iPad readiness:** 44pt minimum touch targets, and no hover-only actions.
- Devanagari and Latin text must sit on the same baseline grid. Test with long Konkani/Hindi lines that wrap.

## 7. Non-functional
- Library opens in under 1s with 500 songs.
- Stage mode never stutters. Audio is pre-rendered, so the stage only plays one file.
- The app never writes to `song.json` fields it doesn't own, and keeps unknown fields untouched.
- Every screen has an empty state and handles missing files (e.g. a lyrics file deleted) without crashing.

## 8. What the UI agent should deliver first
1. Clickable mockups or a prototype for **Library**, **Song editor (with tap-to-sync)**, **Setlist** and **Stage mode (both layouts)**, using the sample song `godacho-panv` (Konkani, Gm, 129 BPM) plus fake but realistic entries in all four languages.
2. A small design-token set (colours, type scale, spacing) usable directly as a Flutter `ThemeData`.

## 9. Open questions (ask Ryan, don't assume)
- Word-by-word highlight versus line-only as the default.
- Whether the presenter view shows the full lyrics or just current and next lines.
- Whether to show Romanised and Devanagari side by side on the lyrics screen for any songs.
