#!/usr/bin/env bash
# pfand 循环的进程级端到端测试：用 fake/ 层（假热区文件 + 假设备 + 假 dmesg）驱动真实守护。
# 这是 P1 复审 I6 裁决要求 P2 先建的那一层。
#
# 三个前提（都必须成立，否则测的是假象）：
#  1) 新接缝的【缺省值必须等于生产值】—— 见 T0；
#  2) fake dmesg 的输出格式与实机 `dmesg | grep pfanctl` 一致（RESULT [0,L,4294967295]）；
#  3) 坏路径不产生 RESULT（fail-closed），与 pfanctl.c 实测一致。
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
fails=0; ok(){ echo "  [ok]   $1"; }; ng(){ echo "  [FAIL] $1"; fails=$((fails+1)); }
PIDD=""   # 必须先初始化：trap 会在 set -u 下提前调用 stop
stop(){ if [ -n "$PIDD" ]; then kill "$PIDD" 2>/dev/null; wait "$PIDD" 2>/dev/null; PIDD=""; fi; }
T=$(mktemp -d "${XDG_CACHE_HOME:-$HOME/.cache}/loop.XXXXXX"); trap 'stop; rm -rf "$T"' EXIT

echo "== T0: 新接缝缺省值必须等于生产值 =="
grep -q 'PFAN_DMESG:-dmesg' core/pfand && ok "PFAN_DMESG 默认 dmesg" || ng "PFAN_DMESG 默认值漂移"
grep -q 'PFAN_CONF:-/etc/pfand.conf' core/pfand && ok "PFAN_CONF 默认 /etc/pfand.conf" || ng "PFAN_CONF 默认值漂移"
grep -q 'PFAN_CURVE_FILE:-/var/lib/pfanel/curve.state' core/pfand && ok "PFAN_CURVE_FILE 默认正确" || ng "PFAN_CURVE_FILE 默认值漂移"
grep -qE 'PFAN_PORT"?, *"?8789' server/pfanel.py && ok "PFAN_PORT 默认 8789" || ng "PFAN_PORT 默认值漂移"
grep -q 'PFAN_EMERG_FILE:-/var/lib/pfanel/emerg.state' core/pfand && ok "PFAN_EMERG_FILE 默认 /var/lib/pfanel/emerg.state" || ng "PFAN_EMERG_FILE 默认值漂移或缺失"
if grep -rhE 'PFAN_(DMESG|CONF|CURVE_FILE|PORT|DEV|LOCK|PROBE)=' systemd/ 2>/dev/null | grep -q .; then
  ng "systemd 单元里出现了测试接缝"
else ok "systemd 单元未设置任何测试接缝"; fi

echo "== T1: fake 平台配置 + 假热区可读 =="
if [ -f fake/platform.conf ]; then
  echo 55000 > "$T/temp"   # 热区文件是【毫摄氏度】，readT 会 /1000
  sed "s|^THERMAL_ZONE=.*|THERMAL_ZONE=$T/temp|" fake/platform.conf > "$T/plat.conf"
  v=$(PFAN_PLATFORM_CONF="$T/plat.conf" bash -c '. core/platform.sh; pfan_plat THERMAL_ZONE' 2>/dev/null)
  [ "$v" = "$T/temp" ] && [ -r "$v" ] && ok "THERMAL_ZONE 指向假热区: $v" || ng "THERMAL_ZONE='$v'"
else ng "缺 fake/platform.conf"; fi

echo "== T2: 假 dmesg 输出格式与实机一致 =="
if [ -x fake/bin/dmesg ]; then
  fmt=$(PFAN_DMESG_STATE="$T/st" PFAN_DMESG_LOG="$T/dl" PFAN_DEV="$T/dev" \
        bash -c 'echo 30 > "$T_DEV"; :' 2>/dev/null; true)
  # 直接喂一个 _FSL 请求再读
  mkdir -p "$T/fm"; echo '_SB.PCI0.LPCB.EC0.TFN1._FSL 1 40' > "$T/dev"
  out=$(PFAN_DEV="$T/dev" PFAN_DMESG_STATE="$T/st" PFAN_DMESG_LOG="$T/dl" fake/bin/dmesg 2>&1)
  echo "  fake dmesg: $out"
  if echo "$out" | grep -qE 'pfanctl: RESULT \[0,[0-9]+,[0-9]+\]'; then
    ok "格式与实机一致"
  else ng "格式不符（实机形如 RESULT [0,40,4294967295]）: $out"
  fi
else ng "缺 fake/bin/dmesg 或不可执行"; fi

echo "== T3: 守护能用假设备跑起来并写出档位 =="
: > "$T/dev"; : > "$T/dl"; rm -f "$T/st"; echo 55000 > "$T/temp"   # 热区文件是【毫摄氏度】，readT 会 /1000
printf 'IDLE=50\nL0=25\nT1=56\nL1=30\nT2=62\nL2=40\nT3=67\nL3=50\nT4=72\nL4=60\nT5=79\nL5=70\nEMERG=80\nE=100\nEMERG_REL=75\nCAP=70\nTRIM=6\nGAIN=1\nHYST=3\nDWELL=2\nDEAD=2\nIV=2\n' > "$T/conf"
printf '{"curve":"s0i3"}\n' > "$T/curve"
stop
timeout 14 env PFAN_PLATFORM_CONF="$T/plat.conf" PFAN_DEV="$T/dev" PFAN_DMESG=fake/bin/dmesg \
  PFAN_DMESG_STATE="$T/st" PFAN_DMESG_LOG="$T/dl" PFAN_LOCK="$T/lock" PFAN_CONF="$T/conf" \
  PFAN_CURVE_FILE="$T/curve" PFAN_EMERG_FILE="$T/emerg" PFAN_LOG="$T/pfand.log" \
  bash core/pfand >"$T/out" 2>&1 &
