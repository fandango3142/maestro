#!/bin/sh
# Process the inbox on the GPU box. Watch live from another terminal: tail -f ~/karaoke/studio.log
cd "$(dirname "$0")"
export UV_PYTHON_PREFERENCE=only-managed PYTHONUNBUFFERED=1
~/.local/bin/uv run studio.py 2>&1 | tee -a ../studio.log
