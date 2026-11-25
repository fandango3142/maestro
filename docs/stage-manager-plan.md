# Stage manager build plan

Owner: Ryan. Written 2026-11-26. Executed by subagents, one work package (WP) at a time, coordinated by the main Claude session.
Source of truth for *what the app is*: `SPEC.md`. This doc is *how we build the next slice*. If they disagree, SPEC wins. Flag the conflict; don't silently pick one.

## Goal
Turn Maestro from "a library that plays songs" into a stage manager. That means timed setlists with breaks, editable song names, durations, key and tempo rendered in the app, and a two-screen presenter mode.

## Decisions already made (do not re-open)
| Decision | Note |
|---|---|
| No "New" badge | Ryan skipped it |
| The app owns `title`, `artist`, `language` in `song.json` | Studio sets the first guess (filename) and never overwrites: it skips any folder that already has `song.json` |
| Key/tempo render runs **inside the app** | Native C++ (Signalsmith Stretch, MIT) via `dart:ffi`. The same code compiles for iPad later. No Python, no ffmpeg, no GPU box |
| Render output is WAV: `render/k{shift}_t{tempo×100}_v{engine}.wav` | No encoder needed. Readable name = cache key. Engine version in the name invalidates old renders |
| Build order A → B → B2 → C → D → E | A setlists, B names, B2 lyrics text, C key/tempo, D two-screen presenter, E audio trimmer |

## Rules for every subagent (read first)
**Do**
- Read `SPEC.md` §2–§7 and this whole doc before writing code. Read every file you will change in full.
- Match the existing style: plain `StatefulWidget`s, the `K` theme constants in `app/lib/theme.dart`, small files, no state-management package.
- Keep `song.json` and setlist writes **atomic**: write `<file>.tmp`, then rename over the original. Keep unknown fields untouched (load the map, change only your keys, write the map back).
- Put pure logic (time maths, parsing, file naming) in plain Dart functions with unit tests in `app/test/`.
- Mark every deliberate shortcut with a `// ponytail: <what was deferred and why>` comment.
- Before reporting, run from `app/`: `flutter analyze` (0 issues), `flutter test` (all green), `flutter build windows --debug` (succeeds). Paste the actual result lines in your report.
- Report in this shape: **Done & verified** (with evidence) / **Open: Ryan must check** (exact steps) / **Deferred** (ponytail comments) / **Risks**.

**Don't**
- Don't edit `SPEC.md`, `README.md`, anything in `studio/`, or `design/`. The coordinator updates the spec. Another session is working in `studio/` right now.
- Don't commit, push, or touch git config. The coordinator commits after review.
- Don't add a dependency that isn't listed in your WP. If you think you need one, stop and say why in your report.
- Don't add a database, a state-management library (Provider/Riverpod/Bloc), routing packages, or code generation.
- Don't build anything from "Out of scope" lists, even if it's "only 5 lines".
- Don't put copyrighted audio or lyrics in the repo or tests. Use synthetic audio (sine waves) generated in the test.
- Don't add confirmation dialogs inside stage mode. Mid-song safety comes from *holds*, never dialogs (SPEC §5.4).
- Don't invent numbers in your report. If you didn't measure it, say so.

## Shared contracts (all WPs depend on these, don't change them without the coordinator)

### Field ownership in `song.json`
- Studio owns `schema_version`, `id`, `source_file`, `original_key`, `bpm`, `separation_model`, `backing_model`. **The app never writes these.**
- The app owns `title`, `artist`, `language`, `tags`, `key_shift`, `tempo`, `backing_vocals`, `guide_vocal`, `lyrics_script`, `cuts`, `notes`, `bpm_override`, `dismissed_suggestions`.
- Studio additionally owns `cut_suggestions` (WP-E).
- `bpm_override` (optional number): Ryan's correction when Studio's detected `bpm` is half or double. Every BPM shown in the app = `bpm_override ?? bpm`. Studio may re-patch `bpm` at any time, and the override survives that.
- One writer: `Future<void> saveSongFields(Song s, Map<String, Object?> changes)` in `library.dart` (built in WP-B). It throws if asked to write a Studio-owned key.

