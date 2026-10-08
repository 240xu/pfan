# Operations

面向**已经部署本项目的机器**的操作记录。改任何一条之前先读这一节。

> 标注约定：**[未验证]** = 该陈述**无法从本仓库核实**（目标机状态、Cloudflare 侧配置、
> 历史恢复点、现场时间线），执行前请先在目标机上核对；没有标注的条目均已逐条对照
> 仓库内源码（`scripts/`、`systemd/`、`server/`、`core/`）核实，2026-10-07。

## 拓扑

- 控制面板后端 `pfanel` 监听 `0.0.0.0:8789`
  （核实：`server/pfanel.py` `_PORT = PFAN_PORT` 缺省 8789、`Server(("0.0.0.0", _PORT), H)`）
- 公网入口 `https://pfan.example.com/pfan`
  —— **[未验证]** 「Cloudflare 隧道 → 本机回环，不经 ufw 外部 INPUT」这半句的隧道配置在
  CF 侧，仓库内只能核实到 `scripts/smoke.sh` 对该 URL 的 GET 断言。
- 开发/运维入口：SSH
  - 别名：`~/.ssh/config` 里 `Host 192.168.1.10 fanhost`（`User pfan`、
    `IdentityFile ~/.ssh/pfan_deploy_key`、`IdentitiesOnly yes`）
  - 脚本**不用**别名：`scripts/deploy.sh` / `scripts/smoke.sh` 写死
    `pfan@${PFAN_HOST:-192.168.1.10}` + `-i ~/.ssh/pfan_deploy_key`，换机器用 `PFAN_HOST` 覆盖

## 常用检查

```bash
bash scripts/ci.sh                # 开发机：静态检查 + 全部测试（= npm test）
bash scripts/smoke.sh             # 实机只读冒烟；SSH 不可达直接 exit 1，从不 skip
PFAN_HOST=<ip> bash scripts/smoke.sh   # 换目标机
```

`smoke.sh` 允许的远端操作只有：GET / `systemctl show|is-active|is-enabled` / `cat` /
`grep` / `stat` / `sha256sum` / `pfan get`（`_FST` 查询是 getter）—— 详见脚本头部。

## 防火墙（读接口未鉴权的前提条件）

`pfanel` 的**读接口有意不鉴权**（见 `SECURITY.md` / backlog ②）。因此 8789 **绝不能**对公网开放，
只能放行本机 LAN 子网：

```bash
ufw allow from 192.168.1.0/24 to any port 8789 proto tcp comment "pfan panel LAN"
```

验证（在目标机上执行）：

```bash
ufw status | grep 8789
# 期望形如：8789/tcp    ALLOW    192.168.1.0/24    # pfan panel LAN
#   —— **[未验证]** 当前生效规则与「注释是否显示」都取决于目标机 / ufw 版本
curl -fsS http://<host>:8789/api/now | jq .
```

变更前的规则备份（本机）：`/root/backups/pfan-ufw-<timestamp>/{user.rules,user6.rules,status.after.txt}`
—— **[未验证]**（目标机路径，仓库无法核实）。

> ⚠️ **不要**用 `ufw allow ... port 8789 proto tcp`（不带 `from`）—— 那等于对 Anywhere 开放未鉴权遥测。

## 曲线参数的权威源

- 权威文件：目标机 `/etc/pfand.conf`（由面板「自定义曲线」按钮**原子**写入 ——
  核实：`server/pfanel.py` `write_params()` 走 `CONF + ".tmp"` + `os.replace()`）
- 仓库副本：`config/pfand.conf.example`
- `scripts/smoke.sh` 第 4 段对两者做**整文件 sha256 比对**；不一致即报红

改曲线参数的正确路径：面板 `/api/params` → 仓库副本随之同步 → smoke 校验一致。
**不要**只在机器上手改，否则下次 smoke 必红。

## 服务

| 单元 | 说明 |
|---|---|
| `pfanctl.service` | 幂等 insmod `pfanctl.ko`；第二个 `ExecStart` 遇到「节点不是字符设备」时先 `rm -f` 再重载（`systemd/pfanctl.service`） |
| `pfand.service` | 温度→档位闭环，`Restart=on-failure`，**只在曲线=`s0i3` 时接管**（`core/pfand` 曲线守卫：非 s0i3 打日志后 `exit 0`，故不能用 `always`，否则 15s 空转循环） |
| `pfanel.service` | HTTP 面板后端，`Restart=always` |

⚠️ `systemctl restart pfanctl` 的**覆盖边界**：单元里是
`grep -q ^pfanctl /proc/modules || insmod ...`，所以（a）模块已在跑则不重载；
（b）节点被删但模块仍在 → 单元不会重建节点。这两种情况都按下面「内核模块」一节的三步走。
（推导自 `systemd/pfanctl.service`；devtmpfs「节点只在模块注册时创建」属内核语义，**[未验证]** 本仓库无从证实。）

