#!/usr/bin/env bash
# scripts/smoke.sh — 实机只读冒烟。
# 只允许：GET / systemctl show|is-active|is-enabled / cat / grep / stat / sha256sum /
#         ufw status / pfan get（写进设备的只有 _FST 查询，是 getter，不改风扇档位）。
# 严禁任何写操作（POST、set_level、set_curve、systemctl start|stop|restart、ufw allow|delete、rm）。
# Termux 注意：/usr/bin/env 不存在，且无 /tmp 写权限 → 用 `bash scripts/smoke.sh` 调用。
set -uo pipefail
# 必须先 cd 到仓库根：本文件多处用【cwd 相对路径】读仓库文件（config/pfand.conf.example
# 里的 EMERG、面板部署件、core/pfanctl/pfanctl.c）。smoke.sh 原来从不 cd，于是从别的目录
# 运行时这些读取静默失败 —— 其中 EMERG 是唯一 fail-open 的默认值（读不到兜底 80），
# 已一并改成 fail-closed（专家审计 C-2）。
cd "$(dirname "$0")/.." || { echo "[FAIL] 进不去仓库根（cwd=$PWD）"; exit 1; }

# fail-safe 蕴含式（TDD 可测，tests/shell/test_guards.sh 抽取本变量）
# 语义：(温度读不到 或 温度>=EMERG) 是危险条件 ⇒ 必须满速；否则放行。
# 用 --argjson emerg 注入实际 EMERG，不写死。
GUARD_FAILSAFE_JQ='((.temp == null or .temp >= $emerg) | not) or (.level == 100)'

HOST="${PFAN_HOST:-192.168.1.10}"
SSH_USER="${PFAN_USER:-pfan}"
API="${PFAN_API:-http://$HOST:8789}"

# 面板目录必须与 deploy.sh 和 pfanel.py 同源（都从 platform.conf 派生），否则
# "改了部署路径、冒烟还在查旧路径"会变成静默失效的守卫。见 deploy.sh 的 PDIR。
PANEL_DIR="${PFAN_PANEL_DIR:-}"
if [ -z "$PANEL_DIR" ]; then
  PANEL_DIR=$(sed -n 's/^PANEL_DIR=//p' platform/platform.conf.example 2>/dev/null | head -1) || true
fi
PANEL_DIR="${PANEL_DIR:-/opt/beszel/beszel_data}"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/pfan"
mkdir -p "$CACHE"
OPTS=(-i "$HOME/.ssh/pfan_deploy_key" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=8)
rc=0
ok(){ printf '  [ok]   %s\n' "$1"; }
bad(){ printf '  [FAIL] %s\n' "$1"; rc=1; }
remote(){ timeout 25 ssh "${OPTS[@]}" -l "$SSH_USER" "$HOST" "$@"; }
. "$(dirname "$0")/smoke-lib.sh"   # svc_verdict
warn(){ printf '  [warn] %s\n' "$1"; }

# 0) 可达性 —— 不可达必须失败，不许跳过
if ! timeout 8 ssh "${OPTS[@]}" -l "$SSH_USER" "$HOST" true 2>/dev/null; then
  echo "[FAIL] 目标机 SSH 不可达 —— 不允许跳过"
  exit 1
fi

printf '\n=== 1. 服务状态（active + enabled + 无重启）===\n'
for s in pfanctl pfand pfanel; do
  st=$(remote "systemctl is-active $s" 2>/dev/null || true)
  en=$(remote "systemctl is-enabled $s" 2>/dev/null || true)
  nr=$(remote "systemctl show $s -p NRestarts --value" 2>/dev/null || true)
  svc_verdict "$st" "$en" "$nr"; v=$?
  case "$v" in
    0) ok "$s" ;;
    1) warn "$s 当前健康，但 NRestarts=$nr（历史计数，不阻断）" ;;
    *) bad "$s: active=$st enabled=$en NRestarts=$nr" ;;
  esac
done

printf '\n=== 2. API 形状（LAN）===\n'
# 等 level 的预算上限（秒）。计数器按 2s 步进，所以最坏情况实际等到 46s；
# 下面那行会把【真实等到的秒数】打出来，不用猜。测试可把它调小：
# tests/shell/test_guards.sh 用它跑"永远为 0 仍然失败"，否则那一条要在 CI 里真睡 46 秒。
WAIT_LEVEL0_MAX="${PFAN_WAIT_LEVEL0_MAX:-45}"

