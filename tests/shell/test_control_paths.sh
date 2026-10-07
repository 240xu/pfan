#!/usr/bin/env bash
# 控制路径测试：覆盖复审 C1（set 死锁）、I1（前导零绕过禁0）、I2（EC88 派生）、I3（fail-safe 退出码）。
#
# 这些路径生产上依赖 /dev/pfanctl + /run/pfanel.lock（都要 root），因此用
# PFAN_DEV / PFAN_LOCK 环境接缝指向 /dev/null 与临时文件来测。
#
# 两个历史坑（都踩过，保留注释防止回退）：
#  1) set 里的 $(pfan get) 是子进程。若 PATH 里没有 pfan，子进程根本起不来，
#     测试会因为"没复现"而假绿。必须放一个替身进去。
#  2) 替身不能用 #!/bin/sh —— Termux 的 /bin/sh 是 /system/bin/sh，
#     它开得出 fd8 但 flock -x 8 报 Bad file descriptor；且 #!/bin/bash / #!/usr/bin/env bash
#     在 Termux 都不存在。用 $(command -v bash) 的绝对路径做 shebang，两边通用。
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
fails=0; ok(){ echo "  [ok]   $1"; }; ng(){ echo "  [FAIL] $1"; fails=$((fails+1)); }
T=$(mktemp -d "${XDG_CACHE_HOME:-$HOME/.cache}/ctrl.XXXXXX"); trap 'rm -rf "$T"' EXIT

BASH_ABS=$(command -v bash)
mkdir -p "$T/bin"
cat > "$T/bin/pfan" <<WRAP
#!$BASH_ABS
# 替身：只做"抢同一把锁"，模拟生产中 set 会 spawn 的 pfan get 子进程。
exec 8>"\$PFAN_LOCK" || exit 1
flock -x 8 || exit 1
echo CHILD_ACQUIRED_LOCK
flock -u 8
WRAP
chmod +x "$T/bin/pfan"

run_set(){ # run_set <level>  -> 输出 rc
  timeout 25 env PATH="$T/bin:$PATH" PFAN_DEV=/dev/null PFAN_LOCK="$T/lock" \
    PFAN_PLATFORM_CONF=platform/platform.conf.example bash core/pfan set "$1" 2>&1
}

echo "== T1: pfan set 必须跑完（不得与自己 spawn 的子进程互等死锁）=="
out=$(run_set 50); rc=$?
if [ $rc -eq 124 ]; then
  ng "挂死 25s —— 复审 C1：父持锁 spawn 子进程，子进程重开锁文件再 flock，互等"
elif [ $rc -ne 0 ]; then
  ng "set 50 rc=$rc: $(echo "$out" | head -1)"
elif echo "$out" | grep -q 'CHILD_ACQUIRED_LOCK'; then
  ng "子进程拿到了锁 —— 说明父进程在 spawn 子命令前已释放，但读回时序需复核"
else
  ok "set 50 跑完且未被子进程卡住: $(echo "$out" | head -1 | cut -c1-46)"
fi

echo "== T2: set 之后锁必须是自由的 =="
if timeout 5 flock -n "$T/lock" true 2>/dev/null; then ok "锁可立即获取"; else ng "锁被残留持有"; fi

echo "== T3: 前导零必须被拒（内核 simple_strtol base 0 会把 080 解析成 0 -> 停转）=="
for v in 0 00 008 080 050 099; do
  out=$(run_set "$v"); rc=$?
  if [ $rc -ne 0 ] && echo "$out" | grep -q '1\.\.120'; then ok "set $v 被拒"
  else ng "set '$v' rc=$rc 未被拒: $(echo "$out" | head -1)"; fi
done

echo "== T4: 合法档位仍被接受 =="
for v in 1 25 100 120; do
  out=$(run_set "$v"); rc=$?
  if [ $rc -eq 0 ] && echo "$out" | grep -q '已设'; then ok "set $v 接受"
  else ng "set $v rc=$rc: $(echo "$out" | head -1)"; fi
done

echo "== T5: pfand 必须用 EC_ROOT 派生 EC88（复审 I2：\$F.EC88 实测一直是 AE_NOT_FOUND）=="
# 只看代码行：注释里解释旧写法的那句不能算残留（与 test_no_hardcode 的处理一致）
_ec_code=$(grep -vE '^[[:space:]]*#' core/pfand)
if echo "$_ec_code" | grep -q '\$F\.EC88'; then
  ng "代码里仍残留 \$F.EC88（派生自 FAN_DEVICE，该路径不存在）"
elif echo "$_ec_code" | grep -q '\$EC\.EC88'; then
  ok "EC88 由 EC_ROOT 派生（\$EC.EC88）"
else
  ng "找不到 EC88 写入点"
fi

echo "== T6: PFAN_PROBE 必须同时暴露 EC_ROOT =="
out=$(PFAN_PROBE=1 PFAN_PLATFORM_CONF=platform/platform.conf.example bash core/pfand 2>&1)
if echo "$out" | grep -qE '^EC_ROOT=\\_SB'; then ok "探针含 EC_ROOT: $(echo "$out" | sed -n 's/^EC_ROOT=//p')"
else ng "探针缺 EC_ROOT"; fi

