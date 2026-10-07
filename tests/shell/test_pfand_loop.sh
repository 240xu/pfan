#!/usr/bin/env bash
# pfand 循环的进程级端到端测试：用 fake/ 层（假热区文件 + 假设备 + 假 dmesg）驱动真实守护。
# 这是 P1 复审 I6 裁决要求 P2 先建的那一层。
#
# 三个前提（都必须成立，否则测的是假象）：
#  1) 新接缝的【缺省值必须等于生产值】—— 见 T0；
#  2) fake dmesg 的输出格式与实机 `dmesg | grep pfanctl` 一致（RESULT [0,L,4294967295]）；
#  3) fail-closed：只有已知好路径（platform.conf 的 FAN_DEVICE 上的 _FSL 1 <n>/_FST、
#     EC_ROOT 上的 EC88）上的合法请求才产生 RESULT；坏路径/坏格式/设备文件缺失或读不出
#     一律不产生（与 pfanctl.c get_handle 失败分支一致；I1：否则写失败的死设备会被读成
#     "新鲜读数"，E2E 层永远抓不到 getL 的 fail-open）。
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
fails=0; ok(){ echo "  [ok]   $1"; }; ng(){ echo "  [FAIL] $1"; fails=$((fails+1)); }
PIDD=""   # 必须先初始化：trap 会在 set -u 下提前调用 stop
stop(){ if [ -n "$PIDD" ]; then kill "$PIDD" 2>/dev/null; wait "$PIDD" 2>/dev/null; PIDD=""; fi; }
# 用与 T3 完全相同的接缝启动真实守护（新块共用，避免漏掉某个 PFAN_* 接缝）
startd(){ # startd <timeout秒>
  timeout "$1" env PFAN_PLATFORM_CONF="$T/plat.conf" PFAN_DEV="$T/dev" PFAN_DMESG=fake/bin/dmesg \
    PFAN_DMESG_STATE="$T/st" PFAN_DMESG_LOG="$T/dl" PFAN_LOCK="$T/lock" PFAN_CONF="$T/conf" \
    PFAN_CURVE_FILE="$T/curve" PFAN_EMERG_FILE="$T/emerg" PFAN_LOG="$T/pfand.log" \
    bash core/pfand >>"$T/out" 2>&1 &
  PIDD=$!
}
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
  # 直接喂一个 _FSL 请求再读。必须带上 PFAN_PLATFORM_CONF：I1 之后 fake dmesg
  # 只对已知风扇路径产生 RESULT（坏路径 fail-closed），没有平台配置就一条都不吐。
  mkdir -p "$T/fm"; echo '_SB.PCI0.LPCB.EC0.TFN1._FSL 1 40' > "$T/dev"
  out=$(PFAN_DEV="$T/dev" PFAN_DMESG_STATE="$T/st" PFAN_DMESG_LOG="$T/dl" \
        PFAN_PLATFORM_CONF="$T/plat.conf" fake/bin/dmesg 2>&1)
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
# 120s 而不是 14s：这个守护要活过 T3(5s) + T4 + T5(最长 16s 轮询) + T6(6s) ≈ 30s。
# 旧的 14s 会在 T6 进行中把它杀掉，于是 T6 读到应急【之前】那一档(70)、
# 而 _FSL 1 100 还来不及被 dmesg 捕获 —— 表现成"滞回失效"的假故障。
timeout 120 env PFAN_PLATFORM_CONF="$T/plat.conf" PFAN_DEV="$T/dev" PFAN_DMESG=fake/bin/dmesg \
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
  _alive=no; kill -0 "$PIDD" 2>/dev/null && _alive=yes
  _lg=$(tail -6 "$T/pfand.log" 2>/dev/null | tr '\n' '|')
  _dw=$(grep '_FSL 1 ' "$T/dl" 2>/dev/null | tail -5 | tr '\n' '|')
  ng "77C 时档位掉到非100: $lastdev | 守护=$_alive | 日志=$_lg | 写入=$_dw"
fi

echo "== T7: 重启后应急锁定必须恢复（backlog ⑬）=="
stop
sleep 1
timeout 120 env PFAN_PLATFORM_CONF="$T/plat.conf" PFAN_DEV="$T/dev" PFAN_DMESG=fake/bin/dmesg \
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

