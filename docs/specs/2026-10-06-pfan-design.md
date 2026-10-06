# pfan 设计（2026-10-06 定稿）

> P1/P2/P3 的实施计划以本文为准；与计划冲突时以本文裁决。
> 本文件由 P0 复审（I7）要求补入仓库 —— 此前只存在于对话与执行 ledger 中。

## 目标

1. 完成剩余 11 项缺陷 backlog
2. 面板代码质量达到生产级
3. **全栈开源**（内核模块 + 守护进程 + CLI + 面板后端 + 前端 + 文档）

## §1 架构与模块边界

| 单元 | 职责 | 依赖 | 接口 |
|---|---|---|---|
| `core/pfanctl/` | 内核 ACPI 求值器（`/dev/pfanctl`） | 内核头 | write：ACPI 路径+参数；read：返回结果（**补 `.read` 回调，去掉对 dmesg 的依赖**） |
| `core/pfand` | 温度→档位闭环 | `platform.conf` + `/dev/pfanctl` | 只读配置、写 `_FSL`、日志 |
| `core/pfan` | CLI | 同上 | `pfan {get,set,curve,smoke}` |
| `server/pfanel.py` | HTTP API + 采集 + 看门狗 | `platform.conf`、SQLite、`systemctl` | JSON：`/api/{now,curve,params,profile,events,history}` |
| `panel/` | 控制台 UI | 只依赖 pfanel API | 原生 ES module，**无打包器** |

新增两块：`platform/`（配置层，让其余单元可移植）、`fake/`（测试替身，让其余单元可测）。

## §2 平台抽象层

`/etc/pfan/platform.conf`（bash / python 两侧共读，纯 `KEY=VALUE`）：

```ini
EC_ROOT=\_SB.PCI0.LPCB.EC0
FAN_DEVICE=\_SB.PCI0.LPCB.EC0.TFN1
THERMAL_ZONE=/sys/class/thermal/thermal_zone9/temp
EC_CMD=0xB5
```

**探测命令** `pfan detect`：
1. 热区：`grep -l x86_pkg_temp /sys/class/thermal/thermal_zone*/type`（本机 zone9，索引因机器而异，必须现场探测）
2. ACPI：依次试三个候选 `\_SB.PCI0.LPCB.EC0.TFN1` / `\_SB.PC00.LPCB.EC0.TFN1` / `\_SB.PC00.LPCB.EC0`+`\_SB.IETM.TFN1`，能读 `_FST` 即认
3. 探测失败 → 用显式配置并**报错**，绝不静默回退

`pfand` / `pfanel` / `pfan` 的 5 处硬编码（`pfand:32,38`、`pfanel.py:10,14`、`pfan:3`）全部改为读该配置。本机默认值必须等于现值。

## §3 测试体系

| 层 | 工具 | 覆盖对象 |
|---|---|---|
| 纯逻辑单测 | pytest / vitest | `validate_params`、`want_for`/`floor_of`/`center_of`、`est_rpm`、`curve_view`；前端曲线渲染、轮询器、编辑器校验 |
| mock 设备 | 假 `/dev/pfanctl` + 假 thermal zone | `pfand` 应急 / 对账 / fail-safe 全链路（需支持 `DEV`/`TZ` 环境变量覆盖） |
| 实机只读冒烟 | `scripts/smoke.sh` | 服务态、API 形状、曲线整文件一致、公网入口、无硬编码密钥 |
| 静态检查 | shellcheck + `bash -n` + `node --check` + ruff | shell / python / js |

**验收判据：能红也能绿** —— 故意改坏一处，测试必须报红。

## §4 缺陷 backlog 落位

| # | 项 | 实现 | 测试 |
|---|---|---|---|
| ⑩ | `L0=0` 面板与执行不一致 | `validate` 要求 `L0>=25`；曲线表标注 min | pytest |
| ⑪ | `est_rpm` 越界 | `min(rpm, 12000)` | pytest |
| ⑫ | POST 无全局互斥 | `_op_lock` 包住 `set_curve`/`set_level` | 并发 pytest |
| ⑬ | pfand 重启丢 `emerg` | `emerg` 持久化到 state 并恢复 | mock 设备 E2E |
| ⑭ | 日志无轮转 | `logrotate.d/pfan`；同时给 pfanctl 降噪（dmesg 97% 是它） | 安装检查 |
| ⑯ | `daemon_threads` | `ThreadingTCPServer.daemon_threads=True` | pytest |
| ⑰ | 前端无错误处理 / `cached`·`age` 未用 | `j()` 包 try + 渲染错误态；显示数据新鲜度 | vitest |
| ⑱ | `pfanctl.c` 死代码 | 删 `res.length==ACPI_TYPE_INTEGER` 分支；**加 `.read`** | 编译 + 单测 |
| ⑲ | `pfan` CLI 白名单与 pfanel 不一致 | 统一 `0..120`，并禁止 0（`_FSL 0`=停转） | sh 单测 |
| ⑳ | 零测试 | §3 全部 | — |
| ② | 读接口未鉴权 | **不改**（写接口已有 Token+Origin）→ 写进 `SECURITY.md`，并由 ufw 限 LAN | 文档 |
| ②③ | ufw 未放行 8789（LAN 直连不可用） | ✅ P0 已修：`8789/tcp ALLOW 192.168.1.0/24` | smoke 第 3 段 |
| ②④ | `pfan` 非 root 锁失败仍继续，吐出陈旧 dmesg 值 | 明确报错退出；**锁失败必须中止** | sh 单测 |
| ②⑤ | `pfanel.py:517` Origin 白名单硬编码 `192.168.1.10` | 配置化（env / platform.conf） | pytest |
| ②⑥ | `pfanel.py:262` `fps` 对非表档位返回 null，而 `est_rpm` 有兜底 | 同样用 `min(LEVELS, key=...)` 找最近档位再查表 | pytest |
| ②⑦ | `pfanel.py:463` JSON 读接口带 `Access-Control-Allow-Origin: *`，LAN 内任意网页都能跨域拉遥测 | 收紧到面板自身 origin；与 ②「读有意不鉴权」一起写进 `SECURITY.md` | pytest + 前端 |

