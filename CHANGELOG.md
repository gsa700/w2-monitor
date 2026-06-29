# Changelog

All notable changes to **W2 Monitor** are documented here.

This project follows [Semantic Versioning](https://semver.org). Versions below
`1.0.0` are pre-release: real and in active use, but not yet broadly field-tested.
`1.0.0` is reserved for when the app has airtime across multiple stations and a
second W2 has exercised the multi-meter path.

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