echo "== T9: 对账 —— 外部改档必须被发现并重新收敛（⑦ 抓到过真实事故）=="
# T8 结束态：temp=70000、应急已解除。清流水便于断言"注入之后的新写入"。
: > "$T/dl"; rm -f "$T/st"
startd 45
# 等启动对齐真的写过一次（_FSL 1 60 = want_for(70)），避免注入与启动状态写入互踩
for i in $(seq 1 40); do sleep 0.25; grep -q '_FSL 1 60' "$T/dl" 2>/dev/null && break; done
grep -q '_FSL 1 60' "$T/dl" 2>/dev/null || ng "T9 前置：启动对齐没写出 60（后续对账断言无意义）"
n9=$(grep -c '对账:' "$T/pfand.log" 2>/dev/null || true); n9=${n9:-0}
d9=$(grep -c '_FSL 1 ' "$T/dl" 2>/dev/null || true); d9=${d9:-0}
# 外部改档：面板/pfan/别的实例直接动档位 —— 假 dmesg 的档位状态就是"实际档"
echo 99 > "$T/st"
hit9=0
for i in $(seq 1 20); do
  # 每轮重新注入：getL 的第一个 dmesg 调用会读 DEV 尾部，若尾部是 `_FSL 1 60`
  # 就会把 60 写回 st、覆盖我们注入的 99。这是测试接缝的竞态，不是守护的缺陷 ——
  # 用重复注入消除它（断言"对账必须发现 99"本身一字未改）。
  echo 99 > "$T/st"
  sleep 1
  if grep -q '实际=99' "$T/pfand.log" 2>/dev/null; then hit9=1; break; fi
done
if [ "$hit9" = 1 ]; then
  ok "对账发现外部改档: $(grep '实际=99' "$T/pfand.log" | tail -1)"
else
  # fake dmesg 的拒绝原因（"不产生 RESULT: ..."）打在 stderr，被 startd 重定向到 $T/out ——
  # getL 拿不到新 RESULT 就一直返回空，对账于是永远不触发；不看这条根本定位不到。
  _out=$(tail -6 "$T/out" 2>/dev/null | tr '\n' '|')
  # 卡在哪一步决定修哪里：活着却不动 = 阻塞在 flock/子进程；死了 = 需要看 stderr。
  _c=$(pgrep -P "$PIDD" 2>/dev/null | head -1)
  if [ -n "$_c" ] && kill -0 "$_c" 2>/dev/null; then
    _st="alive(pid=$_c wchan=$(cut -d' ' -f1 /proc/$_c/wchan 2>/dev/null || echo '?'))"
  elif kill -0 "$PIDD" 2>/dev/null; then _st="wrapper alive, child gone"
  else _st="DEAD"; fi
  # 它在等谁：孙进程的 comm+wchan 直接指认（flock / 假dmesg / cat / sed）。
  _kids=$(ps -o pid=,comm=,wchan= --ppid "$_c" 2>/dev/null | tr '\n' ';' | tr -s ' ')
  _st="$_st 孙进程=[$_kids]"
  # getL 里假 dmesg 的 stderr 被 `2>/dev/null` 吞掉，所以 $T/out 恒为空 —— 失败时
  # 必须用同一套接缝【手动跑一次】假 dmesg，才看得见它到底吐不吐 RESULT。
  _fr=$(PFAN_DEV="$T/dev" PFAN_DMESG_STATE="$T/st" PFAN_DMESG_LOG="$T/dl" \
        PFAN_PLATFORM_CONF="$T/plat.conf" bash fake/bin/dmesg 2>&1 | tr '\n' '|')
  ng "对账未触发: 守护=$_st | 手动假dmesg输出=$_fr | st=$(cat "$T/st" 2>/dev/null) | dev尾=$(tail -1 "$T/dev" 2>/dev/null) | 日志=$(tail -3 "$T/pfand.log" | tr '\n' '|')"
