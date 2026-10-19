# Operations

面向**已经部署本项目的机器**的操作记录。改任何一条之前先读这一节。

> 标注约定：**[未验证]** = 该陈述**无法从本仓库核实**（目标机状态、Cloudflare 侧配置、
> 历史恢复点、现场时间线），执行前请先在目标机上核对；没有标注的条目均已逐条对照
> 仓库内源码（`scripts/`、`systemd/`、`server/`、`core/`）核实，2026-10-07。

## 拓扑

- 控制面板后端 `pfanel` 监听 `0.0.0.0:8789`
  （核实：`server/pfanel.py` `_PORT = PFAN_PORT` 缺省 8789、`Server(("0.0.0.0", _PORT), H)`）
- 公网入口 `https://pfan.example.com/pfan`（占位域名，不代表任何真实部署）
  —— **[未验证]** 「Cloudflare 隧道 → 本机回环，不经 ufw 外部 INPUT」这半句的隧道配置在
  CF 侧，仓库内只能核实到 `scripts/smoke.sh` 对 `PFAN_API_BASE`（默认即该占位域名）的 GET 断言。
- 开发/运维入口：SSH
  - 别名：`~/.ssh/config` 里 `Host 192.168.1.10 fanhost`（`User <deploy user>`、
    `IdentityFile ~/.ssh/pfan_deploy_key`、`IdentitiesOnly yes`）
  - 脚本**不用**别名：`scripts/deploy.sh` / `scripts/smoke.sh` 读
    `${PFAN_USER:-pfan}` + `${PFAN_HOST:-192.168.1.10}`，密钥走 `-i ~/.ssh/pfan_deploy_key`；
    换机器用 `PFAN_HOST`（部署账号用 `PFAN_USER`）覆盖。文档里的地址是 RFC1918 占位值，
    真实部署必须显式设置这两个变量

## 常用检查

