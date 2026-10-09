# pfan — Panasonic CF 系列风扇控制

Kernel ACPI helper + temperature daemon + web panel.

Status: under construction (P0).

## Layout

- `core/pfanctl/` — kernel ACPI evaluator (`/dev/pfanctl`)
- `core/pfand` — temperature → fan level closed loop
- `core/pfan` — CLI
- `server/pfanel.py` — HTTP API + collector + watchdog
- `panel/` — control panel (static, no bundler)
- `systemd/`, `config/`, `platform/` — units, curve parameters, platform config
- `deploy/` — files shipped by deploy (logrotate config)
- `scripts/` — ci / deploy / live smoke / hooks installer
- `tests/` — python / js / shell suites
- `docs/` — operations manual + design spec

## Setup

```bash
npm install                      # devDependencies（vitest），按 package-lock.json 安装
bash scripts/install-hooks.sh    # 装 pre-push 钩子（.git/hooks 不受版本控制，clone 后需手动装一次）
```

本机约定：Termux 没有 `/usr/bin/env`，仓库脚本一律用 `bash scripts/<name>.sh` 调用；
写成 `./scripts/xxx.sh` 会 rc=126（`/usr/bin/env: bad interpreter`）。

## Checks

- `bash scripts/ci.sh` — 静态检查 + 全部测试（只在开发机跑）
- `npm test` — 同上，`scripts/ci.sh` 的别名（两者 rc 相同）
- `bash scripts/smoke.sh` — 实机只读冒烟（服务态 / API 形状 / 曲线参数一致 /
  部署面板与仓库一致 / 公网入口 / 无硬编码密钥 / `/dev/pfanctl` 节点形状）

`pre-push` 钩子（`hooks/pre-push`，POSIX sh）串联两者，两种情形必须分开说：

- 机器**可达**时：ci 与 smoke 都必须通过，否则拒绝 push；
- 机器**不可达**时：ci 照常跑完，钩子打印不可达原因（`ssh: connect to host ...`）后放行；
  `PFAN_SKIP_SMOKE=1` 会额外打印一行确认。机器可达时 smoke 照跑，失败即拒绝推送
  （**flag 不能绕过真正失败的 smoke**）。

而 `bash scripts/smoke.sh` 自身**从不跳过**：第 0 段 SSH 探测失败直接 `exit 1`
（`scripts/smoke.sh` 的可达性检查）。

## Deploy

前置：`~/.ssh/pfan_deploy_key` 密钥可用、目标机可达（别名见 `~/.ssh/config`）。

```bash
bash scripts/deploy.sh
```

脚本顺序（不得手拆子步骤）：本地 `ci.sh` → 目标机建恢复点
`/root/backups/pfan-deploy-<时间戳>/` 并暂存新文件 → 传输安装（平台配置**只在缺失时**
写入；运行单元 / 加载器 / logrotate / 面板 4 文件）→ 重启 `pfanel`、`pfand` →
等待控制回路接管（最多 30s）→ 实机 `bash scripts/smoke.sh`。
回滚点路径打印在脚本结尾。

> ℹ️ 暂存名：`core/pfan` 与 `deploy/logrotate.d/pfan` 都叫 `pfan`，所以 logrotate 走
> 独立的 `$STAGE/logrotate-pfan`。同名的后果曾是把 logrotate 规则装成
> `/usr/local/bin/pfan`——现已修复，并由 `test_repo_hygiene` T7 钉住。


**回滚**：把恢复点里的文件拷回原位 + `systemctl restart pfanel pfand`
（**不要**顺手重启 `pfanctl` —— deploy 不动内核模块，见「服务」一节的覆盖边界），
逐步骤见 `docs/OPERATIONS.md`（该流程由 `deploy.sh` 的备份清单推导，**未经目标机实操验证**）。

## Docs

- 操作手册（部署 / 回滚 / 内核模块重建 / 日志 / 故障处置）：`docs/OPERATIONS.md`
- 安全模型与已知取舍：`SECURITY.md`
- 设计与裁决（含 P0/P1/P2 复审附录 A/B/C）：`docs/specs/2026-10-06-pfan-design.md`

## License

GPL-3.0-or-later — full text in [`LICENSE`](LICENSE).

This is an independent implementation. It was written without copying or decompiling any
other project's code; development consulted only publicly documented behaviour of the
hardware (the ACPI `_FSL`/`_FST` methods, `s0i3` mode, and `fine_grain_control`). See
[`NOTICE`](NOTICE) for the full statement — which matters precisely because the license is
copyleft.

### Third-party components

Vendored in `panel/vendor/`:

| Component | Version | Author | License | Files |
|---|---|---|---|---|
| [uPlot](https://github.com/leeoniya/uPlot) | 1.6.32 | Leon Sorokin | MIT | `uPlot.esm.js`, `uPlot.min.css`, `uPlot.LICENSE` |

Both distributed files are byte-identical to the `npm pack uplot@1.6.32` output (verified by
sha256). MIT is compatible with GPL-3.0; the license text ships alongside them and is
installed on the appliance.