fi
# 重新收敛：written 被纠正后，微调门一到必须真的把档位写回设备
hit9b=0
for i in $(seq 1 16); do
  sleep 1
  d=$(grep -c '_FSL 1 ' "$T/dl" 2>/dev/null || true); d=${d:-0}
  if [ "$d" -gt "$d9" ]; then hit9b=1; break; fi
done
if [ "$hit9b" = 1 ]; then
  ok "对账后重新写入档位: $(grep '_FSL 1 ' "$T/dl" | tail -1)"
else
  ng "注入后没有新的 _FSL 写入（外部改档后风扇停在错档）: d9=$d9 dl=$(tail -3 "$T/dl" | tr '\n' '|')"
fi

echo "== T10: 传感器故障 —— 热区读空 -> T<0 必须一个 IV 内满速（审计最严重一类）=="
# 覆盖循环里的 T<0 分支。删掉 `if [ "$T" -lt 0 ]` 守卫的话 want_for(-1)=L0=25，
# 旧套件全绿（所有既有用例都喂合法毫摄氏度）—— 所以这条断言就是那个分支的牙。
# 判据用 $T/dev 尾行而不是流水 $T/dl：T<0 分支 setL 后直接 continue，根本不调 getL，
# dmesg 不会被触发、流水不会追加 —— 只有设备文件本身留着刚写进去的档位。
n10=$(grep -c '温度读取失败' "$T/pfand.log" 2>/dev/null || true); n10=${n10:-0}
dev_before=$(tail -1 "$T/dev" 2>/dev/null || true)
: > "$T/temp"    # 空文件 -> readT 得 T=-1
hit10=0
for i in $(seq 1 8); do
  sleep 1
  a=$(grep -c '温度读取失败' "$T/pfand.log" 2>/dev/null || true); a=${a:-0}
  d=$(tail -1 "$T/dev" 2>/dev/null || true)
  if [ "$a" -gt "$n10" ] && echo "$d" | grep -q '_FSL 1 100'; then hit10=1; break; fi
done
if [ "$hit10" = 1 ]; then
  ok "T<0 -> ${i}s 内设备写入 100% 且记日志: $(grep '温度读取失败' "$T/pfand.log" | tail -1)"
else
  ng "传感器故障未满速 (IV=2 却 8s 无事件): dev_before='$dev_before' dev_now='$(tail -1 "$T/dev" 2>/dev/null)' log=$(tail -3 "$T/pfand.log" | tr '\n' '|')"
fi
echo 70000 > "$T/temp"

echo "== T11: 冷启动即过热 —— 必须立刻满速，不许在 CAP(70%) 停一个 IV（I8）=="
# 全新启动 + 85C + 应急锁文件为 0：⑬ 不得代劳，否则测不出 apply() 的 CAP 钳制。
stop; sleep 1
: > "$T/dl"; rm -f "$T/st" "$T/dl.cnt"
echo 85000 > "$T/temp"; echo 0 > "$T/emerg"
startd 20
# 窗口必须覆盖【冷启动耗时 + 一个 IV】：守护启动要跑平台探测、一次 getL（多次子进程）
# 才走到启动写，之后第一个循环周期还要 sleep IV=2。早先这里只等 3s，落在这个耗时的
# 边界上（I8 的语义不是"3 秒内"，见下）。
first=""; sample_at=""
for i in $(seq 1 32); do          # 32 × 0.25s = 8s ≫ 启动 + IV
  sleep 0.25
  first=$(grep '_FSL 1 ' "$T/dl" 2>/dev/null | grep -v '_FSL 1 0' | head -1)
  if [ -n "$first" ]; then sample_at=$((i * 250))ms; break; fi
done
# I8 真正要守的三条（缺一不可）：
#  1) 冷启动分支确实走到了（否则测的是 ⑬ 恢复锁或曲线对齐的副作用）
#  2) 启动期间【从未】写出 70 —— apply() 的 CAP 钳制一旦生效，风扇就在 70% 停到
#     第一个 IV 之后的应急分支，CPU 已 ≥80C 时这是真实过热窗口
#  3) 首个非零写入就是 100
if [ -z "$first" ]; then
  ng "8s 内没有任何档位写入 (dl=$(tail -3 "$T/dl" 2>/dev/null | tr '\n' '|') log=$(tail -3 "$T/pfand.log" 2>/dev/null | tr '\n' '|'))"
