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
| 实机只读冒烟 | `scripts/smoke.sh` | 服务态、API 形状、曲线整文件一致、部署面板与仓库一致、公网入口、无硬编码密钥 |
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
LICENSE            GPL-3.0-or-later          ← 尚未创建（P3 待办）
NOTICE             独立逆向实现声明；仅交叉验证 panafanpwr 的**公开发现**，未引用其任何代码  ← 尚未创建
README.md ✅ / README.zh-CN.md ✗ / SECURITY.md ✅ / CONTRIBUTING.md ✗
docs/REVERSE-ENGINEERING.md   ACPI/EC 寄存器表与验证方法（含"查不到 RPM"的负面结论）  ← 尚未创建
docs/PORTING.md                三种路径变体 + 探测方法 + 各机型实测状态  ← 尚未创建
docs/OPERATIONS.md             部署 / 回滚 / 日志 / 故障处置  ← ✅ 已存在（2026-10-07 逐条核实）
docs/ARCHITECTURE.md           模块边界与数据流  ← 尚未创建
```

（✅/✗ 为 2026-10-07 对仓库文件清单的核对；缺的都是 P3 待办，不是遗漏。）

**脱敏**（`scripts/sanitize.sh`，有残留则拒绝 push）：隧道 UUID · LAN IP · token 文件 · 记忆文档 · `audit/`。
—— `scripts/sanitize.sh` **尚未实现**（2026-10-07 核实：`scripts/` 只有 ci/deploy/install-hooks/smoke-lib/smoke）。

**落点**：public `240xu/pfan`（当前 private）。**部署**：`scripts/deploy.sh`（**scp** over ssh，非本节早稿写的 rsync；2026-10-07 核实 `deploy.sh:33-37` 用 `scp`）取代 base64+ssh。

## §6 执行顺序

- **P0 建网** ✅（仓库 + ci.sh + smoke.sh + pre-push + 私有远端）
- **P1 拆分 + 测试网**：平台层 → 拆前端 → 抽纯函数 → ~~`fake/`~~ → 测试能红能绿
  - **裁决（P1 复审 I6）**：spec §3/§6 原本把 `fake/` 假设备 E2E 与 `want_for`/`floor_of`/
    `center_of`/`curve_view` 的单测列为 P1 范围，P1 计划漏排了这一层。裁定：
    **`fake/` 假设备层 + 守护循环单测推迟到 P2**，且**必须在 P2 动 backlog 之前先建**。
    依据：P1 的控制路径测试已用 `PFAN_DEV`/`PFAN_LOCK`/`PFAN_PROBE` 接缝覆盖了
    「进程级」缺陷（复审 C1 死锁就是靠它抓到的），而 `fake/` 要覆盖的是
    「守护循环决策逻辑」—— 那正是 P2 修 ⑩~⑳ 时的主要改动面，测试应与改动同期建立。
    代价（若判错）：循环逻辑类缺陷可能带进 P2，由实机冒烟兜底，且 P2 开工第一件事就是补它。
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

> 状态列由 2026-10-07 的清理轮逐条核实回填；行号为核实当时的行号。
> 回归网：`tests/shell/test_repo_hygiene.sh`（RED→GREEN 记录在该轮交接说明里）。

| 位置 | 问题 | 状态（2026-10-07 核实） |
|---|---|---|
| `README:22` | `./scripts/install-hooks.sh` 在 Termux 失败（`/usr/bin/env`），应写 `bash scripts/install-hooks.sh` | ✅ **已修**：Setup 改为 `bash scripts/install-hooks.sh`，本机实跑 rc=0（且顺带刷新了 `.git/hooks/pre-push` 里那份过期副本）；守卫 T3 |
| `README:31` | "机器不可达时只跑 ci，smoke 不 skip 只 FAIL" 自相矛盾（**钩子**会 skip，smoke 本身从不 skip），应拆成两条 | ✅ **已修**：拆成「可达/不可达两种情形」+「smoke 自身从不跳过」两条；守卫 T3 钉死矛盾句不得回归 |
| `hooks/pre-push`（核实该条时的**新发现**） | 钩子在机器不可达时于 `probe_err=$(ssh …)` 那行因 `set -e` 直接退出（rc=255），第 14–19 行「打印跳过原因 / `PFAN_SKIP_SMOKE=1` 放行」是死代码，push 照样被拒 | **✅ 已修**（两次）：(1) `1b8218e` 用 `probe_rc=0; probe_err=$(ssh …) || probe_rc=$?` 接住退出码，守卫 T8；(2) `148df63` 发现**同一分支里第二颗地雷** —— 跳过提示行写成 `[ "${PFAN_SKIP_SMOKE:-0}" = 1 ] && echo …`，条件为假时返回 1，`set -e` 再次掐断钩子，表现是「机器不可达时 push 被无理由拒绝、日志停在上一行」；改用 `if` 后修复，守卫 T10。README 同期改为如实描述（`b0ac675`）——**本行此前曾误标为「README 同步改为如实描述」而实际未改，已订正**。 |
| `BASELINE.sha256` | `server/pfanel.py` 已过期且仓库内无说明（其唯一消费者 `verify-import.sh` 已在 43da01a 删除） | ✅ **已处置 = 删除**。理由：它是一次性导入门禁（43da01a 的提交说明已把消费者退役），复活消费者只会得到「改任何受管文件都要重算」的伪控制 —— 仓库可写者能同时改文件和哈希，没有信任锚；真实一致性由 `smoke.sh` 对**目标机**的比对（第 4 段曲线、第 5 段部署件）承担。守卫 T4：「BASELINE.sha256 要么有活消费者，要么不存在」。`BASELINE.date` 同批处理 = **也删除**（同一理由：全仓只有本文档提到它，无代码消费者；守卫 T4 已扩到 `BASELINE.*` 两个文件，孤儿不会再悄悄回来） |
| `package.json` | `"test": "echo Error... && exit 1"` 使 `npm test` 恒失败；`"main": "index.js"` 不存在 | ✅ **已修**：`test` → `bash scripts/ci.sh`（`npm test` 作为唯一惯例入口应跑全量套件；只挂 js 套件会造出一个更弱的第二入口，把 shell/python 检查藏起来），`main` 删除，另加 `private: true` 防误发布；守卫 T1/T2，`npm test` 实跑 rc=0 |
| `smoke.sh:63`（现 88/94 行） | 连接失败时 `$(… \|\| echo 000)` 可能得到 `000\n000` / `000000`；取 `${code:0:3}` | ✅ **已修**：两处状态码赋值后立刻切 3 位（`code=${code:0:3}`、`c=${c:0:3}`）；守卫 T5（断言的是**赋值后切片**，不是错误文案里的顺手截断） |
| `smoke.sh` 第 5 段 | 扫的是**仓库**面板副本，而线上服务的是 `/opt/beszel/beszel_data/`（今日字节一致；应改名或加部署件哈希） | ✅ **已修**：改为对 4 个部署件（`index.html/styles.css/app.js/core.js`，即 `PANEL_DIR` 的实际内容）做 ssh `sha256sum` 与仓库副本比对，分叉即报红；密钥扫描仓库与部署件两边都做；守卫 T6。**部署件字节是否真与仓库一致需实机 smoke 才能证实 [未验证]** |
| `.editorconfig` | 比计划多了 `trim_trailing_whitespace` 与 md/json 缩进（无害偏离，已记录） | ⚠️ **仍开放**：按原样保留（无害） |

**另记（P2 期间已知的运行时特性）**：`core/pfand` 的 `ensure_s0i3()`（定义在 182 行，其中
`_FSL 1 0` 在 185 行，启动调用在 233 行 —— 原记 106 行已漂移）启动时会短暂写 `_FSL 1 0`
（约 0.3s），在该窗口内轮询会让 smoke 的 `[1,120]` 检查出现罕见误报。

## 附录 B：P1 复审延期项（Minor，不进修复轮）

> 状态列与行号由 2026-10-07 逐条核实回填。`panel/`、`server/`、`core/` 归其他代理/
> 后续轮次，本轮只更新本表、不动代码。

| 位置 | 问题 | 状态（2026-10-07 核实） |
|---|---|---|
| `panel/index.html:14` | 副标题仍写死数据源 `thermal_zone9`；移植到别的机器即错，且不在静态扫描的 3 文件集合内。应改为从 `/api/now` 渲染或直接去掉 | **✅ 已修**（UI 代理，见 1b8218e）：副标题不再写死 `thermal_zone9`；与 `test_no_hardcode.sh` 的「thermal_zoneN 归零」口径对齐。 |
| `core/pfanctl/pfanctl.c` ec88 便捷语法（原记 98-103，现 159–180） | 硬编码 EC 路径 `\_SB.PCI0.LPCB.EC0.EC88`；仓库内无调用方、全仓文档零引用 → ⑱ 当时未并入。**推迟（代价已核）**：删它会改 `pfanctl.c`，而 `smoke.sh` §9 要求目标机源码与仓库一致、`.ko` 不早于 `.c` —— 即**必须付一次 rmmod/insmod 窗口**，且 `test_pfanctl_source` 的「受检调用点 ≥3 处」要同步改成 ≥2。纯度收益换一次热路径窗口不划算：**并入下一次内核改动合并做**（下次重载前先改附录状态）。 | ⏸ **推迟，需内核重载窗口** |
| `core/pfan` `detect --write` | 非原子写；中途崩溃会留下半截配置，下次开机 fail-close。应 temp + `mv` | **✅ 已修**：temp + `mv` 原子写（同目录 rename 原子），失败清理临时文件；守卫 `test_appendix_closeout` T3（变异验证：还原成直接 `printf > "$2"` 即红）。 |
| `EC_CMD` | 两侧加载器都要求、`detect` 也写入，但**没有任何消费者**（死键）。spec 要求它存在 → 补注释说明用途 | **✅ 已修**：`platform.conf.example` 补注释，写明「当前无行为消费者，仅为配置完整性与 REQUIRED 校验保留」；守卫 T4。 |
| `panel/app.js` free 模式看门狗文案互相矛盾（原记 `:40` vs `:77`） | 代码（`GUARDED`）表明**会接管** → 文案与 `guard()` docstring 过期 | **✅ 已修**：代码为准（`GUARDED = ("quiet","s0i3","free")`，free **会**被接管）。改掉两处过期文案 —— `panel/app.js` 的「此模式下不接管」与 `guard()` docstring 的「free 模式不看门狗」，两处都改为与 GUARDED 一致；守卫 T1。 |
| `server/pfanel.py` `/api/levels` | 仍返回 `free_range:[0,120]` 与 "0~120"，而 0 在别处全面禁止（既存问题，纯文案矛盾） | **✅ 已修**：`free_range:[0,120]` → `[1,120]`，note 改为「固件实测 0~120，但本 API 禁 0（_FSL 0 = 停转），交回曲线用 set_curve(auto)」—— 对外契约描述 API 行为而非固件能力；守卫 T2。 |
| 目标机 `/opt/beszel/beszel_data/pfan.html` | 拆分后遗留的旧单文件；deploy 会备份但从不删除，无任何在用消费者 | **[未验证]**（部署件在目标机）。仓库侧可核实：`deploy.sh:28` 确实只备份、全程无删除；仓库内除该备份行外无任何消费者 |

**修复轮中顺手解决的（原为 Minor）**：`pfan set` 里 `$DEV` 未加引号（现 `core/pfan` 58/78/159 行
均为 `> "$DEV"`，2026-10-07 复核 ✅）；`PFAN_LOG` 在 fail-safe 分支之后才生效
（现 `core/pfand:33` 在 fail-safe `exit 1`（103 行）之前就完成赋值 ✅）。

**已知语义特性（P2 处理）**：`core/pfand` 的 `ensure_s0i3()` 启动时短暂写 `_FSL 1 0`（约 0.3s），
该窗口内轮询会让 smoke 的 `[1,120]` 出现罕见误报 —— deploy 的 4b 等待接管判据已覆盖部署路径。

### 附录 C：P2 裁决（2026-10-06；状态 2026-10-07 复核）

| # | 裁决 | 理由 | 状态（2026-10-07 核实） |
|---|---|---|---|
| C1 | ⑱ 的 `.read` 回调**推迟**到后续阶段 | 加了 `.read` 但三个消费者（pfan/pfand/pfanel）不同时迁移就毫无收益，而只有全部迁完才能去掉 RESULT 行；这三条共同维持风扇控制，热路径上的协调迁移应单独一个阶段做双路径一致性验证（`.read` 与 dmesg 同时读、断言相等），不塞进 backlog 扫尾。dmesg 路径当前全绿（smoke 21/21）。⑱ 中的两个真实缺陷（死分支、八进制解析）已修复并测试。 | **仍有效**：`core/pfanctl/pfanctl.c` 仍无 `.read` 回调（grep 0 命中），三个消费者仍走 dmesg RESULT（`pfanel._result_state()` 读 `PFAN_DMESG`）；死分支已删（`pfanctl.c:100-105` 注释 + 新分支可查）、八进制解析已由 `pfan_parse` 收口（`pfanctl.c:48-68`，`tests/shell/test_pfanctl_source.sh` + `test_control_paths.sh` T3 断言）。原理由里「smoke 21/21」需实机才能证实 **[未验证]** |
| C2 | panel 不发任何 CORS 头 | 面板与 API 同源（`API=""`），通配头只会让 LAN 内任意网页跨域读遥测；`smoke.sh` 2b 段用 **GET** 断言（旧版无 `do_HEAD`，HEAD 会 501 假阳性）。 | **仍有效**：`pfanel._send()` 不发 `Access-Control-Allow-Origin`（2026-10-07 复核 `server/pfanel.py:499`），smoke 2b 断言「完全没有该头」 |
| C3 | pfanel 状态路径接缝与 pfand **同名** | `PFAN_LOCK/DEV/DMESG/CONF/CURVE_FILE` 两边一致，只有一套词汇；缺省值必须等于生产值，由测试断言。 | **仍有效**：五个接缝两边同名同缺省（`core/pfand:32-51` / `server/pfanel.py:45,60,160,178,361`），`tests/shell/test_seam_defaults.sh` 逐条钉住 |
