#!/usr/bin/env bash
# 守卫行为测试 —— 复审 Critical/Important 修复的回归网。
# 不碰网络、不碰目标机、不碰真仓库（在 scratch 副本里跑 ci.sh）。
set -uo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
cd "$repo" || exit 1
fails=0
ok(){ printf '  [ok]   %s\n' "$1"; }
ng(){ printf '  [FAIL] %s\n' "$1"; fails=$((fails+1)); }
sec(){ printf '\n== %s ==\n' "$1"; }

SCRATCH="${XDG_CACHE_HOME:-$HOME/.cache}/pfan-scratch"
fresh_scratch(){
  rm -rf "$SCRATCH"; mkdir -p "$SCRATCH"
  (cd "$repo" && tar -cf - --exclude=./.git --exclude=./node_modules --exclude=./.superpowers .) \
    | (cd "$SCRATCH" && tar -xf -)
}

sec "T1: 删除核心源文件必须让 ci.sh 报红"
fresh_scratch
rm -f "$SCRATCH/core/pfand"
if (cd "$SCRATCH" && PFAN_SKIP_SHELL_TESTS=1 bash scripts/ci.sh >/dev/null 2>&1); then
  ng "删掉 core/pfand 后 ci.sh 仍 PASS —— 文件缺失是静默跳过的"
else
  ok "删掉 core/pfand → ci.sh 报红"
fi

sec "T2: smoke.sh 里出现写操作必须让 ci.sh 报红"
fresh_scratch
printf '\ncurl -X POST http://example.invalid/api/level -d level=100\n' >> "$SCRATCH/scripts/smoke.sh"
if (cd "$SCRATCH" && PFAN_SKIP_SHELL_TESTS=1 bash scripts/ci.sh >/dev/null 2>&1); then
  ng "smoke.sh 含 POST 仍 PASS —— 只读性质无回归保护"
else
  ok "smoke.sh 含 POST → ci.sh 报红"
fi

sec "T3: fail-safe 断言语义（需暴露 GUARD_FAILSAFE_JQ 且接受 EMERG 参数）"
EXPR=$(sed -n "s/^GUARD_FAILSAFE_JQ='\(.*\)'/\1/p" scripts/smoke.sh | head -1)
if [ -z "$EXPR" ]; then
  ng "smoke.sh 未定义顶层变量 GUARD_FAILSAFE_JQ"
else
  chk(){ # $1=json  $2=期望jq退出码(0=通过)  $3=描述
    local r; r=$(echo "$1" | jq -e --argjson emerg 80 "$EXPR" >/dev/null 2>&1; echo $?)
    if [ "$r" = "$2" ]; then ok "$3"; else ng "$3（期望 rc=$2 实际 rc=$r）"; fi
  }
  chk '{"temp":85,"level":50}'   1 "过热 85C 却只有 50 档 → 必须拒绝"
  chk '{"temp":85,"level":100}'  0 "过热但已满速 → 接受"
  chk '{"temp":48,"level":25}'   0 "正常温度低档位 → 接受"
  chk '{"temp":null,"level":100}' 0 "温度读不到但满速 → 接受"
  chk '{"temp":null,"level":50}'  1 "温度读不到且非满速 → 必须拒绝"
  chk '{"temp":79,"level":60}'    0 "79C 低于 EMERG=80 → 接受"
fi

sec "T4: 服务判定（NRestarts>0 应为 warn 而非 fail）"
if [ -f scripts/smoke-lib.sh ]; then
  # shellcheck source=/dev/null
  . scripts/smoke-lib.sh
  svc_verdict active enabled 0 >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 0 ] && ok "active/enabled/NR=0 → ok(rc0)" || ng "active/enabled/NR=0 → rc=$rc 期望0"
  svc_verdict active enabled 3 >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 1 ] && ok "NRestarts=3 → warn(rc1，不阻断)" || ng "NRestarts=3 → rc=$rc 期望1(warn)"
  svc_verdict inactive enabled 0 >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 2 ] && ok "inactive → bad(rc2)" || ng "inactive → rc=$rc 期望2"
  svc_verdict active disabled 0 >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 2 ] && ok "disabled → bad(rc2)" || ng "disabled → rc=$rc 期望2"
else
  ng "scripts/smoke-lib.sh 不存在（svc_verdict 未实现）"
fi

sec "T5: 曲线参数应整文件比对（sha256），而非只查 6 个键"
if grep -q 'sha256' scripts/smoke.sh; then ok "smoke.sh 使用 sha256 整文件比对"; else ng "smoke.sh 仍只比 6 个键，EMERG_REL 等漂移检测不到"; fi

printf '\n== test_guards: %s (fails=%d) ==\n' "$([ "$fails" -eq 0 ] && echo PASS || echo FAIL)" "$fails"
exit "$fails"