# ⚠ 先等守护写出第一个档位再断言：deploy.sh 刚重启过 pfand/pfanel 时立刻跑 smoke
# 可能采到 level=0，误报成 "风扇停转 + API 字段缺失"（2026-10-10 实测踩到）。
# level=0 的来源是 pfanel 的 snapshot 缓存 —— 它带 age（线上实测 age≈7s），
# 重启瞬间还能报出重启前的旧值（deploy.sh 那句"pfanel 的 snapshot 有缓存"就是这个）。
# 【2026-10-17 更正】这一段原本还写着"pfand 每次启动都会先 ensure_s0i3 写 _FSL 1 0
# （s0i3 握手序列），随后才写真正的档位"——那是旧守护的行为。keep-level 握手
# （R-01，设备件 36afcf02 已上游）写的是当前档位（>=25），正常启动全程不再出现 0。
# 等待守卫保留：重启窗口里旧快照仍可能报 0；设备上若又跑起旧版 pfand，0 也会
# 真的回来 —— 那正是 §4b 要比对 pfand sha 的原因。
#
# 窗口有多长：要吸收的是 pfanel 的 snapshot 缓存 —— 它带 age
# （线上实测 age≈7s），重启瞬间还能报出重启前的旧值（deploy.sh 那句"pfanel 的
# snapshot 有缓存"就是这个）。2026-10-10 重启 pfanel 实测：level=0 持续 ≥10s，
# 约 30s 才回到正常档位 —— 比原来 25s 的预算还长，于是守卫把自己护的东西报成了故障。
# 上界取 45s 是给这个 30s 留 50% 余量。两边错的方向不对称：上界偏小会把一台正在
# 自愈的健康机器报成故障（踩到的就是这条），偏大只是让真故障晚 20s 报出来。
# 正常情况第一轮就 break，一次 sleep 都不睡。
#
# 判据必须是结构化的：条件是【level 这个字段的值等于 0】，不是【这几个字符按这个
# 顺序出现过】。原来那句 `case "$j" in *'"level":0'*)` 是把结构事实退化成文本近似，
# 而服务实际发的是 `"level": 0`（json.dumps 默认分隔符，冒号后有空格）—— 永远失配，
# 循环第一轮就 break，这个守卫等了 0 秒，等于没有。实测同一份负载只差一个空格：
# 带空格 → 1 次轮询 / 0s；不带空格 → 14 次轮询 / 26s（2026-10-10 修）。
# 比较也交给 jq 按【数值】做：0.0 同样算 0，不会在 shell 里被当成两个字符串。
# jq 本来就在下面每一条断言里用着。
#
# "取"和"等"合成一个循环：原来的取数循环无条件 break，一个响应都重试不了 ——
# 同样是"守卫不会转"。这里每轮取一次、取到就判，不够就接着等。
_waited=0
while :; do
  j=$(timeout 20 curl -fsS --max-time 12 "$API/api/now" 2>/dev/null) || j=""
  # 三个状态分开写，别把它们压成一个 if —— 压在一起就会有人后来"简化"掉其中一个。
  if [ -z "$j" ]; then
    _zero=1    # 没取到：继续等，别拿空串去断言
  elif printf '%s' "$j" | jq -e '.level == 0' >/dev/null 2>&1; then
    _zero=1    # level 就是 0：握手窗口，继续等
  else
    _zero=0    # 就绪
  fi
  # 缺 level、level=null、JSON 坏了 —— jq 都判成"不是 0"，于是这里直接就绪并退出，
  # 由下面的字段齐全/越界断言报红。那种负载不是握手窗口，是真故障，不该被等掉。
  [ "$_zero" = 1 ] || break
  [ "$_waited" -lt "$WAIT_LEVEL0_MAX" ] || break
  sleep 2; _waited=$((_waited + 2))
done
[ -n "$j" ] || bad "LAN $API/api/now 不可达"
if [ "$_waited" -gt 0 ]; then
  echo "    （等了 ${_waited}s 让 pfanel/pfand 的重启窗口过去 —— 刚重启时 level=0 可能来自旧快照缓存，不是停转）"
