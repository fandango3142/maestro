#!/bin/sh
# Process the inbox on the GPU box. Watch live from another terminal: tail -f ~/karaoke/studio.log
# systemd-inhibit: box can't sleep (idle or lid close) while songs are processing.
# Polkit denies it when nobody is logged in at the desktop (e.g. right after boot), so run without it
# then; lid-on-charger is already ignored by logind (karaoke-lid.conf).
cd "$(dirname "$0")"
export UV_PYTHON_PREFERENCE=only-managed PYTHONUNBUFFERED=1 PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True
INHIBIT="systemd-inhibit --what=sleep:idle:handle-lid-switch --why=karaoke-studio"
$INHIBIT true 2>/dev/null || INHIBIT=""
$INHIBIT ~/.local/bin/uv run studio.py 2>&1 | tee -a ../studio.log
