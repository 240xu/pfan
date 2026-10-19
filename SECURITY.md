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

- **写操作不带有效的 `X-Pfan-Token` 一律 403，且判定是**无条件**的** —— Origin 白名单
  **不能替代** token（旧版是「token 或白名单 Origin」二选一，同主机**任意端口**的页面都能免
  token 写，已废除；`tests/python/test_http.py` 的 `test_write_requires_token_even_from_allowed_origin`
  与 `test_tokenless_post_has_no_server_side_effect` 钉住这一条）。**不带 Origin** 的请求（如 curl）
  只看 token，有效即放行。令牌是 `secrets.token_urlsafe(32)` —— **32 随机字节、43 个字符**，
  存于 `/var/lib/pfanel/token`（`600 root:root`）。⚠️ **但它不是身份认证** —— 见下一节。
- **读接口全部免鉴权，这是有意的**：`/api/now`、`/api/curve`、`/api/events`、`/api/history`、
  `/api/params`、`/api/profile`、`/api/mode`、`/api/levels`，以及 `/pfan`、`/pfan.js` 等静态件。
- **Origin 白名单**（`PFAN_ORIGIN_ALLOW`，默认 `pfan.example.com,127.0.0.1,localhost,192.168.1.10`）
  是 token 之上的**第二道门（纵深防御）**：请求**带了** `Origin` 时还必须在白名单里，否则 403。
  白名单**只比对主机名**（scheme 与端口一律忽略）—— 这正是它不能当鉴权用的原因，
  也是旧版二选一规则的漏洞所在。白名单缺省字面量由 `tests/python/test_http.py` 断言，
  改配置是可选的。
- **不发 CORS 头**。面板与 API 同源，通配 `Access-Control-Allow-Origin: *` 只会让
  LAN 内任意网页跨域读遥测 —— 已移除，`scripts/smoke.sh` 2b 段守着。

### 写边界究竟是什么：token 不是身份认证

上面那条 token 判定**是真的**，但把它当成「谁能写」的判据是错的：

- **面板自己就要用这个 token。** `panel/app.js:11` 写的是占位符 `__PFAN_TOKEN__`，
  `pfanel.py` 的 `_panel()` 把它替换成真值，而 `/pfan`、`/pfan.js` 是**免鉴权 GET**。
  于是「持有有效 token」对任何能访问面板的人都是现成的 —— **非浏览器客户端（curl）一次
  GET 就有了**，不需要任何凭据。
- 理由是一句话：**任何由客户端自己提交的 HTTP 门都能被 curl 满足**，`Origin` 与 `Host`
  同样是自己写的。脚本客户端唯一伪造不了的东西是**一个从未被传输的秘密**，而这个秘密
  被发到了公网上。**应用层不认证任何人。**
- 写操作**也不按 URL 分派**：`do_POST` 从不读 `self.path`，写哪一项由 **JSON body 的键**决定
  （`params` / `profile` / `hold` / `auto` / `level`），**任意路径**都能触发写操作。
  文档里常见的 `POST /api/level` 是客户端的习惯，不是服务端承认的路由。
- 读接口只返回本机温度/档位/历史，不含任何凭据 —— 不过 `/api/params` 会回 `conf`（即
  `/etc/pfand.conf` 的**绝对路径**）、`/api/profile` 会回 `guard_temp`。两者都不是秘密，但它们
  **公网上任何人可读**，所以不要往这些字段里塞任何不能公开的东西。

### 仍然成立的边界（不要因为上一节就把整个安全模型当成假的）

- **Origin 白名单是真实有效的浏览器 CSRF 边界。** 跨源页面发起的 `fetch` / `<form>`
  必然带上 `Origin`，而 `Origin` 由浏览器强制注入、脚本伪造不了。所以它挡的是
  「别的网站骗你的浏览器来写档位」；它挡不住「对方自己拿 curl 来写」。这是它的真实范围，
  也是它值得留下的原因 —— 只是它不是身份认证。
- **不发 ACAO** 阻止跨源**读取**遥测：没有 `Access-Control-Allow-Origin`，
  别的网页即使能把请求发出去，也读不回响应体。
- **`ufw`** 使 8789 仅 LAN 可达（放行规则见「信任边界」表与 `docs/OPERATIONS.md`）。
  注意这是目标机上的一次性规则，**不由 `scripts/deploy.sh` 下发** —— 换机器重装时必须手工
  补上，否则面板监听 `0.0.0.0:8789` 会暴露在公网入口上。