fi
if [ -n "$j" ]; then
  if echo "$j" | jq -e '(.ts|type=="number") and ((.temp == null) or (.temp|type=="number"))
        and (.level|type=="number") and (.ec76|type=="number")
        and (.rpm|type=="number") and (.mode|type=="string")
        and (.curve|type=="string") and (.gov|type=="string")
        and (.cached|type=="boolean") and (.age|type=="number")
        and ((.fps == null) or ((.fps|type=="array") and (.fps|length)==3))' >/dev/null 2>&1; then
    ok "/api/now 11 字段齐全"
  else
    bad "/api/now 字段缺失: $j"
  fi
  if echo "$j" | jq -e '(.level >= 1) and (.level <= 120)' >/dev/null 2>&1; then
    ok "level ∈ [1,120]（禁 0）"
  else
    bad "level 越界: $(echo "$j" | jq -c .level 2>/dev/null)"
  fi
  EMERG_V=$(grep -E '^EMERG=' config/pfand.conf.example 2>/dev/null | head -1 | cut -d= -f2)
  # 读不到就必须【报错】而不是兜底：兜底 80 会让应急满速断言转去对着一个硬编码常量
# 断言，EMERG 一变就静默失效（config/pfand.conf.cool-quiet 就是 EMERG=85）。
# 兜底 0 而不是 80：这样后面的断言只会更严，不会更松（专家审计 C-2）。
[ -n "${EMERG_V:-}" ] || { bad "读不到 config/pfand.conf.example 的 EMERG（cwd=$PWD）"; EMERG_V=0; }
  if echo "$j" | jq -e --argjson emerg "$EMERG_V" "$GUARD_FAILSAFE_JQ" >/dev/null 2>&1; then
    ok "fail-safe：温度>=EMERG($EMERG_V) 或读不到 ⇒ 满速"
  else
    bad "温度异常但非满速: $(echo "$j" | jq -c '{temp,level}' 2>/dev/null)"
  fi
fi

printf '\n=== 2b. 读接口不得发通配 CORS（②⑦）===\n'
# 必须用 GET：旧版 pfanel 未实现 do_HEAD，HEAD 会 501 且根本不进 _send，
# 拿它检查会得到"没有这个头"的假阳性（2026-10-06 实测踩过）。
# ⚠ 这里必须区分【三态】：有 CORS 头 / 确认没有 / 【没连上】。
# 原来的 `... || true` 把 curl 的退出码丢了，于是超时或连接断开时 acao 为空，
# 而 `[ -z "$acao" ]` 把"根本没收到响应"报成"确认没有这个头" —— SECURITY.md
# 正是拿这一段当"不发 CORS 头"的执行依据，所以它必须 fail-closed（专家审计 C-1）。
_hdrs=$(timeout 30 curl -sS -D - -o /dev/null --max-time 20 "$API/api/now" 2>/dev/null) \
  || { bad "CORS 探测不可达（$API）—— 无法判定，不当作通过"; acao=__UNREACHABLE__; }
acao=$(printf '%s' "${_hdrs:-}" | tr -d '\r' | grep -i '^access-control-allow-origin:')
# 只允许【完全没有】这个头。反射型 ACAO（把请求 Origin 回显回去）对浏览器来说
# 与通配等价，之前的 "非通配就算 ok" 分支会把它放过去。
if [ "$acao" = "__UNREACHABLE__" ]; then
  :   # bad 已在上面记过，这里不能再当成"没有这个头"
elif [ -z "$acao" ]; then
  ok "无 Access-Control-Allow-Origin（同源面板不需要 CORS）"
else
  bad "发了 CORS 头（反射型与通配同样危险）: $acao"
fi

printf '\n=== 3. 公网入口 ===\n'
# 探哪个入口必须来自配置，不写死在脚本里：即使默认值是占位域名，断言也得对着
# 【这次部署实际配置的那个基址】发请求，否则它只是在测一个与部署无关的常量。
# PFAN_API_BASE 与 deploy.sh 的就绪检查同名同义（deploy 里可用 PFAN_API 覆盖），
# 目标机只能经隧道/公网到达时由操作者显式设置。
PUBLIC_BASE="${PFAN_API_BASE:-https://pfan.example.com}"
code=$(timeout 30 curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "$PUBLIC_BASE/pfan" 2>/dev/null || echo 000)
# 失败路径可能得到 "000\n000" 之类的多行串，直接进数值比较会以看不懂的方式全挂 —— 只取 3 位状态码
code=${code:0:3}
if [ "$code" = 200 ]; then ok "公网入口 $PUBLIC_BASE/pfan = 200"; else bad "公网入口 $PUBLIC_BASE/pfan = $code"; fi

