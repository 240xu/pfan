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

# R-11（2026-10-11 实测）：T1/T2 原先只看 rc。scratch 树排除 node_modules，vitest
# 缺失恒退 1；T1 的树还另有 pytest 失败 —— 于是 rc 恒非 0，两条断言【无论守卫死没死】
# 都走「红」分支（两条守卫全拆掉 + 注入变异，ci 照样 rc=1，日志里两条守卫的行一句
# 都没有）。现在用接缝把 pytest/vitest 关掉，断言改成【具体那一行】：
# 守卫死了，那一行就不出现，测试转红；顺带省掉 ~190s
# （2026-10-18 实测：整份套件 215s → 16s）。
sec "T1: 删除核心源文件必须让 ci.sh 报红"
fresh_scratch
rm -f "$SCRATCH/core/pfand"
T1LOG=$(cd "$SCRATCH" && PFAN_SKIP_SHELL_TESTS=1 PFAN_SKIP_PYTEST=1 PFAN_SKIP_VITEST=1 \
        bash scripts/ci.sh 2>&1); T1RC=$?
if [ "$T1RC" -eq 0 ]; then
  ng "删掉 core/pfand 后 ci.sh 仍 PASS —— 文件缺失是静默跳过的"
elif grep -qE '^MISSING: core/pfand$' <<<"$T1LOG"; then
  ok "删掉 core/pfand → ci.sh 报红（rc=$T1RC）且输出含具体的 'MISSING: core/pfand'"
else
  ng "删掉 core/pfand 后 ci.sh rc=$T1RC，但输出里没有 'MISSING: core/pfand' —— 红在别处，清单守卫没在守"
fi

sec "T2: smoke.sh 里出现写操作必须让 ci.sh 报红"
fresh_scratch
printf '\ncurl -X POST http://example.invalid/api/level -d level=100\n' >> "$SCRATCH/scripts/smoke.sh"
T2LOG=$(cd "$SCRATCH" && PFAN_SKIP_SHELL_TESTS=1 PFAN_SKIP_PYTEST=1 PFAN_SKIP_VITEST=1 \
        bash scripts/ci.sh 2>&1); T2RC=$?
if [ "$T2RC" -eq 0 ]; then
  ng "smoke.sh 含 POST 仍 PASS —— 只读性质无回归保护"
elif grep -qE '^smoke 文件含写操作' <<<"$T2LOG"; then
  ok "smoke.sh 含 POST → ci.sh 报红（rc=$T2RC）且输出含具体的 'smoke 文件含写操作'"
else
  ng "smoke.sh 含 POST 后 ci.sh rc=$T2RC，但输出里没有 'smoke 文件含写操作' —— 红在别处，只读守卫没在守"
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

# T6b 钉的是【缺省值】。T6 一次钉住的是机制：会等 / 等不到仍失败 / 正常时不等。
# 上面 T6 三个子例都【显式传了】PFAN_WAIT_LEVEL0_MAX（那个覆盖项存在的唯一理由就是
# 让 CI 不用真睡 46s），于是 WAIT_LEVEL0_MAX 的缺省值从来没有被任何断言碰过：
# 把它改回 25、甚至改到 5，整份测试照样 fails=0（本分支变异实测）——
# 而出事故的那个数字正是它。2026-10-10：冒烟在一台【正在自愈的健康机器】上报出
# "level 越界: 0"，根因是 25s 的预算比 30s 的恢复窗口短。
sec "T6b: level=0 等待预算的【缺省值】必须钉住 —— 25s 预算比实测恢复窗口短，必然误报"
# 这里断言的是【关系】，不是字面量 45：
#   缺省预算必须【超过实测恢复窗口 30s】。任何 ≤30 的值都是【已知错值】——
#   计数器按 2s 步进（scripts/smoke.sh:59-62），25 的预算实际只能等 26s < 30s，
#   于是每一次正确的恢复都会被报成故障。30 来自 2026-10-10 的实测记录
#   （level=0 持续 ≥10s，约 30s 才回到正常档，见 scripts/smoke.sh:70-72）。
#
# 为什么【不】把 45 钉死：45 是"给 30s 留 50% 余量"的策略选择，不是正确性条件。
# 钉死它有两个坏处：① 它会禁止一个同样正确、甚至更稳的取值（40 或 50），
# 正确性收益为零；② 这个字面量自己也会烂 —— 下次重新实测得到 35s 时，
# 钉 45 的断言会以"守卫坏了"的样子报错，把一次正常的重新标定伪装成回归。
# 被断言的只有【不会退回已知错值】这一条。
# 上界只做宽松封顶：deploy.sh 重启完立刻跑冒烟，真故障晚报一会儿是温和的方向
# （scripts/smoke.sh:73-74 自己就是这么权衡的），但冒烟是冒烟，不该挂上几分钟。
T6B_FLOOR=30    # 实测恢复窗口（秒），出处见上（与 scripts/smoke.sh:70-72 同一份记录）
T6B_CEIL=120    # 封顶：超过 ~2min 就不是冒烟了，是脚本卡住
# 【执行】smoke.sh 里定义 WAIT_LEVEL0_MAX 的那一行，而不是 grep 字面量：
# 整行原样交给一个【没设 PFAN_WAIT_LEVEL0_MAX】的干净 bash 去 source，读出结果。
# 于是这一条问的是"不传覆盖时冒烟真的用多少秒"，加引号、改展开写法、后面挂个
# 注释都不会让它失效 —— 也不会像字面量断言那样在某次重构后静默失去锚点。
T6BASH=$(command -v bash)
T6B_N=$(grep -c '^WAIT_LEVEL0_MAX=' scripts/smoke.sh)
if [ "$T6B_N" -ne 1 ]; then
  ng "scripts/smoke.sh 里有 $T6B_N 行顶层 WAIT_LEVEL0_MAX= 赋值（期望恰好 1）—— 抽取锚点变了，先修这个再谈钉值"
