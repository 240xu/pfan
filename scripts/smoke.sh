#!/usr/bin/env bash
# scripts/smoke.sh — 实机只读冒烟。
# 只允许：GET / systemctl show|is-active|is-enabled / cat / grep / ufw status。
# 严禁任何写操作（POST、set_level、set_curve、systemctl start|stop|restart、ufw allow|delete、rm）。
# Termux 注意：/usr/bin/env 不存在，且无 /tmp 写权限 → 用 `bash scripts/smoke.sh` 调用。
set -uo pipefail

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
j=$(timeout 20 curl -fsS --max-time 12 "$API/api/now" 2>/dev/null) || { bad "LAN $API/api/now 不可达"; j=""; }
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
  [ -n "${EMERG_V:-}" ] || EMERG_V=80
  if echo "$j" | jq -e --argjson emerg "$EMERG_V" "$GUARD_FAILSAFE_JQ" >/dev/null 2>&1; then
    ok "fail-safe：温度>=EMERG($EMERG_V) 或读不到 ⇒ 满速"
  else
    bad "温度异常但非满速: $(echo "$j" | jq -c '{temp,level}' 2>/dev/null)"
  fi
fi

printf '\n=== 3. 公网入口 ===\n'
code=$(timeout 30 curl -sS -o /dev/null -w '%{http_code}' --max-time 20 https://pfan.example.com/pfan 2>/dev/null || echo 000)
if [ "$code" = 200 ]; then ok "pfan.example.com/pfan = 200"; else bad "公网入口 = $code"; fi

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

printf '\n=== 5. 面板无硬编码密钥 ===\n'
if grep -q '__PFAN_TOKEN__' panel/pfanpanel.html; then
  if grep -qE 'sk-[A-Za-z0-9]{20,}|Bearer [A-Za-z0-9]{20,}|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' panel/pfanpanel.html; then
    bad "面板疑似含真实密钥/UUID"
  else
    ok "面板只含 __PFAN_TOKEN__ 占位符"
  fi
else
  bad "面板缺 __PFAN_TOKEN__ 占位符"
fi

printf '\n=== smoke.sh: %s (rc=%d) ===\n' "$([ "$rc" -eq 0 ] && echo PASS || echo FAIL)" "$rc"
exit "$rc"
