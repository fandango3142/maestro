#!/bin/sh
# Process the inbox on the GPU box. Watch live from another terminal: tail -f ~/karaoke/studio.log
# systemd-inhibit: box can't sleep (idle or lid close) while songs are processing.
cd "$(dirname "$0")"
export UV_PYTHON_PREFERENCE=only-managed PYTHONUNBUFFERED=1 PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True
systemd-inhibit --what=sleep:idle:handle-lid-switch --why="karaoke studio" \
  ~/.local/bin/uv run studio.py 2>&1 | tee -a ../studio.log