```bash
bash scripts/ci.sh                # 开发机：静态检查 + 全部测试（= npm test）
bash scripts/smoke.sh             # 实机只读冒烟；SSH 不可达直接 exit 1，从不 skip
PFAN_HOST=<ip> PFAN_USER=<user> bash scripts/smoke.sh   # 换目标机/账号
PFAN_API_BASE=https://<your-host> bash scripts/smoke.sh # 公网入口（§3）另配
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
   运行单元 / 加载器 / logrotate（带 `logrotate -d` 自检）/ 面板 7 文件（4 主文件 + 3 vendor）
   / 2 个曲线预设（`/opt/pfanctl/presets/`）
4. 重启 `pfanel`、`pfand`，4b 段轮询等控制回路接管（`pfand=active` 且 `level>=1`，最多 30s）
5. 实机 `bash scripts/smoke.sh`

> ℹ️ 暂存名（**已于 2026-10-08 修复**）：`core/pfan` 与 `deploy/logrotate.d/pfan`
> 都叫 `pfan`，落到同一路径会互相覆盖 —— 后果是把 logrotate 规则装成
> `/usr/local/bin/pfan`、把 CLI 装成 `/etc/logrotate.d/pfan`，而暂存后 `ls` 看不出来。
> 传输早已不用 `scp`（本机 scp 对该目标静默失败），改走 tar-over-ssh。
> 现在的机制：`S()` 对 `deploy/` 开头的路径**保留子目录**，所以它落在
> `$STAGE/deploy/logrotate.d/pfan`（与 `$STAGE/pfan` 天然不撞），随后再把 CLI
> 改名成 `$STAGE/pfan-cli`。守卫见 `test_repo_hygiene` T7 与 T16。
>
> ⚠ 本页此前把这条写成"$STAGE/logrotate-pfan"并归给 `b0ac675`——那个名字在仓库里
> 从不存在，`b0ac675` 是 vendor 修复；暂存名修复是 `b5b4de4`。已订正。
> 本页此前的「deploy.sh 有待修缺陷」警告已随修复移除。

### 回滚

`deploy.sh` 只备份、不提供一键回滚；恢复点路径打印在脚本结尾。

**部署会在恢复点不完整时直接中止**：`deploy/check-recovery-point.sh` 逐个核对的是
第 3 步会**覆盖**的 **18 个路径** —— 5 个二进制（`/usr/local/bin/` 下）、logrotate
规则、`platform.sh` 与它的 example 副本（`/usr/local/lib/pfan/`）、`fan-candidates.txt`、
面板 7 文件（4 主文件 + 3 vendor）、2 个曲线预设。判据是「文件在部署前【存在于机器上】、
恢复点里却没有」：机器上本来就不存在的文件（首台机器上的面板、尚未装过的预设）不算缺；
但 18 个里凡是应当备份的少一个，`PRESENT` 就小于 `EXPECTED`，部署在安装之前中止。所以
deploy 正常跑完时，**每一个部署前存在、且第 3 步会覆盖的路径都在恢复点里**。核对脚本、
第 3 步安装清单与第 1 步备份清单三方由 `test_repo_hygiene` T16/T16b 逐条对钉，任何一方
单独漂移都会转红。

> ⚠ 上下文（2026-10-18）：上面这个保证在当天之前并不成立 —— 核对脚本只查 10 个路径
> （面板 7 + logrotate + platform.sh + fan-candidates），5 个二进制与 2 个曲线预设
> 根本没查，而 deploy 照常打印「已确认落地 10/10 个关键路径」。presets 于 `99ddc9a`
> 进入 deploy.sh 时，核对脚本从未跟动。现已扩到 18 个（含 R-10 新增的 example 副本）
> 并加了三方对钉守卫。

两个**不在核对范围**的路径（也因此恢复点里可能多出一个文件）：

- `/etc/pfan/platform.conf` —— 只在缺失时由 example 建立，部署不覆盖它，所以也不
  备份、不核对；它在恢复点里【不存在】是正常的。
- `<面板目录>/pfan.html` —— 旧版遗留的单文件面板，deploy 不再安装它；机器上若还
  留着，备份循环会顺手把它拷进 `$B/`，所以它【可能】出现在恢复点根下，但缺它不算缺。

恢复点的布局是**混合**的，因为备份分两批（与核对脚本里的 `flat`/`parents` 布局一一对应）：

```
$B/pfand  $B/pfan  $B/pfanel.py  $B/pfan_platform.py  $B/pfan_core.py  [$B/pfan.html]
   ↑ 5 个二进制用 cp -a 落在 $B 根（[ ] 内是旧版遗留件，机器上存在才备份，不核对）
$B/etc/logrotate.d/pfan   $B/etc/pfan/fan-candidates.txt
$B/usr/local/lib/pfan/platform.sh   $B/usr/local/lib/pfan/platform.conf.example
$B/opt/pfanctl/presets/pfan.conf.cool-quiet  $B/opt/pfanctl/presets/pfan.conf.performance
$B/opt/beszel/beszel_data/{index.html,styles.css,app.js,core.js,vendor/uPlot.*}
   ↑ 其余 13 个用 cp -a --parents，保留完整路径
```

手工回滚（布局核对自一次 `pfan-deploy-<timestamp>` 恢复点的实际内容，
并已在目标机实操验证 —— 不再是 [未验证]）：

```bash
B=/root/backups/pfan-deploy-<ts>            # deploy 结尾打印的那个

# ① 先核对恢复点真的齐（deploy 部署时跑过，这里可以再确认一次）。
#    脚本随仓库走：deploy/check-recovery-point.sh；它必须【在目标机上】运行 ——
#    查的是目标机的绝对路径。把仓库里那份经 stdin 递过去：
#      sh deploy/check-recovery-point.sh --list      # 本地演练：打印核对范围，不碰文件系统
#      ssh fanhost "sudo -n sh -s $B /opt/beszel/beszel_data" < deploy/check-recovery-point.sh
#    第二个参数是面板目录，取自目标机 /etc/pfan/platform.conf 的 PANEL_DIR。
#    EXPECTED N / PRESENT M 两者必须相等；不等就别回滚，先查为什么