恢复点：`/root/backups/pfanfix-<timestamp>/`（第一批修复的全量回滚）、
`/root/backups/pfan-ufw-*/` —— **[未验证]**（目标机历史目录；`deploy.sh` 确实每次往
`/root/backups/pfan-deploy-<ts>/` 写新恢复点，但上面两个历史路径无法从仓库核实）。

## 部署与回滚

### 部署

唯一入口：`bash scripts/deploy.sh`（顺序纪律写在脚本里，不要手拆子步骤）。五步：

1. 本地 `bash scripts/ci.sh`（不绿不动目标机）
2. 目标机建恢复点 `/root/backups/pfan-deploy-<时间戳>/`，新文件暂存 `/tmp/pfan-deploy-$$`
3. 传输 + 安装：`/etc/pfan/platform.conf` **只在缺失时**由 example 建立（已有配置绝不覆盖）；
   运行单元 / 加载器 / logrotate（带 `logrotate -d` 自检）/ 面板 4 文件
4. 重启 `pfanel`、`pfand`，4b 段轮询等控制回路接管（`pfand=active` 且 `level>=1`，最多 30s）
5. 实机 `bash scripts/smoke.sh`

> ⚠️ **已知缺陷（2026-10-07 静态确认，执行前必读）**：`scripts/deploy.sh` 先把 `core/pfan`
> 传成 `$STAGE/pfan`（第 33 行），又把 `deploy/logrotate.d/pfan` 传成**同一个**
> `$STAGE/pfan`（第 37 行，后者覆盖前者），随后第 54 行把 `$STAGE/pfan` 安装为
> `/usr/local/bin/pfan` —— 装完的「pfan CLI」其实是 logrotate 配置，smoke 第 8 段
> `pfan get` 必失败。**修好前不要跑 `bash scripts/deploy.sh`**；`deploy.sh` 不在本轮
> 修复范围内，已上报协调者。

### 回滚

`deploy.sh` 只备份、不提供一键回滚；恢复点路径打印在脚本结尾。手工回滚
（**推导自 `deploy.sh:24-29` 的备份清单，未经目标机实操验证 —— [未验证]**）：

```bash
# 目标机上，B = deploy 结尾打印的 /root/backups/pfan-deploy-<ts>
sudo cp -a "$B"/pfand "$B"/pfan "$B"/pfanel.py "$B"/pfan_platform.py "$B"/pfan_core.py /usr/local/bin/
sudo systemctl restart pfanel pfand
bash scripts/smoke.sh          # 回滚后必须全绿
```

**恢复点里没有的东西**（核实自 `deploy.sh` 的备份清单）：

- 面板 4 文件（`index.html/styles.css/app.js/core.js`）—— 只备份了旧单文件 `pfan.html`；
  要回滚面板需从 git 历史检出字节再手动 `install`
- `/etc/logrotate.d/pfan`、`/usr/local/lib/pfan/platform.sh`、`/etc/pfan/*`、内核模块

## 日志

| 文件 | 写入者 | 轮转 |
|---|---|---|
| `/var/log/pfand.log` | `core/pfand` `log()`（`PFAN_LOG` 可覆盖） | `deploy/logrotate.d/pfan` |
| `/var/log/pfanel.log` | `server/pfanel.py`（guard / set_curve 兜底分支等追加写） | 同上 |
| journal | 三个单元的 stdout/stderr | **[未验证]** 目标机 journald 持久化配置 |

轮转配置要点（`deploy/logrotate.d/pfan`）：`copytruncate`（两个进程都是 `>>` 追加、无信号处理）、
`su root syslog`（`/var/log` 是 775 root:syslog，缺它 logrotate 直接拒转）、
每日、`rotate 7`、`maxsize 10M`。安装时 deploy.sh 会跑 `logrotate -d` 语法演练。

## 发布前置条件（P3 才执行）

本仓库**即将公开**。翻转 visibility 之前必须满足：

1. `scripts/sanitize.sh` 已实现且通过（扫描隧道 UUID、LAN IP、token、私钥、记忆文档、`audit/`）
   —— **状态：未完成**（`scripts/` 里只有 ci/deploy/install-hooks/smoke-lib/smoke，脚本尚不存在）
2. 本文档与 `scripts/smoke.sh` 中的 LAN 子网已按 sanitize 规则处理
   —— **状态：未完成**（两者仍含 `192.168.1.0/24` / `192.168.1.10`）