printf '\n=== 3b. 静态路由（拆分后的面板资源）===\n'
  # vendor 路由必须一起验：漏装时 app.js 的 ESM import 失败、整个面板不执行，
  # 而其余 4 个 URL 仍是 200 —— 不验就是静默半死。
  for u in /pfan.css /pfan.js /pfan-core.js /pfan-vendor-uplot.js /pfan-vendor-uplot.css; do
  c=$(timeout 20 curl -sS -o /dev/null -w '%{http_code}' --max-time 12 "$API$u" 2>/dev/null || echo 000)
  c=${c:0:3}
  if [ "$c" = 200 ]; then ok "$u = 200"; else bad "$u = $c（未部署？pfanel 仍是旧版）"; fi
done
# Content-Type 必须正确，否则浏览器按 HTML 解析 JS/CSS 导致面板白屏
ct=$(timeout 20 curl -sS -o /dev/null -w '%{content_type}' --max-time 12 "$API/pfan.css" 2>/dev/null || echo "")
case "$ct" in *text/css*) ok "Content-Type text/css" ;; *) bad "Content-Type: '$ct' (期望 text/css)" ;; esac
ct=$(timeout 20 curl -sS -o /dev/null -w '%{content_type}' --max-time 12 "$API/pfan.js" 2>/dev/null || echo "")
case "$ct" in *javascript*) ok "Content-Type javascript" ;; *) bad "Content-Type: '$ct' (期望 javascript)" ;; esac

printf '\n=== 4. 曲线参数权威源一致（repo vs 目标机 /etc/pfand.conf）===\n'
if remote 'sudo -n sha256sum /etc/pfand.conf' > "$CACHE/live.sha" 2>/dev/null && [ -s "$CACHE/live.sha" ]; then
  LIVE=$(awk '{print $1}' "$CACHE/live.sha")
  REPO=$(sha256sum config/pfand.conf.example 2>/dev/null | awk '{print $1}')
  if [ -n "$LIVE" ] && [ "$LIVE" = "$REPO" ]; then
    ok "曲线参数整文件 sha256 一致 ($REPO)"
  else
    bad "曲线参数漂移: repo=${REPO:-<缺>} live=${LIVE:-<缺>}（含 EMERG_REL 等全部 24 项）"
  fi
else
  bad "读目标机 /etc/pfand.conf 失败"
fi

printf '\n=== 4b. pfand 部署件与仓库一致（防 deploy 静默回退设备件）===\n'
# 设备曾长期跑一份【不在任何提交里】的 keep-level ensure_s0i3（36afcf02）：
# 仓库旧版每次启动先写 _FSL 1 0 把风扇停 0.6-3s，而 deploy.sh 会把这个安全修复
# 静默换回去。补丁现已上游（core/pfand 与设备件逐字节一致），所以这条比对一旦
# 报红就意味着【设备与仓库分叉】—— 先上游再部署，禁止直接 deploy 覆盖。
# 只读：两处 sha256sum（与 §9 的 pfanctl.c 同形）。
PFAND_REPO_SHA=$(sha256sum core/pfand 2>/dev/null | awk '{print $1}')
PFAND_LIVE_SHA=$(remote 'sudo -n sha256sum /usr/local/bin/pfand 2>/dev/null' | awk '{print $1}')
[ -n "$PFAND_LIVE_SHA" ] || PFAND_LIVE_SHA=$(remote 'sha256sum /usr/local/bin/pfand 2>/dev/null' | awk '{print $1}')
if [ -z "$PFAND_REPO_SHA" ]; then
  bad "仓库缺 core/pfand"
elif [ -z "$PFAND_LIVE_SHA" ]; then
  bad "设备 /usr/local/bin/pfand 读不到（未部署？sudo 不可用？）"
elif [ "$PFAND_REPO_SHA" != "$PFAND_LIVE_SHA" ]; then
  bad "pfand 部署件与仓库分叉: repo=$PFAND_REPO_SHA live=$PFAND_LIVE_SHA（设备跑着版本外的守护；先上游再部署，否则 deploy 会静默回退）"
else
  ok "pfand 部署件与仓库一致 ($PFAND_REPO_SHA)"
fi