# ② 二进制
sudo -n cp -a "$B"/pfand "$B"/pfan "$B"/pfanel.py "$B"/pfan_platform.py "$B"/pfan_core.py /usr/local/bin/

# ③ 其余按 --parents 布局原样还原（这是 2026-10-09 之前漏掉的部分：
#    面板 + logrotate 规则 + platform.sh + fan-candidates.txt；`$B/opt/.`
#    还覆盖 2 个曲线预设 —— 它们从 2026-10-18 起也在核对范围内）
sudo -n cp -a "$B"/etc/.   /etc/
sudo -n cp -a "$B"/usr/.   /usr/
sudo -n cp -a "$B"/opt/.   /opt/

# ④ 重启并复验
sudo -n systemctl restart pfanctl pfand pfanel
bash scripts/smoke.sh          # 回滚后必须全绿
```

⚠ **内核模块不在恢复点里**，而且 `deploy.sh` 也不碰它 —— 模块重建与重载是独立
流程，见下一节。若一次部署同时换了模块，得单独按那节回退。

⚠ 上面第 ① 步的脚本随仓库走（`deploy/check-recovery-point.sh`）；deploy 暂存区里
那份部署成功后随暂存区一起清理。`--list` 的输出就是它核对的**全部 18 个路径** ——
手工核对请对照它，不要再手抄一份清单（手抄正是 2026-10-18 之前漏掉二进制与预设的原因）。

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

1. `scripts/sanitize.sh` **已实现且通过**（rc=0，5 条规则 / 13 条豁免 / 30 处被锚定的出现），
   但覆盖面比本条原先列的窄 ——
   **token、记忆文档、`audit/`、隧道 UUID 无对应规则**（规则全清单与理由见本节末「发布门的覆盖范围」）。
2. LAN 地址**未删除、已逐条豁免**（`scripts/sanitize.allow` 第 4 组「私网地址」）：本文档 6 处，
   外加 `scripts/smoke.sh` 与 `scripts/deploy.sh` 各 1 处（`PFAN_HOST` 缺省值，两处必须一致）
   等，共 27 处、11 个文件（完整清单用 `bash scripts/sanitize.sh --allow-list` 反查）。
   公开前脱敏（2026-10-19）已把真实地址整体替换为 RFC1918 占位值，保留占位值是为了让
   脚本缺省、文档示例、测试断言三处字面量同源；这是「有意的保留」而不是遗漏，理由见末注。
   豁免锚在**那一行的内容**上而不是行号上，所以这里刻意不写行号 ——
   写了就会在下次改这份文档时过期。
3. `server/pfanel.py` 的 Origin 白名单已配置化（backlog ②⑤），不再硬编码 IP
   —— **状态：已完成**（`PFAN_ORIGIN_ALLOW` 环境变量可覆盖；
   缺省 `DEFAULT_ORIGINS` 仍含 LAN 占位地址，属预期缺省；测试断言字面量与代码默认值一致）

在 1、2 未全部满足前，**不得**把仓库改为 public。

## 内核模块 `pfanctl.ko` 的重建与重载

**构建**（`/opt/pfanctl/Makefile` 只是 kbuild 片段，不能直接 `make` ——
核实：仓库 `core/pfanctl/Makefile` 只有一行 `obj-m := pfanctl.o`，直接 `make` 报
`make: *** No targets.  Stop.`）：

```bash
cd /opt/pfanctl
sudo make -C /lib/modules/$(uname -r)/build M=/opt/pfanctl modules
```

> ⚠ **内核自动升级后必须先删中间产物**，否则上面这条命令什么也不做：
> `make` 按时间戳判断，源码没变 → 认为 `.ko` 是最新的 → 跳过重建 →
> `.ko` 的 `vermagic` 仍是旧内核的 → `insmod` 报 `Invalid parameters`。
> 这正是 2026-10-09 21:48 那次故障的成因（机器自动升到 `6.8.0-146-generic`，
> `.ko` 还是为 `6.8.0-142-generic` 编的）。当时上面这条命令跑完毫无反应，
> vermagic 原封不动。正确做法：
>
> ```bash
> sudo rm -f /opt/pfanctl/pfanctl.ko /opt/pfanctl/pfanctl.o \
>            /opt/pfanctl/pfanctl.mod.c /opt/pfanctl/pfanctl.mod.o \
>            /opt/pfanctl/modules.order /opt/pfanctl/Module.symvers
> sudo make -C /lib/modules/$(uname -r)/build M=/opt/pfanctl modules
> sudo modinfo /opt/pfanctl/pfanctl.ko | grep vermagic     # 必须等于 uname -r
> ```
>
> `smoke.sh` §9b 现在会核对 `vermagic` 与 `uname -r` 是否一致 —— §9 的时间戳检查
> 对「新拷贝的 .ko」完全满意，而那正是升级后最可能出现的状态。

> `deploy.sh` **不同步** `/opt/pfanctl`（传输清单里没有 `pfanctl.c`/`Makefile`），
> 所以目标机 `/opt/pfanctl` 以机器为准 —— **这条不再是"需现场核对"，`smoke.sh` §9 每次
> 都会比对**：（a）仓库与目标机 `pfanctl.c` 的 sha256，（b）`.ko` 是否早于 `.c`
> （早于 = 源码改过但没重新编译，现役模块仍是旧行为）。两项任一不符即报红，
> 守卫见 `tests/shell/test_repo_hygiene.sh` T9。
>
> 同步源码但**不**自动重建（重建涉及 rmmod 窗口，必须人来决定时机）：
>
> ```bash
> scp -i ~/.ssh/pfan_deploy_key core/pfanctl/{pfanctl.c,Makefile} <deploy user>@192.168.1.10:/tmp/
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

