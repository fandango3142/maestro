# WP-D0 spike report: two-screen presenter mode

Date: 2026-11-26 · Branch `spike-d0` (worktree `Karaoke-d0`) · Flutter 3.44.1 stable, Dart 3.12.1, Windows 11
Prototype: `spike/d0_proto/` (throwaway, not for merge). Raw results: `spike/d0_proto/results/run{1,2,3}_release.json`, `run1_mem.csv`.

## Bottom line

**Recommendation: use `desktop_multi_window` 0.3.1 for a separate lyrics window, plus `screen_retriever` 0.2.2 (already in the app as a hidden dependency) to find display 2.** It worked on this Flutter version first time. Messages between the windows are fast: under 1 ms, about 0.2 ms typical. The lyrics window draws each position update within about one screen refresh. Audio kept perfect time while the second window was open, closed and reopened. The cost is about 40–60 MB more memory while the lyrics window is open.

Flutter's own built-in multi-window support is **not** usable: on stable it's switched off and needs the master channel plus a flag.

The one-big-window-across-both-screens idea is not recommended (reasons below).

Everything was tested on the laptop's single screen. The real HDMI test (list at the end) is still needed.

## Q1: native second window in Flutter 3.44.1 stable? **No.**

Evidence:
- The SDK has the API (`C:\flutter\packages\flutter\lib\src\widgets\_window.dart`, `RegularWindowController`, plus `_window_win32.dart`), but every class is `@internal` and throws unless `isWindowingEnabled`, which is `debugEnabledFeatureFlags.contains('windowing')` (`foundation/_features.dart`).
- The flag is defined in `packages/flutter_tools/lib/src/features.dart` as `windowingFeature` (`enable-windowing`), with only `master: FeatureChannelSetting(available: true)`, so it is **not available on stable**.
- I tried it: the prototype compiles when it imports the private file, but at runtime `RegularWindowController(...)` throws `UnsupportedError: Windowing APIs are not enabled. Windowing APIs are currently experimental...` (recorded in `q1_native` in every run).
- I did not run `flutter config --enable-windowing`, because it changes the global Flutter config that the main tree also uses. The tool source shows it is master-only anyway.

## Q2: desktop_multi_window + screen_retriever: **works**

Versions: `desktop_multi_window 0.3.1` (latest, needs Flutter >= 3.0). `screen_retriever 0.2.2` is already in the app's `pubspec.lock` as a transitive dependency of `window_manager 0.5.2`. The latest `screen_retriever` (0.4.1) and `window_manager` (0.7.1) need Flutter >= 3.50, so they can't be used on this SDK.

Setup it needs (done in the prototype):
1. In `windows/runner/flutter_window.cpp`, register plugins for each new window (`DesktopMultiWindowSetWindowCreatedCallback(... RegisterPlugins(...))`, 4 lines). Without this, `window_manager` doesn't work inside the lyrics window.
2. In `main()`, call `WindowController.fromCurrentEngine()` and run the lyrics app when `arguments == 'lyrics'`.
3. In 0.3.x the package only creates, shows and hides windows. Moving, borderless, fullscreen and close come from `window_manager` running **inside** the lyrics window, driven by messages from the presenter. The package README suggests a forked `window_manager`, but every call I used worked with the pub release 0.5.2.

Results (all from release builds, 3 runs, same results each time):

| Check | Result |
|---|---|
| Create the second window | OK. Ready to receive messages 121–130 ms after `create()` |
| Move/resize to given bounds (100,100, 640×360) | OK. `getBounds` reads back exactly `[100,100,640,360]` |
| Borderless + cover the whole display | OK. `[0,0,1536,960]` logical = 1920×1200 physical (laptop at 125%) |
| `setFullScreen(true)` from a normal framed window | OK. Covers the monitor exactly (1920×1200 physical). `isFullScreen = true` |
| `setFullScreen(false)` | OK. Goes back to exactly `[100,100,640,360]` |
| Close cleanly | OK. Window count goes 2 → 1, the lyrics channel reports `CHANNEL_UNREGISTERED`, the presenter carries on |
| Reopen after closing (the unplug/replug path) | OK. A new window comes up and answers messages |
| Keyboard focus | Showing the lyrics window **took focus away** from the presenter (`isFocused = false`). One `windowManager.focus()` call on the presenter brought it back (`true`). D1 must do this, or pedal presses go to the lyrics window |
| Display detection | One display reported: `\\.\DISPLAY1`, 1536×960 logical, scale 1.25. It has a `display-added` / `display-removed` event (from `WM_DISPLAYCHANGE`) for unplug handling. Not tested here (it needs a real second screen) |