3. `server/pfanel.py` 的 Origin 白名单已配置化（backlog ②⑤），不再硬编码 IP
   —— **状态：已完成**（`PFAN_ORIGIN_ALLOW` 环境变量可覆盖；
   缺省 `DEFAULT_ORIGINS` 仍含本机 LAN IP，属预期缺省，测试断言缺省=生产值）

在 1、2 未全部满足前，**不得**把仓库改为 public。

## 内核模块 `pfanctl.ko` 的重建与重载

**构建**（`/opt/pfanctl/Makefile` 只是 kbuild 片段，不能直接 `make` ——
核实：仓库 `core/pfanctl/Makefile` 只有一行 `obj-m := pfanctl.o`，直接 `make` 报
`make: *** No targets.  Stop.`）：

```bash
cd /opt/pfanctl
sudo make -C /lib/modules/$(uname -r)/build M=/opt/pfanctl modules
```

> `deploy.sh` **不同步** `/opt/pfanctl`（传输清单里没有 `pfanctl.c`/`Makefile`），
> 所以目标机 `/opt/pfanctl` 以机器为准 —— **这条不再是"需现场核对"，`smoke.sh` §9 每次
> 都会比对**：（a）仓库与目标机 `pfanctl.c` 的 sha256，（b）`.ko` 是否早于 `.c`
> （早于 = 源码改过但没重新编译，现役模块仍是旧行为）。两项任一不符即报红，
> 守卫见 `tests/shell/test_repo_hygiene.sh` T9。
>
> 同步源码但**不**自动重建（重建涉及 rmmod 窗口，必须人来决定时机）：
>
> ```bash
> scp -i ~/.ssh/pfan_deploy_key core/pfanctl/{pfanctl.c,Makefile} pfan@192.168.1.10:/tmp/
> ssh ... 'sudo -n mv /tmp/pfanctl.c /tmp/Makefile /opt/pfanctl/'
> ```

**重载**（改了 `.c` 之后）：

```bash
sudo rm -f /dev/pfanctl      # ← 必须先删，见下方事故
sudo rmmod pfanctl
sudo insmod /opt/pfanctl/pfanctl.ko
test -c /dev/pfanctl && echo OK      # 必须是字符设备
```

> ⚠️ **`rmmod` 会摘掉 `/dev/pfanctl` 节点。在模块不在位期间，任何
> `echo ... > /dev/pfanctl` 都会把它创建成【普通文件】**，随后 `insmod` 的
> `misc_register` 看到路径已存在就不会覆盖 —— 此后**所有风扇读写都被静默写进这个
> 普通文件，控制完全失效，且不报任何错**。
>
> 2026-10-06 14:31–14:33 实际踩中：控制丢失约 2 分钟，风扇保持在失效前的 50%，
> CPU 峰值约 70°C（应急线 80°C，无热风险）。是 pfand 的**对账**抓出来的：
> `对账: written=30 -> 实际=50 (外部改档或写入未生效)`
> —— 机制核实：`core/pfand` 确有该对账日志与「普通文件遮蔽」的
> `log_dev_hazard()`；**时间线与温度数字为现场记录 [未验证]**。
>
> 恢复：`rm -f /dev/pfanctl` + 重载即可（devtmpfs 会重建字符设备）。
> 三步缺一不可的原因见上面「服务」一节的覆盖边界说明。
>
> **自检**：`stat -c %F /dev/pfanctl` 必须输出 `character special file`
> （与 `scripts/smoke.sh` 第 7 段同一判据）。

**回滚点**：`/root/backups/pfanctl-build-20261006-142743/{pfanctl.c,pfanctl.ko}`（重载前的原件）
—— **[未验证]**（目标机路径）。

### 重建履历

| 日期 | 触发 | 结果 | 恢复点 |
|---|---|---|---|
| 2026-10-08 21:16 | 审计 F5/M11/M12/M13 落地后源码领先现役 `.ko`（坏 token → 静默 0 → `_FSL 0` 停转；`argc>INT_MAX` → 内核栈越界读） | 编译 2 条既有 warning（缩进/帧大小，与 10-06 同）；先编译后重载；`_FSL 1 abc` 从 `rc=0` 变 `rc=1` + dmesg `rejected arg token "abc" -> -EINVAL`；三服务恢复、对账一致、smoke §9 绿 | `/root/backups/pfanctl-rebuild-20261008-211619/` |

⚠️ 现场教训：`systemctl stop pfanctl` 之后 `systemctl start pfanctl` 那一步没起来，
靠手工 `insmod /opt/pfanctl/pfanctl.ko` 才装载成功（回滚分支当时装回了旧 `.ko`）。
单元本身在启动时是好的（`systemctl status` 显示开机那次 ExecStart SUCCESS）——
`start` 失败的真实原因**未查明**，下次重载前先单独复现 `systemctl start pfanctl`。