### Setlist file `setlists/<setlist-id>.json` (replaces the SPEC §4 shape; no setlists exist yet, so stay on schema_version 1)
```json
{
  "schema_version": 1,
  "name": "Friday Konkani & Retro",
  "date": "2026-12-05",
  "venue": "Club Tivoli",
  "start_time": "20:00",
  "changeover_s": 30,
  "items": [
    { "id": "godacho-panv", "key_shift": null, "notes": "Talk to crowd before intro" },
    { "break": true, "minutes": 15, "label": "Dinner break" },
    { "id": "lag-ja-gale", "key_shift": -1, "notes": "" }
  ]
}
```
- `<setlist-id>` = a slug of the name at creation time, with `-2`, `-3`… if taken. Renaming changes `name`, never the file name.
- `start_time` is optional (`""` = no clock times shown). `changeover_s` defaults to 30.
- A song item's `key_shift: null` means "use the song's default".
- An item whose `id` has no library folder is a **missing** song: keep it in the file, show it struck through with a warning, count it as 0:00.

### Durations
- `Duration flacDuration(File f)` reads the FLAC STREAMINFO header (sample rate + total samples) in pure Dart. No audio decoding, no plugin. Returns `null` for a missing or bad file.
- Played length = `(original − sum of cuts) / tempo`. `cuts` is `[]` on every song today; use the formula anyway.
- Set timing is one pure function: `planTimes(items, durationOf, start, changeover)` → each item's start offset plus the total. Changeover goes **after a song only when the next item is also a song**. A break counts as its minutes, with no changeover either side.

### Lyric time mapping (stage + editor)
- Lyrics stay stored against the **original** audio (SPEC §4 Timelines).
- One function, `Duration toOriginal(Duration playbackPos, Song s)`, maps a playback position to an original-audio position. Today that's `pos × tempo`. Cuts slot in here later. Stage mode compares lyric times against `toOriginal(pos)`, never against the raw `pos`.

---

## WP-A: Setlists (with breaks, durations, clock times)
**Goal:** Ryan can build a timed setlist, see the full running time and every song's start clock time, and launch stage mode from it.

**Build**
1. `app/lib/setlist.dart`: a `Setlist` model (load/save atomically, keep unknown fields), the `SetItem` song/break variants, `planTimes`, `listSetlists(root)`, create/duplicate/delete.
2. `flacDuration` in `library.dart`, plus a `Song.duration` getter (cached per load) and `Song.playedDuration` (applies tempo + cuts).
3. A **DURATION** column in the Library table (`m:ss`, `—` if unknown).
4. Sidebar navigation: **Library** and **Setlists** entries. The selected entry is highlighted the way Library is today. The "Start stage" button stays where it is and keeps its current behaviour.
5. The Setlists screen, following `design/setlists/screen.png`:
   - Left column: saved setlists (name, song count, total time) with New / Rename / Duplicate / Delete. Delete asks for confirmation (this is a manager screen, not stage).
   - Header: name, date, venue, **start time** field, **changeover** field (seconds), **TOTAL RUNNING TIME** (big), and **Ends at hh:mm** when a start time is set.
   - Rows, drag to reorder (`ReorderableListView`): number, title, language, status chip, duration, **start clock time** (e.g. `8:14 pm`) when a start time is set, a key override dropdown (Default, −6…+6, showing the resulting key, e.g. `Gm → Am`), a notes field, remove (✕).
   - Break rows look different (muted background, ☕/⏸ icon) with an editable label and minutes, and they reorder like songs.
   - "Add songs" opens a dialog: search box plus a list of library songs, click to append (it can add several before closing). "Add break" appends a 15-minute break.
   - A warning banner when any song isn't `ready` or is missing (as in the wireframe), listing the song names.
   - Autosave on every change (debounced about 500 ms). No Save button.
6. **Launch Stage Mode** button: passes the setlist to `StageScreen`.
7. Stage changes, kept to the minimum WP-A needs:
   - `StageScreen` accepts an item list (songs + breaks) plus per-item key override. The existing Library launch path still works (it passes songs only).
   - **Break item:** audio stopped. The lyrics area shows `Break: back in mm:ss`, counting down from the break's minutes, and the overlay shows the next song. Tapping the pedal (Space/PageDown) or holding → cues the next song.
   - The overlay shows set time remaining (from `planTimes`) alongside song time remaining.
   - Stage mode compares lyric times through `toOriginal()`.
8. Tests: `planTimes` (song-song changeover, song-break-song, break first/last, empty set, missing song = 0), setlist JSON round-trip keeps an unknown field, id collision gets `-2`, `flacDuration` on a FLAC header built in the test (bytes, not a real song).