else
  T6BD=$(mktemp -d "${XDG_CACHE_HOME:-$HOME/.cache}/pfan-t6b.XXXXXX")
  grep '^WAIT_LEVEL0_MAX=' scripts/smoke.sh > "$T6BD/assign.sh"
  # set -u：把 ${PFAN_WAIT_LEVEL0_MAX} 写成【没有缺省】的写法会让这里直接报错，
  # 那正是"缺省值没了"该有的反应（生产里那条赋值会跟着报未定义变量），不许静默通过。
  T6B_RAW=$(env -u PFAN_WAIT_LEVEL0_MAX "$T6BASH" -c 'set -u; . "$1"; printf %s "$WAIT_LEVEL0_MAX"' \
              _ "$T6BD/assign.sh" 2>&1); T6B_RC=$?
  if [ "$T6B_RC" -ne 0 ]; then
    ng "求 WAIT_LEVEL0_MAX 缺省值时报错: $(printf '%s' "$T6B_RAW" | head -1)"
  elif ! printf '%s' "$T6B_RAW" | grep -qE '^[0-9]+$'; then
    ng "缺省预算不是正整数: '${T6B_RAW}' —— 守卫比的是 [ _waited -lt 预算 ]，非数字会让它要么一次都不等、要么每次等满"
  elif [ "$T6B_RAW" -le "$T6B_FLOOR" ]; then
    ng "缺省预算 ${T6B_RAW}s ≤ 实测恢复窗口 ${T6B_FLOOR}s —— 这就是「把正在自愈的健康机器报成故障」的形态（25s → 必然误报）"
  elif [ "$T6B_RAW" -gt "$T6B_CEIL" ]; then
    ng "缺省预算 ${T6B_RAW}s > 封顶 ${T6B_CEIL}s —— deploy.sh 重启后立刻跑冒烟，等这么久就不是冒烟了"
  else
    ok "缺省预算 ${T6B_RAW}s（> 实测恢复 ${T6B_FLOOR}s，≤ 封顶 ${T6B_CEIL}s）：不传覆盖时冒烟等得起一次完整恢复"
  fi
  rm -rf "$T6BD"
fi

sec "T7: 已安装布局下 PLAT_EXAMPLE 的兜底两跳（R-10）"
# 2026-10-11 设备实测：`sudo pfan detect` rc=9、stdout 为空 —— 已安装布局
# （/usr/local/bin/pfan）下第一跳 ../platform/ 不存在，而 example 从未被装到任何地方，
# pfand 的恢复提示「先跑 pfan detect」因此在所有部署机上都是死的。修法两半：
# deploy.sh 3b2 装一份到 /usr/local/lib/pfan/，core/pfan 加第二跳 [ -f ] || 兜底。
#
# 这里【真跑】装好布局的 pfan：proot 把 /usr/local 映射到临时树（测试机没 root、
# 没有 /usr/local，绝对路径只能这么模拟），树里只有第二跳那份 example（带哨兵值）。
# 判据是行为不是源码文本：rc=0 且输出的 PANEL_DIR 等于【第二跳那份文件】的值。
# 缺 proot 就报红（不静默跳过）—— 这条守卫要的正是绝对路径下的布局行为。
T7BASH=$(command -v bash)
if ! command -v proot >/dev/null 2>&1; then
  ng "缺 proot —— 无法把 /usr/local 映射到临时树来模拟已安装布局，这条守卫在本机跑不了"