- **`guard()` 的 82 °C 上限**（`GUARD_TEMP`）是写路径危害的**实际天花板**：
  受管曲线下温度达到阈值就自动回退到 `auto`。所以即便写操作被拿到，后果是**过热**，
  而不是通过 `/dev/pfanctl` 任意 ACPI 求值。`GUARDED` 含 `free` —— 自由模式同样被接管。

> **一句话的真实模型：隧道的可达性就是边界；应用层不认证任何人；兜底的是 `guard()`。**

## 权限

三个服务（`pfanctl` / `pfand` / `pfanel`）**都以 root 运行**，这是必需的：
访问 `/dev/pfanctl`、加载内核模块、写 `/etc/pfand.conf` 都需要特权。

> `/dev/pfanctl` 接受**用户态给出的任意 ACPI 路径 + 整数参数**并求值。
> 因此对该设备的写权限等价于 root —— 它本就是 root-only（`600`，misc 设备默认权限）。
> 不要把它改成 world-writable。

## 数据与日志

- 无 PII，无凭据入库或入日志。
- `/var/lib/pfanel/pfanel.db`（644）只存温度/档位采样与事件；`/etc/pfand.conf`（644）只存曲线参数。
- 唯一算秘密的是 token，**文件模式**是 600（`/var/lib/pfanel/token`）。但它的**分发**不是：
  见「鉴权与 CSRF」一节，它随免鉴权的 `/pfan.js` 交到任何来访者手里。
  换句话说，这个秘密的秘密性来自访问控制，不来自密码学。
- `/var/log/pfand.log` 与 `/var/log/pfanel.log` 由 logrotate 每日轮转、保留 7 份
  （`deploy/logrotate.d/pfan`）。两份配置都必须是 **`copytruncate`**：pfand/pfanel 都用 `>>`
  追加且没有信号处理，普通轮转会让它的 fd 继续指向被移走的文件，之后的日志全部丢失。

## 已知并接受的限制

- 面板**公网可达**（Cloudflare 隧道）。读接口不鉴权意味着公网可读本机温度/风扇状态 ——
  对一台家用风扇控制台是可接受的；如果你的场景不能接受，关掉隧道即可。
- token 是**静态 bearer**，无过期、无轮转。**「对单机 LAN 设备可接受」这个结论以 token 保密
  为前提** —— 而它并不保密（任何能 `GET /pfan.js` 的人都能拿到，见上文）。所以在隧道开着、
  面板公网可达的现实里，成立的结论是：**边界在隧道的可达性，不在应用层**。
  要收紧就关掉隧道、只留 LAN，别把这个 token 当成可以依赖的东西。
- 服务以 root 运行，任一服务被攻陷 = 主机被攻陷。缓解手段是上面的网络与 CSRF 边界。

## Supported Versions（GitHub 安全页需要这一节才能渲染）

| 版本 | 状态 |
|---|---|
| `main`（滚动） | ✅ 接收报告 |
| 任何 tag | ❌ 不接受报告 —— 仓库里的 `p0-net` / `p1-platform` / `p2-backlog` 是**内部阶段标记，不是发布版**，没有 SemVer 版本 |

## 漏洞报告

**请用 GitHub 的私密漏洞报告，不要开公开 issue。**
仓库页 → **Security** 标签 → **Report a vulnerability**（需登录）。
若该功能未启用（仓库未开启 private vulnerability reporting，或你不愿登录），
请通过仓库 owner 的私有渠道联系。

**不要在公开 issue / 讨论 / PR 里贴可直接利用的细节** —— 这台设备以 root 运行，
`/dev/pfanctl` 接受任意 ACPI 路径与整数参数并求值，对它的写权限等价于 root
（见上文「权限」）。公开一份可用的利用细节，等于把它交给任何读到它的人。
这条说的是**设备** —— root 等价的是 `/dev/pfanctl` 这个节点，不是面板 HTTP 接口；
面板本身已经公网可达、边界也已在上文写明，不靠保密来保护。
等 maintainer 确认已发布修复后再公开细节。

**报告里值得包含的**（不必等你确认可复现）：

- 你的机型 / BIOS 版本 / `uname -r`，以及 `modinfo /opt/pfanctl/pfanctl.ko | grep vermagic`
- 复现步骤与观察到的行为（`/var/log/pfand.log` 相关片段、`/api/now` 的输出）
- 哪一条信任边界被绕过：token 检查、Origin 白名单、`/dev/pfanctl` 权限、还是 ufw/CF 配置

**不必包含**：可用的 payload、真实的 token 值、他人主机的地址。

## 参考

- `docs/OPERATIONS.md` —— 部署、模块重载与 `/dev/pfanctl` 节点风险
- `docs/specs/2026-10-06-pfan-design.md` —— 设计与 backlog 裁决
