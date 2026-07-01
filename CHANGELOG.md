# Changelog

All notable changes to **W2 Monitor** are documented here.

This project follows [Semantic Versioning](https://semver.org). Versions below
`1.0.0` are pre-release: real and in active use, but not yet broadly field-tested.
`1.0.0` is reserved for when the app has airtime across multiple stations and a
second W2 has exercised the multi-meter path.

## [0.10.0-beta] - 2026-07-01

Refocused on the core job — rock-solid multi-W2 power/SWR monitoring. The
frequency-aware antenna-analysis features are moving to a separate, vector-capable
LP-100A project, where phase/impedance data makes them far more useful. This trims
the app to the W2 essentials and makes it smaller and easier to share.

### Added
- **Search control** (W2 Controls) — toggles the W2's Sensor *Search* mode (serial
  `Y` command) so a single W2 automatically hunts across **both** of its samplers,
  without press-and-holding the front-panel SENSOR button. (The W2 measures only one
  sampler at a time; Search mode is what lets the app follow whichever has RF.)

### Changed
- **TX timer hardened** — read dropouts no longer reset the timer mid-over, elapsed
  minutes floor correctly, and the alert is locked to the timeout setting: solid
  **yellow 30 s before** TOT, **red flashing at/after** TOT while it keeps counting
  (still fully silent, so nothing goes over the air).

### Removed
- **CAT radio / live-frequency subsystem** — the Kenwood TM-D710/V71A, Kenwood
  TS-2000 / Elecraft / SmartSDR CAT, and Hamlib `rigctld` drivers; the Radios window;
  the per-sampler frequency readout; and the `Start-Rigctld-V71A.bat` helper.
- **Per-transmission CSV logging** — the log file, the in-app log reader, and the
  **Open in Excel** button.
- **SWR-vs-frequency plot** window.

  These all depend on frequency / logged data and are being redeveloped in a dedicated
  LP-100A (vector wattmeter) project, where phase/impedance make them genuinely powerful.

## [0.9.0-beta] - 2026-06-29

First public beta.

### Added
- **Multi-meter support** — monitor one or more Elecraft W2 meters at once, each on
  its own background runspace; the display auto-focuses whichever sampler is
  transmitting. A **Detect** button auto-finds connected W2 meters.
- **Per-sampler CAT radio binding** for live frequency, with three drivers:
  Kenwood TM-D710/V71A, Kenwood TS-2000 / Elecraft / SmartSDR CAT, and
  **Hamlib `rigctld` (network)** for shared-port, multi-app, and remote setups.
- **Resizable dark UI** that scales with width; toggleable rows (status line, power
  bar, SWR bar, reflected power, return loss, peak, TX timer, frequency).
- **TX timeout timer** with configurable TOT: solid yellow 30 s before TOT, red
  flashing at/after TOT (keeps counting), fully silent so nothing goes over the air.
- **Per-transmission CSV logging** (timestamp, meter, frequency, duration, peak
  forward, max SWR, min return loss, sensor, range, type, timed-out), capped to a
  rolling 2000 rows, with an in-app log reader and **Open in Excel**.
- **SWR-vs-frequency plot** built from the logged overs, colored/filtered per
  antenna with reference lines at SWR 1.5 and 2.0.
- Window positions/sizes, UI scale, selected ports, display toggles, timeout, and
  logging state **persist between sessions**.

### Requirements
- Windows with .NET Framework (built in). **Hamlib** (`rigctld`) is an optional,
  separate install, used only for the network radio driver.

### Notes
- Licensed under **GPLv3** (see `LICENSE`).
- Elecraft and Kenwood are trademarks of their respective owners; this is an
  independent project.
