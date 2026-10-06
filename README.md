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

## Setup

```bash
npm i -D vitest              # 前端测试
./scripts/install-hooks.sh   # 装 pre-push 钩子（.git/hooks 不受版本控制）
```

本机约定：Termux 没有 `/usr/bin/env`，仓库脚本一律用 `bash scripts/<name>.sh` 调用。

## Checks

- `bash scripts/ci.sh` — 静态检查 + 测试（只在开发机跑）
- `bash scripts/smoke.sh` — 实机只读冒烟（服务态 / API 形状 / 曲线参数一致 / 公网入口 / 无硬编码密钥）
- `pre-push` 钩子串联两者；机器不可达时只跑 ci，smoke 不 skip 只 FAIL
