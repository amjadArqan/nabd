# Nabd · نبض

A small macOS menu bar app that shows your Mac's temperature, CPU, memory and power draw, and keeps
heavy [Claude Code](https://claude.com/claude-code) sessions from saturating the machine.

تطبيق صغير لشريط القوائم في الماك: يعرض الحرارة والمعالج والذاكرة واستهلاك الكهرباء، ويمنع جلسات
Claude Code الثقيلة من إشباع الجهاز.

## What it shows

- **Temperature**: CPU core average and hottest core, GPU, SSD, battery, fan speed (read from the SMC, no `sudo`).
- **CPU**: total, performance vs. efficiency cores, load average.
- **Memory**: used, compressed, swap, memory pressure.
- **Power**: watts drawn from the wall right now, split into what the Mac uses, battery charging and charger loss;
  the charger's rating, the peak since launch and the energy used today. On battery: draw and time left.
- **Claude Code sessions**: each session by project folder, its CPU and memory, its MCP servers and its heaviest child process.
- **Top consumers**: by CPU, by memory, and background dev services (php, node, mysqld, nginx, redis, VMs…).
- **Advice**: plain-language hints (fans at max, swap too high, idle sessions, orphaned MCP servers, a charger too weak…).

The interface is in Arabic (right-to-left).

## The guard

When the whole machine stays at or above a CPU limit (90% by default; 80/95% or off from the panel) for about
12 seconds, Nabd **pauses the heaviest Claude Code session**: it stops the busy processes that session's Bash
commands started (tests, static analysis, builds). The `claude` process itself and its MCP servers are never touched,
so the agent stays responsive.

- An alert with a **Force continue** button appears, with a sound.
- The session continues by itself once CPU is below the limit minus 15 points for ~9 s (at least 30 s after the pause,
  at most 5 minutes, so sessions take turns), or at once on a forced continue — then it is exempt for 15 minutes.
- Any session can be paused or continued by hand from the panel.
- Quitting Nabd resumes everything; if Nabd crashes, it resumes what it had stopped on its next launch.

A paused session is not told it is paused: its command simply waits. A command frozen longer than Claude Code's
command timeout is killed and the agent sees a timeout. Time-sensitive tests may fail after a pause.

## Requirements

- macOS 13 or later. Built and tested on an Apple Silicon Mac (M1 Pro); Intel Macs should work but are untested.
- Xcode or the Command Line Tools (`xcode-select --install`) to build.

## Build and install

```bash
git clone https://github.com/amjadArqan/nabd.git
cd nabd
./build.sh
cp -R Nabd.app /Applications/
open /Applications/Nabd.app
```

Nabd has no window and no Dock icon: look for the pulse icon and readings in the menu bar. Tick
**تشغيل مع الجهاز** (start with the Mac) at the bottom of the panel, or run `nabd login on`.

The app is ad-hoc signed by `build.sh`, so macOS does not allow it to post system notifications; the guard uses its
own alert window instead.

## Command line

The same binary works in the terminal (`/Applications/Nabd.app/Contents/MacOS/Nabd`, or `./nabd` after building):

| Command | What it does |
|---|---|
| `nabd status` | Full report |
| `nabd doctor` | Advice only |
| `nabd line` | One line, e.g. `58°  CPU 40%  RAM 83%  43W` |
| `nabd json` | Everything as JSON |
| `nabd sensors` | Raw temperature sensors and fans |
| `nabd guard [limit]` | What the guard sees right now (dry run) |
| `nabd continue` | Force-continue every paused session |
| `nabd log` | What the guard paused or continued lately, and why |
| `nabd login [on\|off]` | Start with the Mac |
| `nabd calm` / `uncalm <pid\|name>` | Move a process tree to background priority (efficiency cores) and back |

## How it reads the hardware

- Temperatures and fans come from the SMC through IOKit; sensor keys are discovered at launch, so they adapt to the chip.
  Battery and SSD temperatures come from the HID sensor service, loaded with `dlsym` (private API).
- Power comes from the `AppleSmartBattery` registry entry (`PowerTelemetryData`, `AdapterDetails`).
- Processes come from `ps` and libproc. Nabd only signals your own processes.

## Uninstall

```bash
/Applications/Nabd.app/Contents/MacOS/Nabd login off
rm -rf /Applications/Nabd.app
defaults delete local.nabd.monitor
```