## §5 开源包装

```
LICENSE            GPL-3.0-or-later
NOTICE             独立逆向实现声明；仅交叉验证 panafanpwr 的**公开发现**，未引用其任何代码
README.md / README.zh-CN.md / SECURITY.md / CONTRIBUTING.md
docs/REVERSE-ENGINEERING.md   ACPI/EC 寄存器表与验证方法（含"查不到 RPM"的负面结论）
docs/PORTING.md                三种路径变体 + 探测方法 + 各机型实测状态
docs/OPERATIONS.md             部署 / 回滚 / 日志 / 故障处置
docs/ARCHITECTURE.md           模块边界与数据流
```

**脱敏**（`scripts/sanitize.sh`，有残留则拒绝 push）：隧道 UUID · LAN IP · token 文件 · 记忆文档 · `audit/`。

**落点**：public `240xu/pfan`（当前 private）。**部署**：`scripts/deploy.sh`（rsync over ssh）取代 base64+ssh。

## §6 执行顺序

- **P0 建网** ✅（仓库 + ci.sh + smoke.sh + pre-push + 私有远端）
- **P1 拆分 + 测试网**：平台层 → 拆前端 → 抽纯函数 → `fake/` → 测试能红能绿
- **P2 清 backlog**：11+4 项，每项"实现 → 测试变绿 → ci 过"才记完成
- **P3 开源包装**：license/docs/移植指南 + DKMS + sanitize + 公开

**每阶段出口判据**：`scripts/ci.sh` 全绿 **且** `scripts/smoke.sh` 全绿。

## §7 风险与回滚

- **拆分回归**（最大风险）→ 每步前后跑 ci + smoke；`/root/backups/pfanfix-*` 保留
- **平台层改错路径** → 默认值 = 本机现值；`pfan detect` 失败必须报错而非猜
- **开源泄露** → sanitize 挡在 push 之前，不靠人 review
- **内核模块**（唯一需重编的部分）→ 改 `.c` → 远端 `make` → 冒烟，失败回滚 `.bak`
- **`.read` 改动** → 保留 dmesg 回退路径，两者并存期比对一致后才删旧路径

## 硬约束（Global Constraints）

- `_FSL` 取值域 **1..120**，**禁止 0**（实测 `_FSL 0` = 风扇停转）
- 不引入打包器；前端原生 ES module，静态文件部署
- lint/测试只在开发机跑；目标机缺 shellcheck/pytest，只跑冒烟
- 曲线参数权威源 = 目标机 `/etc/pfand.conf`
- 写接口鉴权（Token + Origin）；读接口有意不鉴权 → 必须由 ufw 限 LAN
- 工作区一律 UTC+8

## 附录 A：P0 复审延期项（Minor，不进修复轮，留待顺手处理）

| 位置 | 问题 |
|---|---|
| `README:22` | `./scripts/install-hooks.sh` 在 Termux 失败（`/usr/bin/env`），应写 `bash scripts/install-hooks.sh` |
| `README:31` | "机器不可达时只跑 ci，smoke 不 skip 只 FAIL" 自相矛盾（**钩子**会 skip，smoke 本身从不 skip），应拆成两条 |
| `BASELINE.sha256` | `server/pfanel.py` 已过期且仓库内无说明（其唯一消费者 `verify-import.sh` 已在 43da01a 删除） |
| `package.json` | `"test": "echo Error... && exit 1"` 使 `npm test` 恒失败；`"main": "index.js"` 不存在 |
| `smoke.sh:63` | 连接失败时 `$(... || echo 000)` 可能得到 `000000`；取 `${code:0:3}` |
| `smoke.sh` 第 5 段 | 扫的是**仓库**面板副本，而线上服务的是 `/opt/beszel/beszel_data/pfan.html`（今日字节一致；应改名或加部署件哈希） |
| `.editorconfig` | 比计划多了 `trim_trailing_whitespace` 与 md/json 缩进（无害偏离，已记录） |

**另记（P2 期间已知的运行时特性）**：`core/pfand:106` 的 `ensure_s0i3()` 启动时会短暂写 `_FSL 1 0`（约 0.3s），在该窗口内轮询会让 smoke 的 `[1,120]` 检查出现罕见误报。
