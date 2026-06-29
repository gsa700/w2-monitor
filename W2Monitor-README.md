# W2 Monitor — Connection Guide

A desktop monitor for one or more Elecraft **W2** wattmeters, with live frequency
pulled from a CAT‑capable radio bound to each sampler. Everything runs on its own
background thread, so the UI never blocks no matter how many meters and radios are
connected.

- **App:** `W2App.ps1` (launch with `Launch W2 Monitor.vbs`, or
  `powershell -ExecutionPolicy Bypass -File W2App.ps1`)
- **Config:** `W2Monitor.config.json` (auto‑saved)
- **TX log:** `W2_TXlog.csv`
- **rigctld launcher:** `Start-Rigctld-V71A.bat`

---

## 1. W2 wattmeter connection (per meter)

| Item | Value |
|---|---|
| Port on the W2 | Rear **PC DATA** jack (3.5 mm), true RS‑232 levels |
| Serial settings | **9600 baud, 8 data bits, no parity, 1 stop bit, no handshake** |
| Control lines | App asserts **DTR + RTS** |
| Cable | Elecraft **KXUSB** (USB) or **KXSER** (RS‑232) → shows up as an FTDI COM port |
| Example | KXUSB on **COM8** |

**Cable caveat (important):** generic "USB RS‑232 to 3.5 mm" cables are frequently
wired **reverse‑polarity** relative to Elecraft. The **DSD SH‑U35B** is true RS‑232
and electrically fine, but its tip/ring are **swapped** (cable Tip = RXD, Ring = TXD;
the W2 expects the opposite), so it will **not** work without re‑pinning the 3.5 mm
plug. Use the genuine KXUSB/KXSER, or swap tip↔ring inside the shell.

**Adding meters in the app:** Setup → **METERS** → pick a port in *Assign port* →
**Add**, or **Detect** (probes each free COM port with `V` and adds any that answer
like a W2). Each meter is its own COM port + worker; the main display auto‑focuses
whichever sampler is transmitting.

---

## 2. Radio connection (per sampler, for live frequency)

Bind a radio to a meter+sampler in Setup → **Radios…**. Three protocols:

| Protocol | Transport | Typical settings | Notes |
|---|---|---|---|
| **Kenwood TM‑D710 / V71A** | Serial COM | **57600 8N1**, DTR+RTS | Reads PTT band (`BC`) then that band's freq (`FO`). The V71A's PC‑port speed is set in its menu and must match. |
| **Kenwood TS‑2000 / Elecraft / SmartSDR CAT** | Serial COM | any baud, 8N1 | Polls `FA;`. Also covers Elecraft K‑line and Kenwood HF rigs. |
| **Hamlib rigctld (network)** | TCP `host:port` | default `127.0.0.1:4532` | rigctld owns the physical port and shares the rig with other apps; near‑universal radio support. See §3. |

**Example (current station):** Kenwood **TM‑V71A** on **COM7 @ 57600 8N1**, bound to
the W2's sampler **S1**, protocol **Kenwood TM‑D710 / V71A** (direct serial).

**FlexRadio:** in SmartSDR, create a **CAT serial port per slice**, then bind that
COM port with protocol **Kenwood TS‑2000 / SmartSDR CAT** (baud is ignored on a
virtual port). One CAT port per slice/antenna → bind each to its sampler.

The bound radio's frequency appears on the main **FREQUENCY** row (follows the active
sampler) and is latched into the TX log per over.

---

## 3. Hamlib rigctld (network / shared‑port option)

Use this when a single physical serial radio must be shared between apps (W2 Monitor
+ logger + WSJT‑X), or to support a rig we don't have a built‑in driver for. Windows
COM ports are **exclusive** — only one app can open a port — so `rigctld` opens it
once and serves the rig over TCP to everyone.

### Install
1. Download the Windows build of **Hamlib** (stable **4.6.4** or later):
   <https://github.com/Hamlib/Hamlib/releases> — get the `hamlib-w64-…` ZIP.