**Mixed-DPI finding (important for D1):** `screen_retriever` turns each monitor's position into logical pixels using *that monitor's* scale, while `window_manager.setBounds` converts back using the scale of the monitor the window is *currently on*. With a 125% laptop and a 100% TV, `setBounds` would put the window in the wrong place. The safe recipe, verified on one screen: put a normal (framed) window anywhere on display 2, then call `setFullScreen(true)`. That uses `MonitorFromWindow` and the monitor's real pixel rectangle, so scaling doesn't matter. Don't call `setAsFrameless()` first: in `window_manager` 0.5.2, `setFullScreen` does nothing to the size if the window is already frameless (seen in the source).

## Q3: state sharing latency: **far below one frame**

Method: the presenter sent `{seq, position}` 20 times a second for 30 s (600 messages), without waiting for replies (as the real app would). Timestamps came from `Timeline.now`, a monotonic clock shared by both engines because they run in the same process. Round-trip time was cross-checked with a separate `Stopwatch` in the presenter. "Rendered" is when the lyrics window finished building the frame that shows that message (post-frame callback). The screen is 60 Hz (16.7 ms per frame).

| Metric (ms) | Run 1 | Run 2 | Run 3 |
|---|---|---|---|
| One-way, median / p95 | 0.16 / 0.32 | 0.22 / 0.39 | 0.20 / 0.40 |
| Round trip, median / p95 | 0.29 / 0.50 | 0.35 / 0.61 | 0.35 / 0.65 |
| Send → lyrics frame built, median / p95 | 8.6 / 12.7 | 15.9 / 18.4 | 7.7 / 18.0 |
| Lost / errors | 0 / 0 of 600 | 0 / 0 | 0 / 0 |

Reading it: the message itself costs about 0.2 ms. The rest is waiting for the lyrics window's next screen refresh, which every Flutter screen does anyway. Worst case is about 19 ms (about one frame). Today's stage screen already polls the audio position every 50 ms, so that polling, not the window link, is the bigger delay. Building the frame is not the same as the light leaving the screen: add one more refresh (about 17 ms) for the GPU and Windows to show it, the same as today. **The lyrics window is within about one frame of the audio.**

## Q4: audio and memory

**Audio (audioplayers 6.8.1)** kept playing in the presenter the whole time. During the 30 s message test, the player's position moved forward by exactly the wall-clock time. For example, in run 1 it went from 11,401 → 11,953 ms over 30,553 ms of wall clock on a 30 s looping sine: 11,401 + 30,553 − 30,000 = 11,954, so it was 1 ms off. It also stayed in step after the lyrics window closed and after it was reopened. State was `playing` throughout.

**Memory** (process working set; both windows live in one process):

| | Run 1 | Run 2 | Run 3 |
|---|---|---|---|
| Presenter only, audio playing | 130 MB | 111 MB | 111 MB |
| + lyrics window open (fullscreen 1920×1200) | 189 MB (+59) | 152 MB (+41) | 153 MB (+42) |
| After the 30 s message test | 178 MB | 156 MB | 156 MB |
| After closing the lyrics window | 168 MB | 144 MB | 146 MB |

So a second engine costs **about 40–60 MB** while it's open, and some of that (about 30 MB) isn't handed back after closing. The laptop has 23 GB of RAM, so this is not a concern. Outside samples (`run1_mem.csv`) agree: private memory 106 → 193 MB, with 60 → 64 threads.

## The cheap alternative: one borderless window across both screens