**Exit criteria**
- [ ] A 3-song + 1-break setlist with start 20:00 and changeover 30 s shows the correct per-row clock times and the correct total (checked by a unit test against hand-computed values).
- [ ] Reorder, rename, duplicate, delete, add/remove songs and breaks all persist across an app restart.
- [ ] A setlist JSON file with an extra unknown field keeps it after an edit (unit test).
- [ ] Launch from a setlist plays songs in setlist order, and break items show the countdown.
- [ ] Library shows durations, and the Library launch path still works.
- [ ] `flutter analyze` clean, `flutter test` green, `flutter build windows --debug` succeeds.

**Out of scope:** multi-select "add to setlist" from Library, printing/exporting setlists, live clock "ahead/behind" (WP-D), fade-out and wake-lock (WP-D), actually *playing* the key override (WP-C), two screens (WP-D), setlist folders/tags, undo history, column sorting.

**Owner field test (Ryan):** build a real setlist of 4 songs + a break and check the total against a stopwatch feel; drag-reorder with the trackpad.

---

## WP-B: Song details (edit names to sort out a big library)
**Goal:** Ryan can quickly fix titles, artists and languages, even for songs he only knows by ear.

**Build**
1. `saveSongFields` (see Shared contracts), atomic, with a guard against Studio-owned keys.
2. A **Song details** dialog, opened from a pencil icon on each Library row and from the `E` key on the focused row:
   - Fields: Title, Artist, Language (dropdown: English, Hindi, Konkani, Spanish, Other).
   - Read-only line: `Source file: godacho-panv.mp3 · Gm · 4:05`, so he can tell songs apart.
   - **BPM** field (editable number) with **½×** and **2×** buttons, because Studio's detector can come out half or double. Saves `bpm_override`. A "reset" link clears it back to the detected value, which is shown greyed beside it.
   - A **Play 15 s** button inside the dialog (reuse the preview logic) to identify a song by ear.
   - Enter saves, Esc cancels. The Library row updates without a full rescan flicker.
   - **Save & next unnamed** button: saves and opens the next song that still needs a name. This is how a 500-song library gets cleaned up in one sitting.
3. "Needs a name" = artist empty **and** title still equals the source file's stem or the id. Add a **Needs name** option to the Status filter (or a separate small filter chip), showing the count.
4. The existing edit-lyrics button stays. Rename its tooltip to "Edit lyrics timing" if needed, so the two pencils aren't confused (use `Icons.edit` for details, keep `Icons.edit_note` for lyrics).
5. Tests: `saveSongFields` keeps unknown fields, refuses `original_key`, and the write is atomic (no `.tmp` left behind); the "needs name" rule.

**Exit criteria**
- [ ] Editing title/artist/language persists to `song.json`, and every other field in the file is byte-for-byte the same value (unit test).
- [ ] Trying to save a Studio-owned key throws (unit test).
- [ ] "Save & next unnamed" walks through all unnamed songs, and the filter count drops as he goes.
- [ ] Search finds a song by its new title straight after saving.
- [ ] analyze / test / build as in WP-A.

**Out of scope:** tags editing, bulk rename, auto-guessing titles (Shazam, filename parsing), editing key/tempo here (WP-C adds that to this same dialog), renaming the song folder or id.

**Owner field test (Ryan):** clean up 10 unnamed songs using only the keyboard plus Play 15 s.

---

## WP-B2: Lyrics text editing (keep timings)
**Goal:** Ryan fixes words in an existing lyrics file without losing any sync work.

**Build** (inside the existing `editor.dart` line list, not a new screen)
1. Edit a line's text in place: double-click or `F2` on the selected line, Enter saves, Esc cancels. **The timing is kept.**
2. Insert a line below (`Ctrl+Enter`). It's untimed until tapped.
3. Delete a line (`Ctrl+Delete`). Its neighbours keep their times.
4. Split a line at the cursor (`Ctrl+Shift+Enter` while editing). The first half keeps the time, and the second half is untimed.
5. Merge with the next line (`Ctrl+M`). The merged line keeps the first line's time.
6. **"Replace all text…"** dialog: paste a full new version. Lines are matched in order: the first N lines keep their times, any extra are untimed, and if fewer lines come in, the leftovers are removed. A warning shows the before/after line counts.
7. All edits go through the existing dirty flag + `Ctrl+S` save. Unsaved edits prompt on leaving (manager screen, so a dialog is fine).
8. Tests: pure list operations (edit, insert, delete, split, merge, replace-all) keep the right times; untimed lines round-trip through `formatLrc`.

