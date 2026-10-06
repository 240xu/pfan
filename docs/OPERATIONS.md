# Operations

面向**已经部署本项目的机器**的操作记录。改任何一条之前先读这一节。

## 拓扑

- 控制面板后端 `pfanel` 监听 `0.0.0.0:8789`
- 公网入口 `https://pfan.example.com/pfan`（Cloudflare 隧道 → 本机回环，不经 ufw 外部 INPUT）
- 开发/运维入口：SSH（目标机别名见本工作区 `~/.ssh/config`）

## 防火墙（读接口未鉴权的前提条件）

`pfanel` 的**读接口有意不鉴权**（见 `SECURITY.md` / backlog ②）。因此 8789 **绝不能**对公网开放，
只能放行本机 LAN 子网：

```bash
ufw allow from 192.168.1.0/24 to any port 8789 proto tcp comment "pfan panel LAN"
```

验证：

```bash
ufw status | grep 8789
# 8789/tcp    ALLOW    192.168.1.0/24    # pfan panel LAN
curl -fsS http://<host>:8789/api/now | jq .
```

变更前的规则备份（本机）：`/root/backups/pfan-ufw-<timestamp>/{user.rules,user6.rules,status.after.txt}`

> ⚠️ **不要**用 `ufw allow ... port 8789 proto tcp`（不带 `from`）—— 那等于对 Anywhere 开放未鉴权遥测。

## 曲线参数的权威源

- 权威文件：目标机 `/etc/pfand.conf`（由面板「自定义曲线」按钮原子写入）
- 仓库副本：`config/pfand.conf.example`
- `scripts/smoke.sh` 第 4 段对两者做**整文件 sha256 比对**；不一致即报红

改曲线参数的正确路径：面板 `/api/params` → 仓库副本随之同步 → smoke 校验一致。
**不要**只在机器上手改，否则下次 smoke 必红。

## 服务

| 单元 | 说明 |
|---|---|
| `pfanctl.service` | 幂等 insmod `pfanctl.ko` |
| `pfand.service` | 温度→档位闭环，`Restart=on-failure`，**只在曲线=`s0i3` 时接管** |
| `pfanel.service` | HTTP 面板后端，`Restart=always` |

恢复点：`/root/backups/pfanfix-<timestamp>/`（第一批修复的全量回滚）、`/root/backups/pfan-ufw-*/`。

## 发布前置条件（P3 才执行）

本仓库**即将公开**。翻转 visibility 之前必须满足：

1. `scripts/sanitize.sh` 已实现且通过（扫描隧道 UUID、LAN IP、token、私钥、记忆文档、`audit/`）
2. 本文档与 `scripts/smoke.sh` 中的 LAN 子网已按 sanitize 规则处理
3. `server/pfanel.py` 的 Origin 白名单已配置化（backlog ②⑤），不再硬编码 IP

在上述三条未全部满足前，**不得**把仓库改为 public。
