# OctoPrint on Raspberry Pi — Two Creality Printers

A Docker Compose stack that runs **two independent OctoPrint instances** on a single Raspberry Pi, one for each of your printers:

| Service | Host port | Printer |
|---------|-----------|---------|
| `octoprint-cr6se` | `5000` | Creality CR-6 SE |
| `octoprint-e3pro` | `5001` | Creality Ender 3 Pro (direct drive) |

Each instance gets its own config directory, its own serial device and its own port, so a hang, a failed firmware flash or a wedged print on one printer cannot affect the other. There is no shared state and no multi-printer plugin involved — deliberately, because that is the arrangement that still works at 2am when something has gone wrong.

```text
                  ┌──────────────────────────────┐
  USB (powered    │  Raspberry Pi (this repo)    │
  hub, one port   │                              │
  per printer) ───┤  octoprint-cr6se  :5000 ──►  /dev/octoprint-cr6se ──► CR-6 SE
                  │  octoprint-e3pro  :5001 ──►  /dev/octoprint-e3pro ──► Ender 3 Pro
                  └──────────────────────────────┘
```

---

## Table of Contents

- [Hardware requirements](#hardware-requirements)
- [Quick start](#quick-start)
- [Step 1: Wire the printers](#step-1-wire-the-printers)
- [Step 2: Give each printer a stable device name](#step-2-give-each-printer-a-stable-device-name)
- [Step 3: Configure and start](#step-3-configure-and-start)
- [Step 4: First-run setup in OctoPrint](#step-4-first-run-setup-in-octoprint)
- [Direct drive notes (Ender 3 Pro)](#direct-drive-notes-ender-3-pro)
- [Marlin notes](#marlin-notes)
- [Optional: camera](#optional-camera)
- [Recommended plugins](#recommended-plugins)
- [Storage: uploads and timelapse](#storage-uploads-and-timelapse)
- [Backups](#backups)
- [Updating](#updating)
- [Troubleshooting](#troubleshooting)
- [Converting to Klipper](#converting-to-klipper)

---

## Hardware requirements

- **Raspberry Pi** (3B+/4/5). OctoPrint is light; even a Pi 3 handles two printers comfortably.
- **Powered USB hub.** Two printers on one Pi's USB ports is workable but tight — the Pi can brown out or drop devices when a stepper kicks in. Use a hub with its **own** power adapter. This is the single most common cause of "serial connection keeps dropping".
- **Separate power supplies for each printer.** Never power a printer's bed heater or motors from the Pi or the hub. Each printer keeps its own PSU; the hub only carries USB data.
- **USB *data* cables.** Charge-only cables are common and look identical to data cables. Test with `lsusb` before debugging anything else.
- **Plug into the mainboard**, not the CR Touch screen. The touchscreen has its own USB connection and is not a printer serial port.

Both printers expose a USB-serial port on the mainboard already, so no wiring, board mods or firmware changes are needed to get started.

---

## Quick start

```bash
git clone git@github.com:adm7373/OctoPrintCompose.git
cd OctoPrintCompose

cp .env.example .env          # then fill in the serial devices
sudo ./scripts/find-printers.sh
# ... install udev rules, edit udev/99-octoprint-serial.rules, activate ...
docker compose up -d
```

Then open `http://<pi-ip>:5000` and `http://<pi-ip>:5001`.

---

## Step 1: Wire the printers

1. Power both printers on **first** — the Pi only enumerates USB devices that are powered.
2. Plug each printer into a **different port** on the powered hub. Which port does not matter, but keep each printer on the port you choose, because the udev rules in step 2 identify printers by USB port path.
3. Connect the Pi's network (wired Ethernet strongly preferred; a long print over a weak Wi-Fi link is its own problem).
4. Confirm the Pi sees two serial devices:

```bash
lsusb
ls -l /dev/ttyUSB* /dev/ttyACM* 2>/dev/null
```

You want **two** devices. One means a charge-only cable, a dead cable, or a printer that isn't powered.

---

## Step 2: Give each printer a stable device name

This step is the important one, and the reason is specific to your hardware.

The CR-6 SE and the Ender 3 Pro use the **same USB-serial chip** (CH340, `1a86:7523`). Two consequences:

- `/dev/ttyUSB0` vs `/dev/ttyUSB1` reflects **plug order**, not which printer it is. Reboot one printer and they can swap.
- `/dev/serial/by-id/...` paths can **collide or change** for identical chips, and change if you move a cable to another port.

Neither path is safe to hardcode. Instead, pin each printer to a **USB port** and give it a stable name with udev.

### 2a. Discover the port paths

```bash
sudo ./scripts/find-printers.sh
```

It prints, per connected printer, the device, its `by-id` path, its **USB port path** (e.g. `1-1.2`) and its `vid:pid`. Note the USB port path for each printer — you need one line per printer.

> The script is read-only. It never writes to `/dev` or `/etc`.

### 2b. Fill in the udev rules

```bash
sudo ./scripts/find-printers.sh --print-udev
```

Edit `udev/99-octoprint-serial.rules`, replacing `CR6SE_USB_PORT` and `E3PRO_USB_PORT` with the port paths from step 2a:

```text
SUBSYSTEM=="tty", ATTRS{idVendor}=="1a86", ATTRS{idProduct}=="7523", KERNELS=="1-1.2", SYMLINK+="octoprint-cr6se", MODE="0660", GROUP="dialout"
SUBSYSTEM=="tty", ATTRS{idVendor}=="1a86", ATTRS{idProduct}=="7523", KERNELS=="1-1.4", SYMLINK+="octoprint-e3pro", MODE="0660", GROUP="dialout"
```

If a board reports the newer **CH9102** chip (`1a86:55d4`) instead of CH340, duplicate its rule with those two attribute values — `find-printers.sh` prints the `vid:pid` it actually sees.

### 2c. Install and verify

```bash
sudo cp udev/99-octoprint-serial.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules && sudo udevadm trigger

ls -l /dev/octoprint-cr6se /dev/octoprint-e3pro
```

Both symlinks should appear. To prove they point at different physical devices, unplug one printer and re-run `ls -l` — the remaining symlink should be unchanged.

---
## Step 3: Configure and start

```bash
nano .env
```

The two serial device values must match your udev symlink names:

```bash
TZ=America/New_York
CR6SE_SERIAL_DEVICE=/dev/octoprint-cr6se
ENDER3PRO_SERIAL_DEVICE=/dev/octoprint-e3pro
```

Then:

```bash
docker compose up -d
docker compose ps
docker compose logs -f octoprint-cr6se
```

OctoPrint listens on port 80 *inside* each container; the host ports `5000`/`5001` map onto that.

---

## Step 4: First-run setup in OctoPrint

Do this **separately for each instance** — they are independent applications with independent users.

1. Open `http://<pi-ip>:5000` (CR-6 SE) or `http://<pi-ip>:5001` (Ender 3 Pro) and create the admin user.
2. **Serial port** — pick the port from `.env` (`/dev/octoprint-cr6se` or `/dev/octoprint-e3pro`). Leave baud rate at `115200` (Creality's default), then *Connect*.
3. **Printer profile** — use *Import from Firmware* if your version offers it, otherwise enter the values below by hand. These are the stock Creality values; **verify against your own firmware** (`Configuration.h`) if you have ever reflashed.

   | Setting | CR-6 SE | Ender 3 Pro |
   |---------|---------|--------------|
   | Build volume (X/Y/Z) | 300 x 300 x 300 mm | 220 x 220 x 250 mm |
   | Origin | Front left | Front left |
   | Bed centre offsets | 150 / 150 | 110 / 110 |
   | Steps per mm X / Y | 80 / 80 | 80 / 80 |
   | Steps per mm Z | 400 | 400 |
   | Max hotend temp | 260 C | 240 C |
   | Max bed temp | 80 C | 100 C |
   | Probe | CR Touch | CR Touch |

4. **Start/End G-code** — leave these **empty**. See [Marlin notes](#marlin-notes).
5. Finish the wizard, then do a real test: home all axes, then print something small.

### Confirming the printers are not swapped

After connecting both instances, jog the Y axis on each from its own web UI and watch the actual printer. If they move the wrong one, your udev rules have the port paths swapped — fix `udev/99-octoprint-serial.rules` and re-run `docker compose up -d`. **Check this before starting a print**; jogging the wrong axis on a 300 mm CR-6 SE will crash the gantry.

---
## Direct drive notes (Ender 3 Pro)

The Ender 3 Pro's extruder pushes filament straight into the hotend, so it needs far less retraction than a Bowden setup:

| | Bowden (typical) | Direct drive (use this) |
|---|---|---|
| Retraction length | 4-5 mm | **1.5 mm** |
| Retraction speed | 25-30 mm/s | **40 mm/s** |

Set these in the slicer (OrcaSlicer / PrusaSlicer / Cura), **not** in OctoPrint. Start at 1.5 mm / 40 mm/s and tune from there — too much retraction grinds filament at the gear, too little causes stringing.

The CR-6 SE is also direct drive, so the same numbers apply to it.

---

## Marlin notes

Both printers ship with Creality's Marlin firmware, and that shapes four things:

- **No `START_PRINT` macro.** Marlin has no macro OctoPrint could call, so the profile's *Start G-code* and *End G-code* must stay **empty**. Pasting slicer "start print" scripts there does nothing, and a profile copied from Klipper will silently misbehave.
- **Retraction lives in the firmware.** If your Marlin build sets a firmware retraction (`DEFAULT_RETRACTION`), it overrides the slicer's value. Set retraction in the slicer and leave firmware retraction at `0` unless you chose otherwise.
- **The CR Touch keeps working.** The touchscreen is wired to the mainboard and Marlin handles it. OctoPrint does not take it over — you can keep using the screen while OctoPrint runs.
- **Flashing firmware.** OctoPrint's built-in flasher can update the Creality bootloader, but for Marlin builds it is usually cleaner to flash from a USB stick on the printer. If you flash, re-check the profile table afterwards.

---

## Optional: camera

If you attach a **USB webcam** to the Pi:

1. Set `ENABLE_MJPG_STREAMER=true` in `.env`.
2. Uncomment the `/dev/video0:/dev/video0` device mapping for that instance in `docker-compose.yml`.
3. In OctoPrint: *Settings -> Webcam & Timelapse*. The image bundles ffmpeg; keep the detected paths.

> The Raspberry Pi Camera Module is **not** supported by this image's mjpg-streamer path — it expects a V4L2 device. Use a USB webcam, or build a custom image with camera support if you want the Pi module.

---

## Recommended plugins

Install from OctoPrint's *Settings -> Plugin Manager*. None are required; these are the ones that earn their keep:

- **OctoPrint-Progress** — ETA, remaining time and filament estimate during long prints.
- **OctoPrint-BedLevelVisualizer** — mesh maps; very useful when dialling in a CR Touch on the Ender 3 Pro.
- **OctoPrint-GCodeViewer** — inspect a file before committing hours of print time to it.
- **OctoPrint-PrintHistory** — durable print history with thumbnails.
- **OctoPrint-UltimateSensorForUPS** — power-loss protection, *only* meaningful with a UPS HAT. Cheap insurance against a print dying at 3am on a brownout.
- **Apprise** / OctoPrint-Notifications — push or email alerts for finished and failed prints.

---

## Storage: uploads and timelapse

OctoPrint stores uploaded files, thumbnails and timelapse videos under `data/<instance>/uploads`. Video is what fills an SD card: a few dozen timelapse captures can reach tens of gigabytes.

Keep them off the SD card by pointing `UPLOADS_PATH` in `.env` at a drive with room and uncommenting the matching volume in each service:

```bash
UPLOADS_PATH=/mnt/storage/octoprint
```

```yaml
    volumes:
      - ./data/cr6se:/octoprint
      - ${UPLOADS_PATH}/cr6se:/octoprint/uploads
```

Create the directories first, or Docker creates them as root:

```bash
mkdir -p /mnt/storage/octoprint/{cr6se,e3pro}
```

---

## Backups

OctoPrint's own backup (*Settings -> Backup*) is the right tool for restoring one instance. For a host-side snapshot of both:

```bash
./scripts/backup.sh                      # -> backups/octoprint-<timestamp>.tar.gz
./scripts/backup.sh --include-uploads    # include timelapse (large)
./scripts/backup.sh --dest /mnt/storage/backups
```

It archives both `data/` directories, skips `uploads/` by default, and prunes to the 10 most recent archives so it is safe to run from cron:

```cron
0 4 * * * /home/<user>/OctoPrintCompose/scripts/backup.sh --dest /mnt/storage/backups >/dev/null
```

---

## Updating

```bash
cd ~/OctoPrintCompose
git pull
docker compose pull
docker compose up -d
```

OctoPrint is configured to restart itself inside the container, and your config lives in the mounted `data/` directories, so pulling a new image does not lose settings. Take a backup first anyway — a new OctoPrint major version can migrate the config.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Only one printer visible in `find-printers.sh` | Charge-only USB cable, or printer not powered | Try a known data cable; power the printer on |
| OctoPrint cannot open the serial port | Wrong device path in `.env`, or udev rule not loaded | `ls -l /dev/octoprint-*`; re-run `udevadm trigger` |
| Serial port disconnects mid-print | Insufficient USB power | Use a **powered** hub |
| Axes move on the wrong printer | udev port paths swapped | Swap the two `KERNELS` values, then `docker compose up -d` |
| Printer homes but ignores print commands | Start G-code pasted into the profile | Clear *Start G-code* and *End G-code* — Marlin has no macros |
| Bed levelling drifts | CR Touch not configured in Marlin | Mesh settings live in the printer's firmware; verify `PROBING`/mesh config |
| Timelapse fills the SD card | Videos in the default location | Point `UPLOADS_PATH` at a larger drive |
| `docker compose up` fails on a device path | `.env` still has placeholder values | Run `find-printers.sh` and use the real symlinks |

More:

```bash
docker compose logs --tail 100 octoprint-cr6se    # instance logs
dmesg | tail -30                                   # USB disconnects and resets
lsusb -t                                           # confirm each printer's port path
```

---

## Converting to Klipper

Both printers can run Klipper instead of Marlin, which gives faster slicing, better probing and input shaping. The trade-off: OctoPrint becomes an optional front-end (or you run Moonraker/Fluidd directly), and Klipper *does* have `START_PRINT` macros, so you would then need to add start/end G-code to the OctoPrint profile — the opposite of the current rule above.

Nothing in this repo prevents that; the compose stack is unaffected by which firmware is on the board. Do it one printer at a time so you always keep a known-good machine.