2. **Unzip anywhere** (e.g. `C:\hamlib\`). No installer. `rigctld.exe` / `rigctl.exe`
   are in the `bin\` folder.
3. You may already have it — many ham apps (WSJT‑X, JTDX, some loggers) bundle Hamlib.

### Find your radio's model number
```
rigctl.exe --list
```
Kenwood **TM‑V71A = 2035**.

### Launch rigctld (TM‑V71A example)
```
rigctld.exe -m 2035 -r COM7 -s 57600 -t 4532 --set-conf=dtr_state=ON,rts_state=ON
```
- `-m` model, `-r` physical COM port, `-s` baud, `-t` TCP port to serve on.
- **`--set-conf=dtr_state=ON,rts_state=ON` is required for the V71A** — its cable
  needs DTR and RTS asserted (same lines the direct driver raises). Without this,
  rigctld connects to the port but the radio never answers and frequency stays blank.
- If it still doesn't respond, **power‑cycle the radio** once — the V71A's PC port can
  latch into a bad state after being probed with the wrong line states.

Or just run **`Start-Rigctld-V71A.bat`** (edit the `HAMLIB_BIN` path at the top once).
Leave the rigctld window open; close it to release the rig.

### Bind it in the app
Setup → Radios… → set **Protocol = Hamlib rigctld (network)**. The Port field becomes
a network address and prefills **`127.0.0.1:4532`** (change if rigctld is on another
host/port — that's also how you'd reach a **remote** rig). Add / Update.

### Verify rigctld independently
In a second terminal (talks to the running daemon over TCP, just like the app):
```
rigctl.exe -m 2 -r 127.0.0.1:4532
```
At `Rig command:` type **`f`** — a frequency means rigctld is good; an `RPRT -…`
error means it's the rig side (DTR/RTS or baud).

---

## 4. Config & data files (in the app folder)

| File | Contents |
|---|---|
| `W2Monitor.config.json` | Window position/size, UI scale, display toggles, TX timeout, logging on/off, **meters** (id/name/port), **radios** (meterId/sampler/port/baud/protocol), log‑window geometry. Auto‑saved. |
| `W2_TXlog.csv` | One row per transmission: `Timestamp, Meter, Freq_MHz, Duration_s, PeakFwd_W, MaxSWR, MinReturnLoss_dB, Sensor, Range, SensorType, TimedOut`. Capped at 2000 rows (oldest trimmed). If the header schema changes, the old file is auto‑archived with a timestamped name. |

---

## 5. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| "Could not connect / access denied" on a W2 port | Another app owns it (e.g. the old W2 Utility). Close it — one app per COM port. |
| W2 cable shows a COM port but no data | Wrong cable polarity (see §1). Use KXUSB/KXSER or swap tip↔ring. Confirm it's a true **RS‑232** cable, not USB‑TTL. |
| Flickery / dropping COM port | Reseat into a **rear** USB port (not a hub/front panel). |
| rigctld: radio seen but no frequency | Add `--set-conf=dtr_state=ON,rts_state=ON`; power‑cycle the radio. Verify with `rigctl -m 2 -r 127.0.0.1:4532` then `f`. |
| Direct serial radio: no frequency | Check baud matches the radio's PC‑port menu setting; the V71A needs DTR+RTS (the driver asserts them). |
| Want a single rig shared by multiple apps | Run it under rigctld (§3) and point every app at `host:port`. |

---

## 6. Packaging & sharing

This folder is self‑contained — **zip it and share**. The launcher and the rigctld
`.bat` use relative paths, so it runs from anywhere after unzipping. Recipients run
**`Create Desktop Shortcut.vbs`** once to put a *W2 Monitor* shortcut on their desktop.

**Before zipping to share,** delete your personal files so the recipient starts clean:
`W2Monitor.config.json` (window positions + your COM/meter/radio bindings) and any
`W2_TXlog*.csv` (your on‑air log).

---

*Station reference: FlexRadio + Elecraft W2 (VHF/UHF samplers, 144–450 MHz) +
Kenwood TM‑V71A. W2 serial = 9600 8N1 on the PC DATA jack; V71A CAT = 57600 8N1 with
DTR+RTS, Hamlib model 2035.*
