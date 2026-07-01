# W2 Monitor — Connection Guide

A desktop monitor for one or more Elecraft **W2** wattmeters. Each meter runs on its
own background thread, so the UI never blocks no matter how many are connected.

- **App:** `W2App.ps1` (launch with `Launch W2 Monitor.vbs`, or
  `powershell -ExecutionPolicy Bypass -File W2App.ps1`)
- **Config:** `W2Monitor.config.json` (auto‑saved next to the app)

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
whichever meter is transmitting.

---

## 2. Two samplers on one W2 — use Search mode

A single W2 has two sampler inputs (S1, S2), but it **reads only one at a time**. To
cover two antennas with one meter, put the W2 in **Sensor Search** mode: press
**Search** in the app's *W2 Controls* (or press‑and‑hold the front‑panel **SENSOR**
button). The W2 then hunts across both samplers and locks onto whichever has RF; the
app shows the active sampler (S1/S2) in the status line and reads its power/SWR.

> In **manual** mode the W2 watches only the one selected sampler — so if it's set to
> S2 and you transmit on S1, the meter sees nothing and the app correctly shows no
> power. Switch the sensor, or use Search mode, to follow the active antenna.

Running truly separate antennas/rigs at once? Use **one W2 per sampler/antenna** and
add each as its own meter — the app auto‑focuses whichever is transmitting.

---

## 3. Config & data files (in the app folder)

| File | Contents |
|---|---|
| `W2Monitor.config.json` | Window position/size, UI scale, `topMost`, display toggles, TX timeout, and **meters** (id / name / port). Auto‑saved. |

It's **per‑user** — excluded from the repo. Delete it before zipping to share so the
recipient starts clean.

---

## 4. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| "Could not connect / access denied" on a W2 port | Another app owns it (e.g. the old W2 Utility). Close it — one app per COM port. |
| W2 cable shows a COM port but no data | Wrong cable polarity (see §1). Use KXUSB/KXSER or swap tip↔ring. Confirm it's a true **RS‑232** cable, not USB‑TTL. |
| Flickery / dropping COM port | Reseat into a **rear** USB port (not a hub / front panel). |
| Keyed up but the app reads nothing | The W2 is in manual mode on the *other* sampler — press **Search** or **Switch Sensor** (§2). |
| Wrong meter shown with two+ W2s | The display focuses the meter with the highest forward power; whichever you key wins. |

---

## 5. Packaging & sharing

This folder is self‑contained — **zip it and share**. The launcher uses relative
paths, so it runs from anywhere after unzipping. Recipients run
**`Create Desktop Shortcut.vbs`** once to put a *W2 Monitor* shortcut on their desktop.

**Before zipping to share,** delete your personal `W2Monitor.config.json` (it holds
your window positions and COM/meter assignments).

---

*Station reference: FlexRadio + Elecraft W2 (VHF/UHF samplers, 144–450 MHz).
W2 serial = 9600 8N1 on the rear PC DATA jack. Frequency/CAT and per‑over logging
have moved to a separate LP‑100A (vector wattmeter) project.*