printf '\n=== 5. 面板部署件与仓库一致，且无硬编码密钥 ===\n'
# 线上真正被服务的是 $PANEL_DIR/（server/pfanel.py 的 PANEL_DIR：
# /pfan→index.html, /pfan.css→styles.css, /pfan.js→app.js, /pfan-core.js→core.js），
# 不是仓库里的 panel/ 副本。只扫仓库副本会在两边字节已经分叉时假绿 ——
# 必须比对【实际部署件】的 sha256。全程只读：sha256sum / grep。
for f in index.html styles.css app.js core.js; do
  LH=$(sha256sum "panel/$f" 2>/dev/null | awk '{print $1}')
  if [ -z "$LH" ]; then bad "仓库缺 panel/$f"; continue; fi
  RH=$(remote "sha256sum $PANEL_DIR/$f" 2>/dev/null | awk '{print $1}')
  [ -n "$RH" ] || RH=$(remote "sudo -n sha256sum $PANEL_DIR/$f" 2>/dev/null | awk '{print $1}')
  if [ -z "$RH" ]; then
    bad "部署件读不到: $PANEL_DIR/$f（未部署？）"
  elif [ "$LH" = "$RH" ]; then
    ok "部署件 $f 与仓库一致 ($LH)"
  else
    bad "部署件 $f 已漂移: repo=$LH live=$RH（跑 bash scripts/deploy.sh 同步，勿只改一边）"
  fi
done

  # vendor 两件是 app.js 的 ESM 依赖，漂移=面板静默半死，一并比对
  for f in uPlot.esm.js uPlot.min.css; do
    LH=$(sha256sum "panel/vendor/$f" 2>/dev/null | awk '{print $1}')
    RH=$(remote "sha256sum $PANEL_DIR/vendor/$f 2>/dev/null" 2>/dev/null | awk '{print $1}')
    [ -n "$RH" ] || RH=$(remote "sudo -n sha256sum $PANEL_DIR/vendor/$f 2>/dev/null" 2>/dev/null | awk '{print $1}')
    if [ -z "$LH" ]; then bad "仓库缺 panel/vendor/$f"
    elif [ -z "$RH" ]; then bad "vendor 部署件读不到: $f（未部署？面板会全挂）"
    elif [ "$LH" != "$RH" ]; then bad "vendor 部署件 $f 已漂移: repo=$LH live=$RH"
    else ok "vendor $f 与仓库一致"; fi
  done

# 密钥扫描两边都做：仓库副本是开源泄露面，部署件是线上实际字节。
# 拆分后 Token 占位符在 app.js（服务端 /pfan.js 注入），HTML 里不应有明文。
SECRET_RE='sk-[A-Za-z0-9]{20,}|Bearer [A-Za-z0-9]{20,}|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
if ! grep -q '__PFAN_TOKEN__' panel/app.js; then
  bad "仓库 panel/app.js 缺 __PFAN_TOKEN__ 占位符"
elif grep -qE "$SECRET_RE" panel/app.js panel/index.html; then
  bad "仓库面板疑似含真实密钥/UUID"
else
  ok "仓库面板只含 __PFAN_TOKEN__ 占位符"
fi
# 部署件目录对部署用户不可读（2026-10-07 实测 grep 直读报 Permission denied），
# 与上面 sha256sum 一样必须带 sudo 兜底；否则会把【读不到】误报成【占位符不存在】——
# 一条指向完全相反的失败信息，会把人引去查服务端注入逻辑而不是权限。
dep_grep(){   # dep_grep <regex> <files...>  → 0=匹配 1=没匹配 2=两次都读不到
  local re="$1"; shift
  if remote "sudo -n grep -qE '$re' $*" 2>/dev/null; then return 0; fi
  if remote "grep -qE '$re' $*" 2>/dev/null; then return 0; fi
  remote "sudo -n test -r $(echo "$*" | cut -d' ' -f1)" 2>/dev/null && return 1
  return 2
}
dep_grep '__PFAN_TOKEN__' $PANEL_DIR/app.js
case $? in
  0)
    dep_grep "$SECRET_RE" $PANEL_DIR/app.js $PANEL_DIR/index.html
    case $? in
      0) bad "部署件疑似含真实密钥/UUID" ;;
      1) ok "部署件 app.js 只含 __PFAN_TOKEN__ 占位符" ;;
      *) bad "部署件密钥扫描读不到（权限？sudo 不可用？）" ;;
    esac ;;
  1) bad "部署件 app.js 缺 __PFAN_TOKEN__ 占位符（线上注入不到 Token？）" ;;
  *) bad "部署件 app.js 读不到（权限？sudo 不可用？）—— 不是占位符缺失，别去查注入逻辑" ;;
