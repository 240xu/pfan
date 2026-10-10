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
API="${PFAN_API:-http://$HOST:8789}"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/pfan"
mkdir -p "$CACHE"
OPTS=(-i "$HOME/.ssh/pfan_deploy_key" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=8)
rc=0
ok(){ printf '  [ok]   %s\n' "$1"; }
bad(){ printf '  [FAIL] %s\n' "$1"; rc=1; }
remote(){ timeout 25 ssh "${OPTS[@]}" "pfan@$HOST" "$@"; }
. "$(dirname "$0")/smoke-lib.sh"   # svc_verdict
warn(){ printf '  [warn] %s\n' "$1"; }

# 0) 可达性 —— 不可达必须失败，不许跳过
if ! timeout 8 ssh "${OPTS[@]}" "pfan@$HOST" true 2>/dev/null; then
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
# ⚠ 先等守护写出第一个档位再断言：pfand 每次启动都会先 ensure_s0i3()，而那一步
# 会写 _FSL 1 0（s0i3 的握手序列，固件在此期间不转），随后才写真正的档位。这个
# 窗口约 1.2s（实测），一个 IV 之内自愈。deploy.sh 刚重启过 pfand 时立刻跑 smoke
# 就会正好采到 level=0，误报成"风扇停转 + API 字段缺失"（2026-10-10 实测踩到）。
# 这里最多等 25s，让 smoke 不再替守护的启动握手背锅。
_waited=0
while :; do
  j=$(timeout 20 curl -fsS --max-time 12 "$API/api/now" 2>/dev/null) && break
  j=""
  break
done
while [ "$_waited" -lt 25 ]; do
  case "$j" in *'"level":0'*) ;; *) break ;; esac
  sleep 2; _waited=$((_waited + 2))
  j=$(timeout 20 curl -fsS --max-time 12 "$API/api/now" 2>/dev/null) || j=""
done
[ -n "$j" ] || bad "LAN $API/api/now 不可达"
if [ "$_waited" -gt 0 ]; then
  echo "    （等了 ${_waited}s 让 pfand 走出 s0i3 握手窗口 —— level=0 在守护刚启动时是预期的，不是停转）"
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
code=$(timeout 30 curl -sS -o /dev/null -w '%{http_code}' --max-time 20 https://pfan.example.com/pfan 2>/dev/null || echo 000)
# 失败路径可能得到 "000\n000" 之类的多行串，直接进数值比较会以看不懂的方式全挂 —— 只取 3 位状态码
code=${code:0:3}
if [ "$code" = 200 ]; then ok "pfan.example.com/pfan = 200"; else bad "公网入口 = $code"; fi

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

printf '\n=== 5. 面板部署件与仓库一致，且无硬编码密钥 ===\n'
# 线上真正被服务的是 /opt/beszel/beszel_data/（server/pfanel.py 的 PANEL_DIR：
# /pfan→index.html, /pfan.css→styles.css, /pfan.js→app.js, /pfan-core.js→core.js），
# 不是仓库里的 panel/ 副本。只扫仓库副本会在两边字节已经分叉时假绿 ——
# 必须比对【实际部署件】的 sha256。全程只读：sha256sum / grep。
for f in index.html styles.css app.js core.js; do
  LH=$(sha256sum "panel/$f" 2>/dev/null | awk '{print $1}')
  if [ -z "$LH" ]; then bad "仓库缺 panel/$f"; continue; fi
  RH=$(remote "sha256sum /opt/beszel/beszel_data/$f" 2>/dev/null | awk '{print $1}')
  [ -n "$RH" ] || RH=$(remote "sudo -n sha256sum /opt/beszel/beszel_data/$f" 2>/dev/null | awk '{print $1}')
  if [ -z "$RH" ]; then
    bad "部署件读不到: /opt/beszel/beszel_data/$f（未部署？）"
  elif [ "$LH" = "$RH" ]; then
    ok "部署件 $f 与仓库一致 ($LH)"
  else
    bad "部署件 $f 已漂移: repo=$LH live=$RH（跑 bash scripts/deploy.sh 同步，勿只改一边）"
  fi
done

  # vendor 两件是 app.js 的 ESM 依赖，漂移=面板静默半死，一并比对
  for f in uPlot.esm.js uPlot.min.css; do
    LH=$(sha256sum "panel/vendor/$f" 2>/dev/null | awk '{print $1}')
    RH=$(remote "sha256sum /opt/beszel/beszel_data/vendor/$f 2>/dev/null" 2>/dev/null | awk '{print $1}')
    [ -n "$RH" ] || RH=$(remote "sudo -n sha256sum /opt/beszel/beszel_data/vendor/$f 2>/dev/null" 2>/dev/null | awk '{print $1}')
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
# 部署件目录对 pfan 不可读（2026-10-07 实测 grep 直读报 Permission denied），
# 与上面 sha256sum 一样必须带 sudo 兜底；否则会把【读不到】误报成【占位符不存在】——
# 一条指向完全相反的失败信息，会把人引去查服务端注入逻辑而不是权限。
dep_grep(){   # dep_grep <regex> <files...>  → 0=匹配 1=没匹配 2=两次都读不到
  local re="$1"; shift
  if remote "sudo -n grep -qE '$re' $*" 2>/dev/null; then return 0; fi
  if remote "grep -qE '$re' $*" 2>/dev/null; then return 0; fi
  remote "sudo -n test -r $(echo "$*" | cut -d' ' -f1)" 2>/dev/null && return 1
  return 2
}
dep_grep '__PFAN_TOKEN__' /opt/beszel/beszel_data/app.js
case $? in
  0)
    dep_grep "$SECRET_RE" /opt/beszel/beszel_data/app.js /opt/beszel/beszel_data/index.html
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
    # pfan 可能没有该路径权限，用 sudo 复核
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