### ⚠️ `Requires=` 级联：动 `pfanctl` 单元 = 动整个控制栈

```
pfand.service   Requires=pfanctl.service   After=pfanctl.service
pfanel.service  Requires=pfanctl.service   After=pfanctl.service
```

`systemctl stop pfanctl` 会**连带停掉 pfand 与 pfanel**（systemd 的 `Requires` 在停止方向
传播）。反过来 `systemctl start pfanctl` **不会**把它们拉起来 —— 于是"只是动一下 pfanctl
单元"很容易留下一个**风扇失控但看起来一切正常**的状态：模块在、节点在、`pfanctl` active，
而真正的闭环守护是停的。

**2026-10-08 22:06 实例**：为了查一个 `start` 失败，我做了 `stop pfanctl → start pfanctl`
的实验，并只复核了 pfanctl/模块/节点三个对象 —— pfand/pfanel 此后停了约 30 分钟，
直到 `smoke.sh` §1 报 `active=inactive` 并由 pre-push 钩子拦下推送才发现（当时机器空闲
47°C、风扇保持最后 40 档，无热风险；若在负载下就是真实过热）。

**规程（做任何涉及 pfanctl 单元的操作后必须全量复核）**：

```bash
for s in pfanctl pfand pfanel; do systemctl is-active $s; done   # 必须三个都 active
curl -fsS --max-time 5 http://192.168.1.10:8789/api/now | jq -c '{temp,level,mode}'
# level>=1 且 mode=daemon 才算闭环真正在跑；只看服务状态不够
```

`smoke.sh` §1/§2 就是这个检查，**改动后不要跳过它**（这次正是它把推送拦住的）。

### 重建履历

| 日期 | 触发 | 结果 | 恢复点 |
|---|---|---|---|
| 2026-10-08 21:16 | 审计 F5/M11/M12/M13 落地后源码领先现役 `.ko`（坏 token → 静默 0 → `_FSL 0` 停转；`argc>INT_MAX` → 内核栈越界读） | 编译 2 条既有 warning（缩进/帧大小，与 10-06 同）；先编译后重载；`_FSL 1 abc` 从 `rc=0` 变 `rc=1` + dmesg `rejected arg token "abc" -> -EINVAL`；三服务恢复、对账一致、smoke §9 绿 | `/root/backups/pfanctl-rebuild-20261008-211619/` |