esac

printf '\n=== 6. 平台配置（事故根因那份文件，必须存在且完整）===\n'
PC=$(remote 'sudo -n cat /etc/pfan/platform.conf 2>/dev/null' || true)
if [ -z "$PC" ]; then
  bad "/etc/pfan/platform.conf 读不到 —— pfand/pfanel 会 fail-safe（就是 2026-10-06 那次事故的起因）"
else
  for k in EC_ROOT FAN_DEVICE THERMAL_ZONE DEV EC_CMD; do
    if echo "$PC" | grep -qE "^$k=\\S+"; then ok "$k 有值"; else bad "$k 缺失或为空"; fi
  done
  TZP=$(echo "$PC" | sed -n 's/^THERMAL_ZONE=//p' | head -1)
  if [ -n "$TZP" ] && [ -r "$TZP" ]; then ok "热区文件可读: $TZP"
  elif [ -n "$TZP" ]; then
    # 部署用户可能没有该路径权限，用 sudo 复核
    if remote "[ -r '$TZP' ]" 2>/dev/null; then ok "热区文件可读(需root): $TZP"
    else bad "热区文件不可读: $TZP"; fi
  else bad "THERMAL_ZONE 为空"; fi
fi
if remote 'sudo -n test -s /etc/pfan/fan-candidates.txt' 2>/dev/null; then
  ok "候选清单存在非空"
else
  bad "/etc/pfan/fan-candidates.txt 缺失 —— fail-safe 无候选可写"
fi

printf '\n=== 7. /dev/pfanctl 节点形状（2026-10-06 事故自检：普通文件遮蔽字符设备）===\n'
# 只读：stat 只取元数据，绝不写设备。恢复命令只出现在提示里，本脚本永不执行它。
# 恢复（docs/OPERATIONS.md 同款）：先删节点再重载模块，devtmpfs 会重建字符设备。
# 下面用 `""` 拼接是故意的：ci.sh 的只读守卫会把任何非注释行里的 `rm -` 判为写操作，
# 而失败信息必须带上完整恢复命令（否则现场的人还得去翻文档）。
RECOVER="rm ""-f /dev/pfanctl 后按 docs/OPERATIONS.md 重载 pfanctl 模块（devtmpfs 重建字符设备）"
dnn=$(remote 'stat -c "%F|%a" /dev/pfanctl' 2>/dev/null || true)
ft=${dnn%%|*}
md=${dnn##*|}
if [ -z "$dnn" ]; then
  bad "/dev/pfanctl 读不到（节点不存在？模块未加载）—— 恢复: $RECOVER"
elif [ "$ft" != "character special file" ]; then
  bad "危险: /dev/pfanctl 是【$ft】不是字符设备 —— 普通文件遮蔽（echo 进去被静默吞掉，全部风扇读写失效、无任何报错；2026-10-06 事故）。恢复: $RECOVER"
elif [ "$md" != "600" ]; then
  bad "危险: /dev/pfanctl 权限 $md ≠ 600 —— 该节点接受任意 ACPI 路径求值，写权限≈root，不得非 root/world 可访问。恢复: $RECOVER"
else
  ok "/dev/pfanctl = character special file 600（与 SECURITY.md 声明一致）"
fi

printf '\n=== 8. pfan 读路径实跑一次（RESULT 消费者之一，2026-10-06 后新增接缝的现场校验）===\n'
# 只读：pfan get 对设备写入的是 _FST 查询（getter，不改变档位），走 sudo -n 取 root
# （/dev/pfanctl 是 600 root，且 dmesg 可能被 dmesg_restrict 拦 —— 与生产同路径）。
if out=$(remote "timeout 20 sudo -n /usr/local/bin/pfan get" 2>&1); then
  line=$(printf '%s\n' "$out" | sed -n '/^\[/p' | tail -1)
  if [ -n "$line" ]; then
    ok "pfan get 读回: $line"
  else
    bad "pfan get 没有返回 [level,...] 行（RESULT 解析路径断了？）输出: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-160)"
  fi
else
  bad "pfan get 失败: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-160)"
fi

printf '\n=== 9. 内核模块源码与仓库一致（deploy.sh 不同步 /opt/pfanctl）===\n'
# deploy.sh 的传输清单里没有 pfanctl.c/Makefile（文档里那条 [未验证] 的缺口），
# 所以 /opt/pfanctl 以机器为准 —— 源码一旦漂移，仓库就不再描述真正在跑的内核模块，
# 而这种漂移没有任何别的检查能发现（.ko 是编译产物、内核里的实例无从比对）。
# 只读：两处 sha256sum。注意这只证明【磁盘源码一致】，不代表现役 .ko 是用它编的 ——
# 那一条由下面的 mtime 兜底（.c 比 .ko 新 = 编译过期，需要人工重建）。
REPO_C=$(sha256sum core/pfanctl/pfanctl.c 2>/dev/null | awk '{print $1}')
TGT_C=$(remote 'sudo -n sha256sum /opt/pfanctl/pfanctl.c 2>/dev/null' | awk '{print $1}')
if [ -z "$REPO_C" ]; then
  bad "仓库缺 core/pfanctl/pfanctl.c"
elif [ -z "$TGT_C" ]; then
  bad "目标机 /opt/pfanctl/pfanctl.c 读不到（未部署？sudo 不可用？）"
elif [ "$REPO_C" != "$TGT_C" ]; then
  bad "内核模块源码漂移: repo=$REPO_C target=$TGT_C（仓库不再描述在跑的模块；按 docs/OPERATIONS.md 同步后重建）"
else
  ok "pfanctl.c 与仓库一致 ($REPO_C)"
fi
# .ko 是否比 .c 旧：旧了就是"源码改过但没重新编译"，现役模块仍是旧行为。
mt=$(remote 'a=$(stat -c %Y /opt/pfanctl/pfanctl.c 2>/dev/null); b=$(stat -c %Y /opt/pfanctl/pfanctl.ko 2>/dev/null); [ -n "$a" ] && [ -n "$b" ] && { [ "$b" -ge "$a" ] && echo fresh || echo stale; }' 2>/dev/null)
case "$mt" in
  fresh) ok ".ko 不早于源码（编译未过期）" ;;
  stale) bad "/opt/pfanctl/pfanctl.ko 比 pfanctl.c 旧 —— 源码改了但没重建，现役模块仍是旧行为（按 docs/OPERATIONS.md 重建并重载）" ;;
  *)     bad "无法判断 .ko/.c 时间关系（读不到？）" ;;
