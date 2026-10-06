# pfan — Panasonic CF 系列风扇控制

Kernel ACPI helper + temperature daemon + web panel.

Status: under construction (P0).

## Layout

- `core/pfanctl/` — kernel ACPI evaluator (`/dev/pfanctl`)
- `core/pfand` — temperature → fan level closed loop
- `core/pfan` — CLI
- `server/pfanel.py` — HTTP API + collector + watchdog
- `panel/` — control panel (static, no bundler)
- `systemd/`, `config/` — units and curve parameters
- `scripts/` — CI and live smoke
- `tests/` — python / js / shell suites
