# 安全说明 / Security Policy

本仓库控制**物理风扇**（Panasonic CFQV8，ACPI `TFN1._FSL` + EC `0x76`），
由一个**以 root 运行的内核模块**承载 ACPI 求值。安全模型围绕这一点设计。

## 信任边界

| 路径 | 暴露方式 | 状态 |
|---|---|---|
| `http://192.168.1.10:8789/pfan` | ufw 仅放行 `192.168.1.0/24` | 读写 |
| `https://pfan.example.com/pfan` | Cloudflare 隧道（公网可达） | 读写 |
| `/dev/pfanctl` | 仅 root 可写 | ACPI 求值入口 |

## 鉴权与 CSRF

- **写接口**（`POST /api/level`、`POST /api/curve` …）**必须**带有效的 `X-Pfan-Token`，
  **无条件** —— Origin 白名单**不能替代** token（旧版是「token 或白名单 Origin」二选一，
  同主机**任意端口**的页面都能免 token 写，已废除；`tests/python/test_http.py` 的
  `test_write_requires_token_even_from_allowed_origin` 钉住这一条）。实测：无 token → **403**；
  **不带 Origin** 的请求（如 curl）只看 token，有效即放行。令牌 30 字节随机数，
  文件 `/var/lib/pfanel/token`，`600 root:root`。
- **读接口**（`/api/now`、`/api/curve`、`/api/events`）**免鉴权，这是有意的**：
  它们只返回本机温度/档位/历史，不含任何凭据。不要往这些字段里塞密钥。
- **Origin 白名单**（`PFAN_ORIGIN_ALLOW`，默认 `pfan.example.com,127.0.0.1,localhost,192.168.1.10`）
  是 token 之上的**第二道门（纵深防御）**：请求**带了** `Origin` 时还必须在白名单里，否则 403。
  白名单**只比对主机名**（scheme 与端口一律忽略）—— 这正是它不能当鉴权用的原因，
  也是旧版二选一规则的漏洞所在。白名单值由 `tests/python/test_http.py` 断言等于生产值，
  改配置是可选的。
- **不发 CORS 头**。面板与 API 同源，通配 `Access-Control-Allow-Origin: *` 只会让
  LAN 内任意网页跨域读遥测 —— 已移除，`scripts/smoke.sh` 2b 段守着。

## 权限

三个服务（`pfanctl` / `pfand` / `pfanel`）**都以 root 运行**，这是必需的：
访问 `/dev/pfanctl`、加载内核模块、写 `/etc/pfand.conf` 都需要特权。

> `/dev/pfanctl` 接受**用户态给出的任意 ACPI 路径 + 整数参数**并求值。
> 因此对该设备的写权限等价于 root —— 它本就是 root-only（`600`，misc 设备默认权限）。
> 不要把它改成 world-writable。

## 数据与日志

- 无 PII，无凭据入库或入日志。
- `/var/lib/pfanel/pfanel.db`（644）只存温度/档位采样与事件；`/etc/pfand.conf`（644）只存曲线参数。
- 唯一的秘密是 token（600）。
- `/var/log/pfand.log` 与 `/var/log/pfanel.log` 由 logrotate 每日轮转、保留 7 份
  （`deploy/logrotate.d/pfan`）。两份配置都必须是 **`copytruncate`**：pfand/pfanel 都用 `>>`
  追加且没有信号处理，普通轮转会让它的 fd 继续指向被移走的文件，之后的日志全部丢失。

## 已知并接受的限制

- 面板**公网可达**（Cloudflare 隧道）。读接口不鉴权意味着公网可读本机温度/风扇状态 ——
  对一台家用风扇控制台是可接受的；如果你的场景不能接受，关掉隧道即可。
- token 是**静态 bearer**，无过期、无轮转。对单机 LAN 设备可接受，不是多租户方案。
- 服务以 root 运行，任一服务被攻陷 = 主机被攻陷。缓解手段是上面的网络与 CSRF 边界。

## Supported Versions（GitHub 安全页需要这一节才能渲染）

| 版本 | 状态 |
|---|---|
| `main`（滚动） | ✅ 接收报告 |
| 任何已发布的 tag | ❌ 不再维护（项目尚无发布版） |

## 漏洞报告

**请用 GitHub 的私密漏洞报告，不要开公开 issue。**
仓库页 → **Security** 标签 → **Report a vulnerability**（需登录）。
若该功能未启用（仓库未开启 private vulnerability reporting，或你不愿登录），
请通过仓库 owner 的私有渠道联系。

**不要在公开 issue / 讨论 / PR 里贴可直接利用的细节** —— 这台设备以 root 运行，
`/dev/pfanctl` 接受任意 ACPI 路径与整数参数并求值，对它的写权限等价于 root
（见上文「权限」）。公开一份可用的利用细节，等于把它交给任何读到它的人。
等 maintainer 确认已发布修复后再公开细节。

**报告里值得包含的**（不必等你确认可复现）：

- 你的机型 / BIOS 版本 / `uname -r`，以及 `modinfo /opt/pfanctl/pfanctl.ko | grep vermagic`
- 复现步骤与观察到的行为（`/var/log/pfand.log` 相关片段、`/api/now` 的输出）
- 哪一条信任边界被绕过：token 检查、Origin 白名单、`/dev/pfanctl` 权限、还是 ufw/CF 配置

**不必包含**：可用的 payload、真实的 token 值、他人主机的地址。

## 参考

- `docs/OPERATIONS.md` —— 部署、模块重载与 `/dev/pfanctl` 节点风险
- `docs/specs/2026-10-06-pfan-design.md` —— 设计与 backlog 裁决
