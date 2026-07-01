# W2 Monitor

A modern, dark‑themed Windows desktop monitor for **Elecraft W2** RF power / SWR
meters — multi‑meter, full W2 control, and a transmit‑timeout timer, in a clean
resizable window that replaces the legacy W2 Utility.

[![Release](https://img.shields.io/github/v/release/gsa700/w2-monitor?include_prereleases&color=orange)](https://github.com/gsa700/w2-monitor/releases)
[![License](https://img.shields.io/github/license/gsa700/w2-monitor?color=blue)](LICENSE)
![Platform](https://img.shields.io/badge/platform-Windows-lightgrey)

![W2 Monitor main window](docs/screenshot-main.png)

W2 Monitor talks directly to one or more W2 meters over serial and gives you a
clean, resizable readout. Each meter runs on its own background thread, so the
display stays glassy‑smooth no matter what else is going on. Built for the
VHF/UHF‑and‑up world where the W2 lives.

> **Beta (v0.10.0):** in active on‑air use, but not yet broadly field‑tested.
> Bug reports and suggestions are very welcome — open an [issue](https://github.com/gsa700/w2-monitor/issues).

## Features

- **Live readout** — forward power, SWR, reflected power, return loss, and peak‑hold,
  with bar graphs and SWR color coding (green / amber / red).
- **Multiple W2 meters** at once — each on its own background runspace; the display
  auto‑focuses whichever meter is transmitting. A **Detect** button finds connected meters.
- **Full W2 control** from the app — switch sensor, auto / manual range, Avg / PEP,
  Peak‑Hold LED, LEDs on/off, reset peak, and **Search**: put the W2 in Sensor‑Search
  mode so it automatically follows whichever of its two samplers has RF (the W2 reads
  one sampler at a time, so Search is what lets a single meter cover both antennas).
- **TX timeout timer** with a configurable TOT: turns **solid yellow 30 s before**
  timeout and **red‑flashing at/after** timeout while it keeps counting — and it's
  **silent**, so nothing goes out over the air.
- **Resizable, scaling UI** with toggleable rows; window position, size, ports, and
  every preference **persist between sessions**.

## Screenshots

Main readout and Setup:

![W2 Monitor overview](docs/screenshot-overview.png)

## Requirements

- **Windows 10 / 11** (.NET Framework — already built in; nothing to install)
- An **Elecraft W2** with its serial or USB interface (KXSER / KXUSB) on a COM port

## Install

1. Download the latest **[release](https://github.com/gsa700/w2-monitor/releases/latest)**
   (the “Source code (zip)” is a clean, ready‑to‑run package).
2. **Right‑click the zip → Properties → Unblock**, then extract it anywhere.
3. Run **`Launch W2 Monitor.vbs`**. (Double‑run **`Create Desktop Shortcut.vbs`** once
   to drop a desktop icon.)

No installer, no admin rights, nothing written to your system — the launcher just
starts the PowerShell script with the right execution policy.

## Quick start

1. Click **Setup**, assign your W2's COM port to a meter, and press **Connect**.
2. Key into a dummy load — power, SWR, and return loss update live.
3. Running two antennas on one W2's two samplers? Press **Search** (or hold the W2's
   front‑panel SENSOR button) so the app follows whichever sampler has RF.

Full wiring and baud‑rate details are in the
**[connection & setup guide](W2Monitor-README.md)**.

## Configuration & data

- Settings live in `W2Monitor.config.json` next to the app (auto‑created).
- It's **per‑user** and excluded from the repo — your station data stays yours.

## License

Released under the **[GNU General Public License v3.0](LICENSE)**. You're free to use,
study, share, and modify it; derivative works must stay open under the same license.

## Credits

Created by **David Erickson (AB0R)** in collaboration with **Claude (Anthropic)**,
which did the heavy lifting on the code.

## Disclaimer

*Elecraft* is a trademark of its respective owner. This is an independent project,
not affiliated with or endorsed by Elecraft. The software is provided **without
warranty of any kind** — you are responsible for your station and your transmissions.

73! 📻