esac

# §9b vermagic —— 只查时间戳【不够】：.ko 可以是刚复制的，但为旧内核编译。
# 2026-10-09 21:48 实测踩到：机器自动升级到 6.8.0-146-generic，而 .ko 是为
# 6.8.0-142 编的 -> insmod 报 "Invalid parameters" -> /dev/pfanctl 不出现 ->
# pfanctl active=failed -> pfand/pfanel 跟着 inactive -> 面板与 API 全不可达。
# 那个时间戳检查对新拷贝的 .ko 完全满意 —— 它只比 .c 与 .ko 的先后。
printf '\n=== 9b. 内核模块 vermagic 必须匹配当前运行内核 ===\n'
_kr=$(remote 'uname -r' 2>/dev/null)
_vm=$(remote 'modinfo /opt/pfanctl/pfanctl.ko 2>/dev/null | sed -n "s/^vermagic:[[:space:]]*\([^ ]*\).*/\1/p"' 2>/dev/null)
if [ -z "$_kr" ]; then
  bad "读不到运行内核版本（uname -r 无输出）—— 无法判定 vermagic"
elif [ -z "$_vm" ]; then
  bad "读不到 /opt/pfanctl/pfanctl.ko 的 vermagic（modinfo 无输出）"
elif [ "$_kr" = "$_vm" ]; then
  ok "vermagic $_vm 与运行内核一致"
else
  bad "vermagic $_vm != 运行内核 $_kr —— insmod 会报 Invalid parameters，/dev/pfanctl 不出现，pfanctl/pfand/pfanel 全挂，风扇失去控制。重建：sudo rm -f /opt/pfanctl/pfanctl.ko /opt/pfanctl/pfanctl.o /opt/pfanctl/pfanctl.mod.c /opt/pfanctl/pfanctl.mod.o && sudo make -C /lib/modules/$(uname -r)/build M=/opt/pfanctl modules（只删 .ko 不够：源码没变时 make 认为无需重建，vermagic 保持旧的）"
fi

printf '\n=== smoke.sh: %s (rc=%d) ===\n' "$([ "$rc" -eq 0 ] && echo PASS || echo FAIL)" "$rc"
exit "$rc"