⚠️ 现场教训（2026-10-08）：`systemctl stop pfanctl` → rmmod → `systemctl start pfanctl`
那一步失败（回滚分支因此装回了旧 `.ko`，新模块最终靠手工
`insmod /opt/pfanctl/pfanctl.ko` 才装载成功，那次 rc=0、未触发回滚）。

**复现结论：单独复现不出来。** 随后做了零影响实验——模块与节点全程不动，只
`systemctl stop pfanctl` → `start`，连做两次都是 `rc=0`、stderr 为空、模块在册、
节点仍是字符设备。所以失败与"紧接着 rmmod"这一上下文相关，具体原因**仍未查明**。

因此重载规程的落地写法固定为：`start` 失败就直接手工 `insmod`，不要停在半路 ——

```bash
sudo -n systemctl start pfanctl || sudo -n insmod /opt/pfanctl/pfanctl.ko
stat -c '%F %a' /dev/pfanctl     # 必须是 character special file 600
```

（`insmod` 失败才回滚：`sudo -n insmod /root/backups/pfanctl-rebuild-<ts>/pfanctl.ko`）

## 发布门的覆盖范围（2026-10-10 核实）

`bash scripts/sanitize.sh --list` 是唯一的事实源 —— 它打印的就是扫描时用的那份，
不是散文。当前编译出 **5 条规则**：私钥路径、macOS 用户目录、自有域名、
带用户名的远端目标（account + host，含邮箱形态）、私网地址。另有 13 条豁免（共 30 处出现），
在 `scripts/sanitize.allow` 里逐条钉死「文件 + 那一行内容的 sha256 指纹」并写了理由。
2026-10-19 公开前脱敏之后，私钥路径与自有域名两类在本仓库已 0 命中（真实值已换成
通用占位名与 RFC 2606 保留示例域名），带用户名远端目标的 3 处只存在于历史计划/设计
文档；仍逐条豁免的私网地址 27 处全部为 RFC1918 占位值。

**豁免为什么钉内容而不钉行号**（2026-10-16 改）：行号会被它上面的任何一次编辑挪动，于是
任何无关的改动都会把门变红 —— 本分支上因为三处互不相关的改动红过三次，每次的修法都是手工
重锚，而重锚正是「悄悄把覆盖面放大」的时机。指纹认内容：上下移动都不必改清单，而同一文件里
新写的同类内容仍然照拦（`tests/shell/test_repo_hygiene.sh` 的 T25e/T25f 双向钉住这两头）。
清单仍然【一份都不少】：13 条全部提交、逐条必要（删掉任何一条门就红）。
`bash scripts/sanitize.sh --allow-list` 是反向视图，把每条豁免当前放行的 `文件:行号` 逐条印出来，
改完某一行之后照它重新取指纹即可，不必手工数行。

**门扫不到的**（发布前须人工过一遍）：

- **token** —— 没有对应规则。`/var/lib/pfanel/token` 的值若被提交，门不会拦。
- **记忆文档 / `audit/`** —— 没有对应规则。它们的路径里没有本门认识的那五类特征。
- **隧道 UUID** —— 没有对应规则。目前仓库里也不存在 UUID 字面量，所以「没规则」
  暂时不构成实际暴露；一旦写进去，门不会拦。

**LAN 地址为什么以占位值保留**：公开版本里这些地址全部是 RFC1918 占位值（真实地址已从
全部受控内容中移除，不存在于本仓库）。保留占位值是为了三处字面量同源、开箱可跑：
`scripts/smoke.sh` 的 `PFAN_HOST` 缺省值必须与 `scripts/deploy.sh` 的那个一致，否则冒烟探的
是另一台机器；文档示例与测试断言也锚在同一组字面量上。真实部署必须显式设置
`PFAN_HOST` / `PFAN_USER`（见 README「Deploy」）。这是「故意留下的占位值」，
不是遗漏 —— 判断依据是 `scripts/sanitize.allow` 第 4 组逐条写着的理由。