The idea: one Flutter window stretched over the laptop and the TV, presenter on one half, lyrics on the other. It needs no new package, has no messages between windows, and runs one engine. Problems:
- **One scale for both halves.** Windows gives a window a single DPI (from the monitor holding most of it), and Flutter draws the whole window at that scale. With a 125% laptop and a 100% TV, one half is drawn at the wrong size. Text on the TV would come out 25% bigger or smaller than planned, and when the window's "home" monitor changes, everything rescales.
- **Different resolutions and layout.** The window must be the bounding box of both screens. If the screens are different heights (1920×1200 laptop vs 1920×1080 TV) or aren't side by side in Windows Display Settings, part of the window is off-screen, and the split point has to be worked out from physical monitor rectangles. That runs into the same mixed-DPI conversion bug as `setBounds` above. `setFullScreen` only covers one monitor, so it can't help here.
- **It breaks Windows' normal behaviour.** Unplugging HDMI makes Windows squash or move the window, so the app must rebuild its layout mid-song. It also covers the taskbar on both screens, and "Duplicate" display mode shows the presenter half to the audience.
- It saves about 40–60 MB and the 4-line runner change, and nothing else. The message cost it avoids is already well under 1 ms.

Verdict: about as much effort to make reliable, and more fragile on stage. Not recommended.

## Risks

1. **Focus stealing:** the lyrics window takes keyboard focus when shown. Fix: refocus the presenter right after (verified). Also check after unplug/replug.
2. **Mixed DPI:** use "move onto display 2, then `setFullScreen(true)`", never `setBounds` across monitors. This needs the real HDMI test.
3. **Same process:** a Dart error in the lyrics window is isolated (separate engine), but a *native* crash there would take down the whole app, audio included. In practice this risk is low (it only renders text), but the SPEC line "if the lyrics window dies, music keeps playing" holds only for Dart-level failures.
4. **Package maturity:** `desktop_multi_window` 0.3.x is a rewrite from Aug 2026 with a small API, and its README suggests a forked `window_manager`. Mitigation: keep all multi-window code in one small file (`lyrics_window.dart`) behind a simple "open / send state / close" interface, so it can be swapped for Flutter's native windowing once that reaches stable.
5. **Version ceiling:** newer `window_manager` and `screen_retriever` need Flutter 3.50. When Flutter is upgraded, re-test this.
6. **Runner change:** D1 must edit `app/windows/runner/flutter_window.cpp` (outside `app/lib`), so the coordinator should allow that file.
7. Not tested: taskbar/Alt-Tab entry for the lyrics window (`setSkipTaskbar` probably fixes it), and display-change events.

## What Ryan must test with a real HDMI display

1. Plug the TV in (Windows set to **Extend**, not Duplicate). Start stage mode. Lyrics should be fullscreen on the TV with no border, title bar or taskbar showing, and the presenter on the laptop.
2. Do it twice: once with the TV at 100% scale and once at a different scale from the laptop (laptop is at 125%). Check that the lyrics fill the TV exactly, with no gap and nothing spilling onto the laptop.
3. Press the pedal straight after the lyrics appear. Play/pause must work without clicking anything first (the focus check).
4. Pull the HDMI cable mid-song. Music must keep playing, and the laptop should switch to the one-screen layout.
5. Plug it back in. The lyrics should come back on the TV (or at least nothing should crash).
6. Watch the TV during a fast lyric line: the highlight should change in time with the singing, with no visible lag compared with today's one-screen mode.
7. Optional: TV on the left of the laptop in Display Settings (negative coordinates), and a 4K TV.

## D1 effort (estimate, not measured)

About **3–4.5 working days** of agent time:
- Window plumbing: deps, runner patch, entry point, open/fullscreen on display 2, focus, unplug/replug fallback, and the state message with encode/decode tests: **about 1–1.5 days**.
- Presenter screen per the wireframe (song/set bars, queue, gig note, ahead/behind maths + tests, buttons), fade-out, wakelock: **about 1.5–2 days**.
- Fixes after Ryan's HDMI test: **about 0.5–1 day**.

## Prototype notes

- `spike/d0_proto/lib/main.dart` runs the whole script automatically and writes JSON to `$D0_OUT`. Run it with `flutter build windows --release`, then start `build\windows\x64\runner\Release\d0_proto.exe`.
- `spike/d0_proto/windows/runner/flutter_window.cpp` has the plugin-registration patch D1 will need.
- Audio is a synthetic 440 Hz sine generated at runtime (no copyrighted material).