else
  T7D=$(mktemp -d "${TMPDIR:-/tmp}/pfan-t7.XXXXXX")
  mkdir -p "$T7D/usr/local/bin" "$T7D/usr/local/lib/pfan" "$T7D/thermal/thermal_zone0"
  echo x86_pkg_temp > "$T7D/thermal/thermal_zone0/type"
  cp core/pfan "$T7D/usr/local/bin/pfan"
  cp core/platform.sh "$T7D/usr/local/lib/pfan/platform.sh"
  sed 's|^PANEL_DIR=.*|PANEL_DIR=/t7-sentinel-panel|' platform/platform.conf.example \
    > "$T7D/usr/local/lib/pfan/platform.conf.example"
  t7_run(){ # t7_run <pfan 路径>：stdout 原样返回，stderr 落 $T7D/err
    env -u PFAN_PLATFORM_EXAMPLE \
      PFAN_THERMAL_DIR="$T7D/thermal" PFAN_ACPI_PROBE='ok:\_SB.T7' \
      PFAN_CANDIDATES="$repo/platform/fan-candidates.txt" \
      proot -b "$T7D/usr/local:/usr/local" "$T7BASH" "$1" detect 2>"$T7D/err"
  }
  T7OUT=$(t7_run "$T7D/usr/local/bin/pfan"); T7RC=$?
  if [ "$T7RC" -ne 0 ]; then
    ng "已安装布局下 detect rc=$T7RC（期望 0）—— 第二跳没生效（stderr: $(head -1 "$T7D/err")）"
  elif grep -qx 'PANEL_DIR=/t7-sentinel-panel' <<<"$T7OUT"; then
    ok "已安装布局下 detect rc=0，PANEL_DIR 取自 /usr/local/lib/pfan/ 的 example（第二跳生效）"
  else
    ng "已安装布局下 detect rc=0 但 PANEL_DIR 不对：$(printf '%s\n' "$T7OUT" | grep '^PANEL_DIR=' || echo '<没有这一键>')（期望 /t7-sentinel-panel）"
  fi
  # 反向控制：删掉第二跳那份文件 ⇒ 必须 rc=9、无 PANEL_DIR（fail-closed，不猜值）。
  # 没有它时，一个「第一跳其实还在」的假布局会让上面那条假绿。
  rm -f "$T7D/usr/local/lib/pfan/platform.conf.example"
  T7OUT2=$(t7_run "$T7D/usr/local/bin/pfan"); T7RC2=$?
  if [ "$T7RC2" -eq 9 ] && ! grep -q '^PANEL_DIR=' <<<"$T7OUT2"; then
    ok "第二跳文件消失 ⇒ rc=9、无 PANEL_DIR（fail-closed，不猜值）"
  else
    ng "第二跳文件消失后 rc=$T7RC2（期望 9）、PANEL_DIR=$(printf '%s\n' "$T7OUT2" | grep '^PANEL_DIR=' || echo '<无>')"
  fi
  rm -rf "$T7D"
fi

sec "T8: 两个新接缝（PFAN_SKIP_PYTEST/VITEST）的缺省必须是【关】—— 否则真 CI 会静默少两层"
# T1/T2 显式传了接缝，证明不了「不传时 pytest/vitest 真的会跑」。探针树里放一条
# 必然失败的 pytest 用例；不传接缝时必须【跑到】pytest 与 vitest 两步（vitest 在
# scratch 里因缺 node_modules 而失败，正是 R-11 的成因）。任一步被静默跳过
# （例如把 :-0 写成 :-1），探针就看不见对应的行，这里转红。
fresh_scratch
rm -f "$SCRATCH"/tests/python/*.py
printf 'def test_zz_seam_probe():\n    assert False, "seam probe"\n' > "$SCRATCH/tests/python/test_zz_seam_probe.py"
T8LOG=$(cd "$SCRATCH" && PFAN_SKIP_SHELL_TESTS=1 bash scripts/ci.sh 2>&1); T8RC=$?
if [ "$T8RC" -eq 0 ]; then
  ng "探针树（pytest 必失败 + 无 node_modules）里 ci.sh 仍 PASS —— pytest/vitest 至少一步被静默跳过"
else
  if grep -qF '=== pytest tests/python ===' <<<"$T8LOG"; then
    ok "不传接缝时 pytest 步真的在跑（缺省=关）"
  else
    ng "不传接缝时 pytest 步没跑 —— PFAN_SKIP_PYTEST 缺省被改成跳过，真 CI 会静默少一层"
  fi
  if grep -qF 'MISSING: node_modules/vitest/vitest.mjs' <<<"$T8LOG"; then
    ok "不传接缝时 vitest 步真的在跑（缺省=关）"
  else
    ng "不传接缝时 vitest 步没跑 —— PFAN_SKIP_VITEST 缺省被改成跳过，真 CI 会静默少一层"
  fi
fi

printf '\n== test_guards: %s (fails=%d) ==\n' "$([ "$fails" -eq 0 ] && echo PASS || echo FAIL)" "$fails"
exit "$fails"
