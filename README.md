# Maestro

A personal, offline, stage-ready karaoke app. *Maestro* (Italian, from Latin *magister*) means the one who runs the show.

- **Studio** (`studio/`, Python): drop a song into the inbox and a GPU box separates vocals (BS-RoFormer), optionally splits off the backing vocals, and detects key and BPM.
- **App** (`app/`, Flutter, Windows now, iPad later): song library, stage mode with synced lyrics and pedal controls, a manual lyric-sync editor, and key/tempo shifting (Signalsmith Stretch).
- Everything is self-hosted. Audio and model weights never go in git.

The design, decisions, status and roadmap are in [SPEC.md](SPEC.md), the living spec.
