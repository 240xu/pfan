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

sec "T6: level=0 的等待守卫必须真的会等（2026-10-10 修）"
# 这条守卫原来判的是 `case "$j" in *'"level":0'*)`，而服务实际发 `"level": 0`
# （冒号后有空格）—— 永远失配，第一轮就 break，等了 0 秒。冒烟于是把一台正在自愈的
# 健康机器报成"风扇停转 + API 字段缺失"。它的注释说的是"等 25s"，代码等 0 秒。
#
# 这里【跑真实代码】：把 scripts/smoke.sh 里那段守卫逐字抽出来（不复述、不重写），
# 用一个假 curl 喂脚本化响应，断言三个行为：会等、等不到仍然失败、正常时不等。
# 只 grep 源码的守卫挡不住这个 —— 2026-10-10 的缺陷正是"注释与代码相反"，
# 而 grep 只会看到注释还在。
T6D=$(mktemp -d "${TMPDIR:-/tmp}/pfan-t6.XXXXXX")
mkdir -p "$T6D/bin"
T6BASH=$(command -v bash)
{
  # shebang 用绝对路径：Termux 没有 /usr/bin/env，而仓库的脚本一律 `bash x.sh` 调用。
  printf '#!%s\n' "$T6BASH"
  cat <<'STUB'
n=$(cat "$STATE" 2>/dev/null || echo 0); n=$((n + 1)); printf '%s' "$n" > "$STATE"
total=$(wc -l < "$SEQ"); [ "$n" -le "$total" ] || n=$total
sed -n "${n}p" "$SEQ"
STUB
} > "$T6D/bin/curl"
chmod +x "$T6D/bin/curl"

t6_guard=$(awk '
  /^WAIT_LEVEL0_MAX=/ { f=1 }
  /^_waited=0$/        { f=1 }
  f                   { print }
  /^\[ -n "\$j" \] \|\| bad/ { exit }
' scripts/smoke.sh | sed '$d')
if [ "$(printf '%s\n' "$t6_guard" | wc -l)" -lt 5 ]; then
  ng "抽不出 smoke.sh 的 level 等待守卫（抽到 $(printf '%s\n' "$t6_guard" | wc -l) 行）—— 抽取锚点失效，先修这个"
else
  printf '%s\n' "$t6_guard" > "$T6D/guard.sh"
  # 断言用的 jq 表达式也从真实文件抽（与 T3 抽 GUARD_FAILSAFE_JQ 同一做法）
  T6_FILTER=$(grep 'level >= 1' scripts/smoke.sh | head -1 | sed "s/.*jq -e '\(.*\)'.*/\1/")
  [ -n "$T6_FILTER" ] || ng "抽不出 smoke.sh 的 level 区间断言"
  ok "从 smoke.sh 逐字抽到等待守卫（$(printf '%s\n' "$t6_guard" | wc -l) 行）与 level 断言"

  # t6_run <seq> <budget>  ->  "<waited>|<final-j>"
  t6_run(){
    local seq="$1" budget="$2" state="$T6D/state"
    rm -f "$state"
    SEQ="$seq" STATE="$state" PATH="$T6D/bin:$PATH" API="http://stub:8789" \
      PFAN_WAIT_LEVEL0_MAX="$budget" \
      "$T6BASH" -c "j=''; . '$T6D/guard.sh'; printf '%s|%s' \"\$_waited\" \"\$j\"" 2>/dev/null
  }
  ZERO='{"ts": 1792068819, "temp": 43.0, "level": 0, "ec76": 0, "rpm": null, "mode": "daemon", "curve": "s0i3", "gov": "curve", "fps": [0,0,0], "cached": true, "age": 0.4}'
  GOOD='{"ts": 1792068825, "temp": 44.0, "level": 25, "ec76": 25, "rpm": 3100, "mode": "daemon", "curve": "s0i3", "gov": "curve", "fps": [3100,15000,1500], "cached": true, "age": 6.4}'
  printf '%s\n%s\n%s\n' "$ZERO" "$ZERO" "$GOOD" > "$T6D/then-good.seq"
  printf '%s\n' "$ZERO" > "$T6D/zero.seq"
  printf '%s\n' "$GOOD" > "$T6D/good.seq"

  # (a) 先 0 后正常 ⇒ 必须真的等，且最后拿到的是正常那份
  r=$(t6_run "$T6D/then-good.seq" 20); w=${r%%|*}; j=${r#*|}
  if [ "${w:-0}" -gt 0 ] 2>/dev/null && printf '%s' "$j" | jq -e "$T6_FILTER" >/dev/null 2>&1; then
    ok "level=0 时等了 ${w}s 并等到正常档位（原实现 0s 就退出）"
  else
    ng "level=0 时没有等就退出（waited=${w:-?}）—— 守卫不会转，等于没有守卫"
  fi

  # (b) 永远为 0 ⇒ 预算耗尽后【仍然失败】。守卫只能是"更有耐心"，不能变宽松。
  r=$(t6_run "$T6D/zero.seq" 4); w=${r%%|*}; j=${r#*|}
  if [ "${w:-0}" -ge 4 ] 2>/dev/null && ! printf '%s' "$j" | jq -e "$T6_FILTER" >/dev/null 2>&1; then
    ok "level 永远为 0 ⇒ 等满预算 ${w}s 后仍判 FAIL（没有被等宽松）"
  else
    ng "level 永远为 0 时 waited=${w:-?}（期望 ≥4），断言判 $(if printf '%s' "$j" | jq -e "$T6_FILTER" >/dev/null 2>&1; then echo '仍然接受'; else echo '拒绝'; fi) —— 真故障被放过或没等够"
  fi

  # (c) 正常情况不许变慢：第一轮就该退出，一次 sleep 都不睡
  r=$(t6_run "$T6D/good.seq" 20); w=${r%%|*}
  if [ "${w:-x}" = 0 ]; then
    ok "level 正常时第 1 轮即退出，_waited=0（冒烟不引入延迟）"
  else
    ng "level 已经正常时仍然等了 ${w}s —— 正常路径被拖慢"
  fi
fi
rm -rf "$T6D"

printf '\n== test_guards: %s (fails=%d) ==\n' "$([ "$fails" -eq 0 ] && echo PASS || echo FAIL)" "$fails"
exit "$fails"