**Exit criteria**
- [ ] Each operation keeps every other line's timing byte-identical (unit tests).
- [ ] Edited lyrics save, reload, and play in stage mode with correct sync.
- [ ] analyze / test / build green.

**Out of scope:** Romanised/Devanagari tabs and auto-transliterate, word-level timing, spell-check, undo history beyond the existing Backspace tap-undo.

---

## WP-C: Key and tempo rendered in the app
Split into two parts. **C1 can start in parallel with WP-A** (new files only, run in its own git worktree).

### C1: Native render engine (no UI)
**Goal:** `render(input.flac, output.wav, semitones, tempo)` works on Windows, fast, from Dart.

**Build**
1. `app/native/maestro_render/`: a small C++ library built by CMake:
   - [Signalsmith Stretch](https://github.com/Signalsmith-Audio/signalsmith-stretch) (MIT, header-only). Vendor the exact files plus its LICENSE under `app/native/third_party/`.
   - [dr_flac + dr_wav](https://github.com/mackron/dr_libs) (public domain / MIT-0, single header) for FLAC decode and WAV write.
   - One C function: `int maestro_render(const char* in_path, const char* out_wav, float semitones, float tempo, volatile float* progress)`. It returns 0 on success, or a negative error code (can't open input, can't write output, bad args).
   - Pitch via `setTransposeSemitones`. Tempo by feeding `N` input frames and asking for `N / tempo` output frames.
   - Peak-normalise the output to ≤ 0.98 when it clips (SPEC finding). Never boost quiet songs.
   - Keep the source sample rate and channel count. Write 16-bit PCM WAV, to a `.tmp` name then rename.
2. Hook the library into the Windows build (`app/windows/CMakeLists.txt` → `add_subdirectory` + install the DLL next to the exe) so `flutter build windows` produces it with no manual steps.
3. `app/lib/render.dart`:
   - `renderFileName(shift, tempo)` → `k{shift}_t{round(tempo*100)}_v1.wav` (0/1.00 → no render needed, play `instrumental.flac`).
   - `Future<File> ensureRender(Song s, {int? keyShift, double? tempo, void Function(double)? onProgress})` runs the FFI call in `Isolate.run`, returns the cached file if it already exists, and makes concurrent calls for the same file share one job.
   - FFI binding via `dart:ffi` by hand (one function, so no `ffigen`).
4. Tests (synthetic audio only):
   - The C function also accepts `.wav` input (picked by file extension; dr_wav is already vendored for writing, so this is a few lines). Tests generate a 5 s 440 Hz sine WAV in Dart. No FLAC encoder anywhere.
   - +12 semitones → measured frequency ≈ 880 Hz (±2 %, via zero-crossing count).
   - tempo 1.25 → output length = input / 1.25 (±1 %).
   - 0 semitones, 1.0 tempo → length identical to the input (±1 frame).
   - Peak ≤ 0.98 on a full-scale input shifted +3.
   - Measure and report wall time for a 4-minute stereo 44.1 kHz render on the dev laptop (synthetic noise is fine). The Python reference was 3.7 s, so flag it if over 15 s.

**Exit criteria (C1)**
- [ ] All four synthetic tests pass via `flutter test`.
- [ ] `flutter build windows --release` from a clean checkout produces the DLL next to the exe with no manual steps.
- [ ] Render time for a 4-minute track measured and reported (real number).

**Out of scope (C1):** mixing vocal stems (guide/backing levels), cuts, FLAC encoding, iOS/macOS build files, real-time (live) pitch shifting, render cache cleanup.

### C2: Wire it into the app (after WP-B lands)
**Build**
1. Song details dialog (from WP-B) gains: **Key** stepper −6…+6 showing `Gm → Am`, and **Tempo** slider 0.80–1.20 (step 0.01, shows `1.05x` and the new duration and BPM). Saved via `saveSongFields` (`key_shift`, `tempo`).
2. On save, start `ensureRender` in the background. The Library row shows a **Rendering 42 %** chip, then nothing. The UI never blocks. **Preview** in the dialog plays the render once it's ready, and the original with a "rendering…" note until then.
3. `Song.audio` → the render for the song's own `key_shift`/`tempo` when it exists, else `instrumental.flac`. Stage mode uses the render for **the setlist's key override** if one is set.
4. **Pre-show check** on Launch Stage Mode: list any renders still missing for this setlist (song defaults + gig overrides), render them with a progress bar, and only then enter stage. A "Launch anyway" button plays the originals for songs not yet rendered and says so.
5. Stage lyric timing uses `toOriginal()` with the song's tempo. Lyrics must stay in sync at 0.85x and 1.15x.
6. Tests: `toOriginal` at tempo ≠ 1, choosing the render file for a gig override vs the song default, a missing-render list for a setlist.

**Exit criteria (C2)**
- [ ] Changing key/tempo in the dialog produces a cached render, and replaying with the same settings does not re-render (check file mtime).
- [ ] Stage mode plays the gig-override render, and lyrics stay in sync at tempo 0.85 and 1.15 (unit test on the mapping + Ryan's ear test).
- [ ] The pre-show check renders everything missing before stage starts.
- [ ] analyze / test / build green.

**Out of scope (C2):** guide/backing vocal mix sliders, cuts editor, deleting old renders, per-song "render all keys" batch.

**Owner field test (Ryan):** a song you know, +2 and −2 semitones, at 0.90x and 1.10x. Check it sounds natural and lyrics land on the beat.

---

## WP-D: Two-screen presenter mode
**Goal:** lyrics on the external screen with zero chrome, and the presenter view on the laptop (`design/stage_mode_two_screen/screen.png`).

### D0: Spike first (max half a day, report before building)
Answer with evidence, by trying it in a throwaway branch/worktree:
1. Does Flutter **3.44.1 stable** (installed) support opening a second window natively on Windows? If it's only behind a flag or on master, the answer is no.
2. If not: does [`desktop_multi_window`](https://pub.dev/packages/desktop_multi_window) work with this Flutter version? Can the second window be moved to display 2 and made borderless fullscreen? Use [`screen_retriever`](https://pub.dev/packages/screen_retriever) for display bounds.
3. How do the two windows share state? Expect separate engines with message passing (no shared memory). Measure the lag of a "current position" message sent at 20 fps: is the lyrics window within one frame of the audio?
4. Recommend one approach. **The coordinator and Ryan approve before D1.**

### D1: Build
1. When two displays exist: the lyrics window goes fullscreen on the external display, showing only the lyrics (existing `_lyrics` widget, moved to its own file so both windows use it). The presenter screen goes on the laptop. With one display, keep today's one-screen layout.
2. **Audio plays in exactly one place: the presenter window.** The lyrics window only renders what it's told (song id, original-time position, blackout flag, break countdown). If the lyrics window dies, the music keeps playing.
3. Presenter screen per the wireframe:
   - SONG elapsed/total with a bar, SET elapsed/total with a bar, KEY/TEMPO (with the gig override applied), clock.
   - Current + next 2 lyric lines.
   - **Gig note** for the current/cued song, prominent (e.g. "Talk to crowd before intro").
   - Setlist queue (previous, current marked ACTIVE, next few, breaks shown), each with its duration.
   - **Ahead/behind:** compares the actual time against the planned start of the current item, counting from when Ryan first pressed play in the set. Shows e.g. `3 min behind` in amber, or `on time`.
   - Buttons: previous, big Play/Pause, next, Blackout (44 pt+ touch targets).
4. **Fade out:** hold `F` 1 s → 3 s volume fade, then cue the next song paused. Add a button too.
5. **No sleep:** keep the screen awake during stage mode via [`wakelock_plus`](https://pub.dev/packages/wakelock_plus) (Windows supported). Release it on exit.
6. **Display unplugged mid-show:** music keeps playing, and the presenter switches to the one-screen layout. It must never crash or stop audio.
7. Tests: the ahead/behind maths (pure function), and the state message encode/decode round-trip.

**Exit criteria (D1)**
- [ ] With an external display, lyrics are fullscreen on it with no chrome, and the presenter is on the laptop.
- [ ] Unplugging the display mid-song: audio doesn't stop, and the app falls back to one screen.
- [ ] Fade-out works and needs a hold. A single tap does nothing destructive.
- [ ] The screen doesn't sleep during a 30-minute idle stage session.
- [ ] analyze / test / build green.

**Out of scope:** choosing the audio output device, key-binding remap, a settings screen, full-lyrics scroll on the presenter (SPEC §9 open question; keep current + next 2), word-level highlight, adding songs to the live queue, iPad external display.

**Owner field test (Ryan):** laptop + TV/projector over HDMI, a 3-song + break setlist, run it with the pedal only, then pull the HDMI cable mid-song.

---

---

## WP-E: Audio trimmer with auto-flagged sections
**Goal:** cut dialogue, long intros and silent tails without hunting for them. The app shows **flagged** sections, and Ryan accepts or dismisses each. Nothing is ever cut automatically.

**Split of work**
- **Studio side (other session, `studio/`, not this plan's subagents):** writes `cut_suggestions` `[{start, end, kind: "speech"|"silence", confidence}]` into `song.json`. The contract is in SPEC §4/§5.2. Coordinator agrees the details with the Studio session before E starts.
- **App side (this WP):**
  1. A waveform view in the song editor: backing track solid, vocal stem faint overlay. Waveform peaks are computed once and cached in `render/peaks_v1.bin`. Decode via the C1 native lib (add one `maestro_peaks` function) so there's no second decoder.
  2. Flagged regions are drawn in amber with a label (Speech / Silence + confidence). Click → play from 1 s before the region. **Accept** → appended to `cuts` (with drag handles). **Dismiss** → `{kind,start,end}` goes into `dismissed_suggestions`, and any later suggestion of the same kind overlapping it by ≥50% stays hidden.
  3. Manual cuts: drag on the waveform to select, `X` = cut. Trim-start/trim-end handles. Remove a cut with Delete.
  4. **App-side fallback flags** when Studio hasn't written suggestions: vocal-stem RMS above a threshold for ≥ 2 s where **no synced lyric line** covers it → "Possible speech". Leading/trailing full-mix RMS below −45 dBFS for ≥ 1.5 s → "Silence". Pure function, unit tested on synthetic signals.
  5. Render (C1) applies `cuts` with ~50 ms crossfades. Render file name gains a cuts hash (`…_c{hash8}_v2.wav`).
  6. `toOriginal()` maps through the cuts. Durations in Library/setlists use `playedDuration` (already includes cuts).
  7. Library filter **Needs trim review** = has suggestions that are neither accepted nor dismissed.
- Tests: the cut mapping both directions (`toOriginal` and lyric time → playback time) across 0, 1 and 3 cuts, the fallback detector on synthetic audio, crossfade = no sample jump > a threshold at the joins.

**Exit criteria**
- [ ] Accepting a flag shortens the played duration by exactly the cut length / tempo (unit test).
- [ ] Lyrics stay in sync after the cuts (mapping unit test + Ryan's ear test).
- [ ] Dismissed flags stay dismissed after Studio rewrites `cut_suggestions`.
- [ ] No click audible at cut points (Ryan's ear test). The sample-jump test passes.
- [ ] analyze / test / build green.

**Out of scope:** automatic cutting without review, music-structure detection (verse/chorus), fade-in/fade-out shaping beyond the fixed crossfade, editing the source audio.

**Owner field test (Ryan):** a song with spoken dialogue in the middle. Accept the flag, play across the cut in stage mode, and check the lyrics before and after it.

## Execution order and parallelism
| Phase | Runs | Where | Gate before next phase |
|---|---|---|---|
| 1 | **WP-A** and **WP-C1** in parallel | A in the main tree (`app/lib`, `app/test`); C1 in its own git worktree (`app/native`, `app/lib/render.dart`, `app/windows/CMakeLists.txt`, its own test file) | Coordinator runs `/code-review` + `/ponytail-review` on each and fixes findings, then commits locally |
| 2 | **WP-B** | main tree | same |
| 3 | **WP-C2** (merge C1 first) | main tree | same, plus Ryan's ear test |
| 2b | **WP-B2** | main tree | same |
| 4 | **WP-D0** spike → Ryan approves → **WP-D1** | spike in a worktree, build in the main tree | same, plus Ryan's HDMI test |
| 5 | **WP-E** (after the Studio `cut_suggestions` contract is agreed; the app-side fallback works without it) | main tree | same, plus Ryan's ear test |

File ownership during Phase 1, to avoid conflicts: WP-A may change `main.dart`, `library.dart`, `stage.dart`, `theme.dart`, new `setlist.dart`/`setlists_screen.dart`, and `app/test/`. C1 must **not** touch those files except adding its own new test file. It adds `render.dart` as a standalone file that nothing imports yet.

## After each phase (coordinator)
1. Review the diff (correctness + over-engineering), run analyze/test/build myself, and read the real output.
2. Update `SPEC.md`: the status pointer, any shape changes (setlist schema, render naming, field ownership), and move items out of "Pick up next session".
3. Commit locally with a clear message. **No push** unless Ryan says.
4. Report to Ryan: what works, what he needs to test, and what was deferred.