PIDD=$!
sleep 5
# 必须查【累计流水】$T/dl 而不是 $T/dev：假设备文件只保留最后一次操作，
# 而 getL 之后写进去的必然是 _FST 读请求 —— 拿它断言会得到假阴性。
if grep -q '平台配置不可用' "$T/pfand.log" 2>/dev/null; then
  ng "进了 fail-safe 而非真循环: $(tail -2 "$T/pfand.log" | tr '\n' '|')"
elif grep -q '_FSL 1 30' "$T/dl" 2>/dev/null; then
  ok "真循环按曲线写出 30% (want_for(55000)=L1=30): $(grep '_FSL 1 ' "$T/dl" | tail -1)"
elif grep -q '_FSL 1' "$T/dl" 2>/dev/null; then
  ng "写入了但档位不符 want_for(55000)=30: $(grep '_FSL 1' "$T/dl" | tail -3 | tr '\n' '|')"
else
  ng "假设备流水里没有 _FSL 写入 (dl=$(tail -3 "$T/dl" 2>/dev/null | tr '\n' '|'))"
fi

echo "== T4: 温度上升触发升档 =="
before=$(grep -c '升温\|微调' "$T/pfand.log" 2>/dev/null || true); before=${before:-0}
echo 75000 > "$T/temp"; sleep 5
after=$(grep -c '升温\|微调' "$T/pfand.log" 2>/dev/null || true); after=${after:-0}
[ "$after" -gt "$before" ] && ok "55C->75C 升档 ($before -> $after)" || ng "未升档 (log $before->$after) tail=$(tail -3 "$T/pfand.log" 2>/dev/null | tr '\n' '|')"

echo "== T5: 过热必须打到应急档 =="
# ⚠ 旧判据 `grep -qE '应急|set=100'` 会匹配启动横幅里的【应急80/100】—— 那一行是参数
# 骨架，与应急触发毫无关系。于是 T5 在守护还没看到 85C 时就"通过"，T6 紧跟着把温度改成
# 77C，守护全程没见过 85C，自然写不出 100 —— 2026-10-06 ci 间歇性失败的真实根因。
# 改成：轮询等【真实事件】（日志"应急满速"或设备写入 100），最多 16s。
echo 85000 > "$T/temp"
hit5=0
for i in $(seq 1 8); do
  sleep 2
  if grep -q '应急满速' "$T/pfand.log" 2>/dev/null || grep -q '_FSL 1 100' "$T/dl" 2>/dev/null; then
    hit5=1; break
  fi
done
if [ "$hit5" = 1 ]; then
  ok "85C >= EMERG(80) → 应急满速 (第 $((i*2))s 观察到)"
else ng "未见应急 (tail=$(tail -3 "$T/pfand.log" 2>/dev/null | tr '\n' '|'))"
fi

echo "== T6: 应急滞回 —— 回落到 [EMERG_REL, EMERG) 必须仍锁在满速 =="
# EMERG=80, EMERG_REL=75。77 落在两者之间：want_for(77)=L5=70，
# 但滞回要求仍停在 100，直到温度跌破 75。
echo 77000 > "$T/temp"; sleep 6
lastdev=$(grep '_FSL 1 ' "$T/dl" 2>/dev/null | tail -1)
if grep -q '应急解除' "$T/pfand.log" 2>/dev/null; then
  ng "77C 就解除了应急（滞回失效）: $(grep '应急解除' "$T/pfand.log" | tail -1)"
elif echo "$lastdev" | grep -q '_FSL 1 100'; then
  ok "77C 仍锁在 100%（滞回生效）: $lastdev"
else
  ng "77C 时档位掉到非100: $lastdev"
fi

echo "== T7: 重启后应急锁定必须恢复（backlog ⑬）=="
stop
sleep 1
timeout 14 env PFAN_PLATFORM_CONF="$T/plat.conf" PFAN_DEV="$T/dev" PFAN_DMESG=fake/bin/dmesg \
  PFAN_DMESG_STATE="$T/st" PFAN_DMESG_LOG="$T/dl" PFAN_LOCK="$T/lock" PFAN_CONF="$T/conf" \
  PFAN_CURVE_FILE="$T/curve" PFAN_EMERG_FILE="$T/emerg" PFAN_LOG="$T/pfand.log" bash core/pfand >>"$T/out" 2>&1 &
PIDD=$!
sleep 5
after_restart=$(grep '_FSL 1 ' "$T/dl" 2>/dev/null | tail -1)
if grep -q '恢复应急锁定' "$T/pfand.log" 2>/dev/null && echo "$after_restart" | grep -q '_FSL 1 100'; then
  ok "重启后恢复应急锁定，仍 100%: $after_restart"
elif echo "$after_restart" | grep -q '_FSL 1 100'; then
  ok "重启后仍是 100%（虽未打恢复日志）: $after_restart"
else
  ng "重启后应急锁定丢失，掉到: $after_restart（want_for(77)=70 即为 ⑬ 的原始缺陷）"
fi

echo "== T8: 跌破 EMERG_REL 才解除应急 =="
echo 70000 > "$T/temp"; sleep 6
if grep -q '应急解除' "$T/pfand.log" 2>/dev/null; then
  ok "70C <= EMERG_REL(75) 解除应急: $(grep '应急解除' "$T/pfand.log" | tail -1)"
else
  ng "70C 仍未解除应急: $(tail -3 "$T/pfand.log" | tr '\n' '|')"
fi
stop

echo "test_pfand_loop: fails=$fails"; exit "$fails"
