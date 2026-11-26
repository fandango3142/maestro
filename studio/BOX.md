# Linux GPU box: runbook

What the box is, how it was set up, and the commands to run it.

The box serves more than one project: Maestro's sections are marked. Add any new command to the **Command log** at the bottom, with the date and why it was needed.

## The box

| | |
|---|---|
| Machine | Lenovo IdeaPad Gaming 3 (81Y4), Linux Mint 22.3 XFCE |
| GPU | GTX 1650, 4 GB (~3.6 GB usable), NVIDIA driver 595 |
| RAM / disk | 8 GB (7.6 usable) + 2 GB swapfile, 916 GB HDD (slow when swapping) |
| CPU | 8 threads |
| Address | `ryan@192.168.29.71` (home Wi-Fi), SSH key `karaoke-dev-laptop` from the dev laptop |
| Also running | Ollama, Docker, LocalSend (Flatpak) |

**Rules.** A project that has a live workload gets priority (today that's Maestro Studio). Cap every experiment's memory so it can't freeze the box:

```sh
systemd-run --user --scope -p MemoryMax=4.5G -p MemorySwapMax=1G <command>
```

Keep **MemoryMax + MemorySwapMax under about 5.5 GB** in total. Swap lands in zram first, and zram lives in physical RAM, so a big swap allowance still starves the box. Long jobs also need a watcher that kills them when `studio.py` starts, so Maestro keeps priority.

## Connect

```sh
ssh ryan@192.168.29.71                    # from the laptop (key auth, no password)
ssh -o BatchMode=yes -o ConnectTimeout=10 ryan@192.168.29.71 true && echo up   # is it up?
```

You can also copy files with LocalSend, which has access to `~/karaoke`.

## Everyday commands

| Want | Command |
|---|---|
| Health at a glance | `uptime; free -h; nvidia-smi` |
| GPU watch (load, VRAM, temp) | `watch -n 2 nvidia-smi` |
| CPU temperature | `sensors` (or `cat /sys/class/thermal/thermal_zone*/temp`, in m°C) |
| Disk / swap | `df -h /; swapon --show` |
| What's hogging memory | `ps aux --sort=-%mem \| head` |
| Kill a script by name | `pkill -f "[p]ython studio.py"` (the brackets stop it matching your own shell) |
| Shut down | `sudo -n systemctl poweroff` (passwordless via `/etc/sudoers.d/maestro-poweroff`) |
| Taskbar vanished | `xfce4-panel &` (on the box's own screen) |
| Desktop for one session (boots headless since 2026-11-26) | `sudo systemctl start lightdm`; back to desktop for good: `sudo systemctl set-default graphical.target` |

**Measured 2026-11-26** (clean fan, laptop upside down, 4-min song). CPU (i5-10300H) held at 93–95 °C throughout, and fell to about 72 °C within 30 s of the GPU going idle. GPU peaked at 87 °C. Separation took 448 s, the same as before (452 s), so nothing throttled. If it ever does, turning turbo off cuts CPU heat with little cost, because the work is GPU-bound: `echo 1 | sudo tee /sys/devices/system/cpu/intel_pstate/no_turbo` (`0` turns it back on; it resets at reboot).

**Safe temperatures.** GPU under load: up to about 80 °C is fine and 87 °C is its throttle point. CPU: under about 90 °C.

## Troubleshooting

- **SSH port open but no reply:** the box is out of RAM and swapping. Wait about 10 minutes; if it's still stuck, hold the power button. Services come back by themselves after a reboot.
- **Box dies when the lid closes:** check `/etc/systemd/logind.conf.d/karaoke-lid.conf` still exists.
- **SSH drops at random:** check that Wi-Fi power saving is still off (`/etc/NetworkManager/conf.d/wifi-powersave-off.conf`).
- **"dpkg frontend lock … pid":** another install or the update manager is running. Wait for it to finish. Don't delete the lock.
- **Install stuck at "Processing triggers for man-db":** this is normal and slow. Leave it.
- **`apt` prints Mint's "wrapper" message:** use `sudo apt-get …` instead.

## One-time setup (already done; repeat on a fresh install)

```sh
# Packages (apt-get, not Mint's apt wrapper)
sudo apt-get update
sudo apt-get install -y openssh-server ffmpeg git
sudo systemctl enable --now ssh

# Laptop's SSH key: on the laptop, append ~/.ssh/<key>.pub to the box's ~/.ssh/authorized_keys

# uv (Python manager); Python comes from uv, not the system
curl -LsSf https://astral.sh/uv/install.sh | sh

# User services keep running when nobody is logged in
sudo loginctl enable-linger ryan

# Lid on charger = ignore, Wi-Fi power saving off (was ~/Desktop/karaoke-fixes.sh, run with sudo sh)
sudo mkdir -p /etc/systemd/logind.conf.d
printf "[Login]\nHandleLidSwitchExternalPower=ignore\n" | sudo tee /etc/systemd/logind.conf.d/karaoke-lid.conf
sudo systemctl kill -s HUP systemd-logind
printf "[connection]\nwifi.powersave = 2\n" | sudo tee /etc/NetworkManager/conf.d/wifi-powersave-off.conf
sudo systemctl reload NetworkManager

# LocalSend as a user Flatpak, then give it ~/karaoke
flatpak install --user flathub org.localsend.localsend_app
flatpak override --user --filesystem=~/karaoke org.localsend.localsend_app
```

The screen-sleep and idle settings were set in XFCE's Power Manager (the box runs XFCE, not Cinnamon).

## Maestro Studio

**Layout:** code in `~/karaoke`, bare git remote in `~/karaoke.git` (branch `main`), and songs in `~/karaoke/inbox`, `inbox-backing` and `library`.

```sh
# Deploy (from the laptop, then on the box). Always pull after a push, or the box runs old code.
git push gtx master:main
ssh ryan@192.168.29.71 'cd ~/karaoke && git pull -q origin main'

# Services: a watcher fires when a file lands in an inbox; the service also runs once at boot
ln -sf ~/karaoke/studio/systemd/karaoke-studio.* ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now karaoke-studio.path
systemctl --user enable karaoke-studio.service

# Operate
tail -f ~/karaoke/studio.log                       # live progress
systemctl --user status karaoke-studio.path karaoke-studio.service
systemctl --user start karaoke-studio.service      # process the inbox now
journalctl --user -u karaoke-studio.service -b     # this boot's runs
```

The Windows laptop's "Maestro Sync" task (`studio/sync.ps1`) runs every 2 minutes. It sends new audio to the box and pulls back finished songs.

## Command log

| Date | Command / change | Why |
|---|---|---|
| 2026-11-26 | `systemd-run --user --scope -p MemoryMax=5G -p MemorySwapMax=1G` on all bench jobs | An AudioSR test used all 8 GB, the box swapped and froze, and it needed a power-cycle |
| 2026-11-26 | One-off exception approved by Ryan: ACE-Step at `MemoryMax=6G -p MemorySwapMax=0` (no swap, so it's killed rather than thrashing) | Gets killed after loading at 4.5G+1G; the 5.5 GB rule applies again afterwards |
| 2026-11-26 | Rule: total cap (MemoryMax + MemorySwapMax) at most about 5.5 GB; no AudioSR until the RAM upgrade | AudioSR at 6.5G + 2G of swap froze the box a second time, because zram swap takes physical RAM |
| 2026-11-26 | `systemctl --user disable --now openclaw-gateway` (undo: `enable --now`) | Stop OpenClaw to free RAM for benchmarks |
| 2026-11-26 | **Done 18:21** (verified: idle RAM about 1 GB, down from 2 GB; Studio's boot run worked headless): `sudo sh ~/music-bench/box-tune.sh`, then reboot. ntfy, which was a container, is also off. Boots headless (`multi-user.target`), stops Docker containers and sets them to `--restart=no` (old policies saved in `~/music-bench/docker-restart-policies.txt`), adds zram swap (half of RAM, zstd, priority 100), turns off Bluetooth. Undo lines are at the bottom of the script | Free RAM and stop the slow hard-drive swapping. Catch: headless means no LocalSend, and stopping Docker takes the port 7000 app offline |
| 2026-11-26 | `echo 'ryan ALL=(root) NOPASSWD: /usr/bin/systemctl poweroff' \| sudo tee /etc/sudoers.d/maestro-poweroff` | Shut the box down over SSH without a password (allows only that one command) |
| 2026-11-26 | Studio unloads Ollama models before each song (`keep_alive: 0` via its API) | Ollama and the separator share the 4 GB GPU; tested, freed 1.6 GB |
| 2026-11-26 | `run.sh` falls back to running without `systemd-inhibit` when polkit says "Access denied" | Nobody is logged in at the desktop after a boot, so inhibit was refused and Studio silently skipped its boot run |