echo "== T7: 平台配置不可用时 fail-safe 必须非零退出（否则 Restart=on-failure 永不重试）=="
out=$(timeout 25 env PFAN_PLATFORM_CONF=/nonexistent/platform.conf PFAN_CANDIDATES=/nonexistent/cand.txt \
      PFAN_DEV=/dev/null PFAN_LOCK="$T/lock" PFAN_LOG="$T/pfand.log" bash core/pfand 2>&1); rc=$?
if [ $rc -eq 0 ]; then
  ng "fail-safe exit 0 —— 守护就这么死了，100% 满速没人再写"
elif [ $rc -ne 0 ]; then
  ok "fail-safe 非零退出 rc=$rc"
  [ -s "$T/pfand.log" ] && ok "有日志: $(tail -1 "$T/pfand.log" | cut -c1-64)" || ng "没有日志"
fi

# ---- I6：DEV 是普通文件 = 文档化的事故形态（2026-10-06）----
# rmmod 删掉节点后，一条 `echo … > /dev/pfanctl` 把它重建成普通文件，
# 之后所有读写被静默丢弃 ~2min。dev_ok 的 -c 判定会失败，但下一行
# `echo … > "$DEV"` 却"成功"—— 两个 fail-safe 分支于是记录出永远到不了硬件的
# 满速尝试。必须：点名危害 + 给恢复命令、不声称尝试过写入、文件里不留字节。
# 注意必须 PFAN_DEV 不设（走平台配置 + dev_ok 的 -c 分支），否则就是测试接缝的语义了。
mkplat_hazard(){ # mkplat_hazard <conf文件> <普通设备文件> [只留DEV]
  if [ "${3:-}" = devonly ]; then
    printf 'DEV=%s\n' "$2" > "$1"
  else
    printf 'EC_ROOT=\\_SB.PCI0.LPCB.EC0\nFAN_DEVICE=\\_SB.PCI0.LPCB.EC0.TFN1\nTHERMAL_ZONE=/sys/class/thermal/thermal_zone0/temp\nDEV=%s\nEC_CMD=0xB5\n' "$2" > "$1"
  fi
}
chk_hazard(){ # chk_hazard <日志文件> <普通设备文件> <场景名> <rc>
  local logf="$1" devf="$2" name="$3" rc="$4"
  if [ "$rc" -eq 0 ]; then ng "$name: rc=0（fail-safe 必须非零退出让 systemd 重试）"; return; fi
  if grep -q 'CRITICAL' "$logf" 2>/dev/null && grep -q 'rm -f' "$logf" 2>/dev/null; then
    ok "$name: 点名危害+恢复命令: $(grep 'CRITICAL' "$logf" | tail -1 | cut -c1-96)"
  else
    ng "$name: 没有 CRITICAL 危害日志: $(tail -1 "$logf" 2>/dev/null | cut -c1-96)"
  fi
  if grep -q '尝试满速\|已写满速' "$logf" 2>/dev/null; then
    ng "$name: 仍声称尝试/完成写入（到不了硬件的假话）: $(grep '尝试满速\|已写满速' "$logf" | tail -1)"
  else
    ok "$name: 没有虚假的写入声明"
  fi
  if [ -s "$devf" ]; then
    ng "$name: 普通文件里被写进了 $(( $(wc -c < "$devf") )) 字节（写入被静默丢弃却当成成功）"
  else
    ok "$name: 未向普通文件写入任何字节"
  fi
}

echo "== T8: 平台 DEV 是普通文件 —— dev_ok(-c) 失败后不得声称满速写入（I6）=="
: > "$T/hzdev"
mkplat_hazard "$T/hz.conf" "$T/hzdev"
rm -f "$T/hz.log"
out=$(timeout 25 env PFAN_PLATFORM_CONF="$T/hz.conf" PFAN_LOCK="$T/lock" PFAN_LOG="$T/hz.log" \
      bash core/pfand 2>&1); rc=$?
[ -n "${PFAN_DEV:-}" ] && ng "测试环境泄了 PFAN_DEV（会让 dev_ok 走 -e 接缝而不是 -c）"
chk_hazard "$T/hz.log" "$T/hzdev" "平台DEV普通文件" $rc

echo "== T9: 平台配置缺键且 DEV 是普通文件 —— 候选 fail-safe 分支同样不许假报已写满速（I6）=="
: > "$T/hzdev2"
mkplat_hazard "$T/hz2.conf" "$T/hzdev2" devonly
rm -f "$T/hz.log2"
out=$(timeout 25 env PFAN_PLATFORM_CONF="$T/hz2.conf" PFAN_LOCK="$T/lock" PFAN_LOG="$T/hz.log2" \
      bash core/pfand 2>&1); rc=$?
chk_hazard "$T/hz.log2" "$T/hzdev2" "候选分支普通文件" $rc

echo "test_control_paths: fails=$fails"; exit "$fails"