elif echo "$first" | grep -q '_FSL 1 100'; then
  ok "冷启动 85C 首个非零档位写入即 100%（${sample_at}）: $first"
else
  ng "首写不是 100% 而是 $first（apply 把 want_for(85)=100 钳到 CAP=70 —— I8）"
fi
if grep -q '启动时 T=85C >= EMERG' "$T/pfand.log" 2>/dev/null; then
  ok "走了冷启动过热分支（不是靠 ⑬ 恢复锁兜底）"
else
  ng "没走冷启动过热分支: $(tail -3 "$T/pfand.log" 2>/dev/null | tr '\n' '|')"
fi
if grep -q '_FSL 1 70' "$T/dl" 2>/dev/null; then
  ng "启动期间写出过 70%（CAP 钳制生效）: $(grep '_FSL 1 ' "$T/dl" | tr '\n' '|')"
else
  ok "启动期间从未写出 70%（apply 的 CAP 钳制没生效）"
fi

echo "== T12: 设备写失败 —— getL 必须返回空，不拿旧档冒充新鲜读数（I1）=="
# chmod 000 同时废掉写与读：守护的写全部失败、fake dmesg 读不到请求。
# 旧 fake dmesg 无条件吐新鲜 RESULT -> getL 把陈旧档位当实际值 -> 触发假对账。
stop; sleep 1
echo 70000 > "$T/temp"; echo 0 > "$T/emerg"
startd 45
sleep 4
n12=$(grep -c '对账:' "$T/pfand.log" 2>/dev/null || true); n12=${n12:-0}
u12=$(grep -c '升温' "$T/pfand.log" 2>/dev/null || true); u12=${u12:-0}
chmod 000 "$T/dev"       # 死设备：echo > dev 失败、tail dev 读不到
echo 75000 > "$T/temp"   # 需要升到 70% —— 守护必须在设备已死的情况下仍发起重推
hit12a=0
# 窗口按【死设备下的真实周期】算：getL 拿不到 RESULT 会把 20×0.12s 烧满(2.4s)，
# 加上 IV=2 → 一个周期 ≈4.4s；升档判断在 getL 之后，最坏要等两个周期 ≈8.8s。
# 旧的 8s 正好卡在中间，于是间歇性失败。
for i in $(seq 1 20); do
  sleep 1
  u=$(grep -c '升温' "$T/pfand.log" 2>/dev/null || true); u=${u:-0}
  if [ "$u" -gt "$u12" ]; then hit12a=1; break; fi
done
if [ "$hit12a" = 1 ]; then
  ok "死设备期间仍记录了升档重推（written 被推进，写失败也没假装完成）: $(grep '升温' "$T/pfand.log" | tail -1)"
else
  ng "设备写失败后守护没有重推升档: $(tail -3 "$T/pfand.log" | tr '\n' '|')"
fi
sleep 4    # 再覆盖至少一个完整循环：旧 fake 在这里会吐新鲜 RESULT 伪造对账
n12b=$(grep -c '对账:' "$T/pfand.log" 2>/dev/null || true); n12b=${n12b:-0}
if [ "$n12b" -eq "$n12" ]; then
  ok "死设备期间对账计数不变（getL 为空 -> 没把陈旧档位当实际值）"
else
  ng "死设备期间触发了对账 —— 陈旧 RESULT 被当成实际档位: $(grep '对账:' "$T/pfand.log" | tail -1)"
fi
chmod 644 "$T/dev"       # 设备恢复，读回/对账必须自己活过来
hit12c=0
for i in $(seq 1 10); do
  sleep 1
  n=$(grep -c '对账:' "$T/pfand.log" 2>/dev/null || true); n=${n:-0}
  if [ "$n" -gt "$n12b" ]; then hit12c=1; break; fi
done
if [ "$hit12c" = 1 ]; then
  ok "设备恢复后对账恢复: $(grep '对账:' "$T/pfand.log" | tail -1)"
else
  ng "设备恢复后守护未恢复对账（读回路径卡死）"
fi
stop

echo "test_pfand_loop: fails=$fails"; exit "$fails"
