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

echo "== T3: 0 与前导零必须被拒（0 = _FSL 0 风扇停转；080 这类写法十进制读是 80、老八进制读是 0，静默改写都不对）=="
# pfan_parse 现在按十进制解析（080 -> 80），内核八进制截断那条老路已不存在（M9）；
# 本用例守的是 `pfan set` 自己的入口卫生：不接受 0、也不接受前导零。
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

# ---- I2：DEV 节点【缺失】（不是普通文件）—— 旧守卫只看"存在且非字符设备"，缺节点时为假 ----
# 2026-10-06 事故的真实前置是 rmmod 把节点删掉了。此时 -e 为假 -> 守卫判"没问题"，
# 接着 `echo … > "$DEV"` 把节点【凭空创建成普通文件】并记下"尝试满速/已写满速"：
# 既造出了 I6 要防的那个假节点（此后 insmod/devtmpfs 因 EEXIST 复建不了），
# 又写下了到不了硬件的假成功日志。T8/T9 都预先把文件建好，永远踩不到这条分支。
chk_missing(){ # chk_missing <日志> <本应保持不存在的DEV路径> <场景名> <rc>
  local logf="$1" devf="$2" name="$3" rc="$4"
  if [ "$rc" -eq 0 ]; then ng "$name: rc=0（fail-safe 必须非零退出让 systemd 重试）"; return; fi
  if grep -q 'CRITICAL' "$logf" 2>/dev/null && grep -q 'insmod' "$logf" 2>/dev/null; then
    ok "$name: 点名危害+恢复命令: $(grep 'CRITICAL' "$logf" | tail -1 | cut -c1-96)"
  else
    ng "$name: 没有 CRITICAL 危害日志/恢复命令: $(tail -1 "$logf" 2>/dev/null | cut -c1-96)"
  fi
  if grep -q '尝试满速\|已写满速' "$logf" 2>/dev/null; then
    ng "$name: 仍声称尝试/完成写入（节点根本不存在，写不到硬件）: $(grep '尝试满速\|已写满速' "$logf" | tail -1)"
  else
    ok "$name: 没有虚假的写入声明"
  fi
  if [ -e "$devf" ]; then
    ng "$name: 缺失的节点被凭空创建成了 $([ -f "$devf" ] && echo 普通文件 || echo 非普通文件)（$(wc -c < "$devf" 2>/dev/null) 字节）—— insmod/devtmpfs 将因 EEXIST 复建不了"
  else
    ok "$name: 未凭空创建 $devf"
  fi
}

echo "== T10: DEV 节点缺失（rmmod 后）—— 不得创建普通文件、不得声称已写满速（I2）=="
[ -n "${PFAN_DEV:-}" ] && ng "测试环境泄了 PFAN_DEV（会让 -c 判定走测试接缝）"
rm -f "$T/gone1" "$T/mn.log1"
mkplat_hazard "$T/mn1.conf" "$T/gone1"
out=$(timeout 25 env PFAN_PLATFORM_CONF="$T/mn1.conf" PFAN_LOCK="$T/lock" PFAN_LOG="$T/mn.log1" \
      bash core/pfand 2>&1); rc=$?
chk_missing "$T/mn.log1" "$T/gone1" "主分支节点缺失" $rc

echo "== T11: 平台配置缺键 + DEV 节点缺失 —— 候选 fail-safe 分支同样不许创建节点（I2）=="
rm -f "$T/gone2" "$T/mn.log2"
mkplat_hazard "$T/mn2.conf" "$T/gone2" devonly
out=$(timeout 25 env PFAN_PLATFORM_CONF="$T/mn2.conf" PFAN_LOCK="$T/lock" PFAN_LOG="$T/mn.log2" \
      bash core/pfand 2>&1); rc=$?
chk_missing "$T/mn.log2" "$T/gone2" "候选分支节点缺失" $rc

echo "== T12: 配置自校验必须挡住会【停转】的下界（E/CAP/L* ≤ 0 或低于 L0_MIN）=="
# 专家审计 C1/C2 实测：E=0 时自检放行，随后 setL "$E" 在最热温度写 _FSL 1 0；
# CAP=0 且 L*=0 时 apply() 钳到 0，d=0 < DEAD 于是【不写不记日志】，风扇停在
# ensure_s0i3 握手留下的 0 上。自检原本只查"是不是数字"+三条关系。
_rc=/root/backups/_cfgchk-probe
grep -qE 'L0.*< *25|_cfg_bad.*L0|\[ "\$E" -lt' core/pfand && ok "pfand 自检含档位下界判断" || ng "pfand 自检没有档位下界判断（E=0 / CAP=0 可通过 → 停转）"
grep -qE '\[ "\$E" -lt ' core/pfand && ok "显式检查 E 的下界" || ng "没有显式检查 E 的下界"

echo "== T13: 配置自检必须拒绝 E <= CAP（否则最热温度写一个比日常上限更弱的档，日志还写「立即满速」）=="
# 复核自 spec F4（实测）：E=50 CAP=70 被自检放行，启动对齐在 85°C 直接写 _FSL 1 50
# 并记「立即满速 50%」—— 应急比日常上限 CAP=70 还弱，日志却声称满速。
# 既是欠冷却（最热时风扇比平时上限还慢）也是谎报（日志说"立即满速"）。
# 面板那份 validate_params 已就同一条判据同步（server/pfan_core.py，E <= CAP）；
# 守护这份自检是它的对偶 —— 任一边放过 E<=CAP，这个洞就会重新打开。
#
# 判据全部落在【设备侧】与【日志】上，一行源码都不看：
#   a) 日志记「不自洽」，且【没有】参数来源横幅（横幅只在自检通过、进主循环之后才打）
#   b) 假设备收到的最后一次请求是 _FSL 1 100（fail-safe 满速）
#   c) 假设备的回读流水里一条 _FST 都没有（进了主循环就必然有一次 getL 回读）
# 上面 T12 是个 grep 源码的守卫：判据被整段删掉它照样绿。这里不能重复那个错，
# 所以断言的是真实守护在假设备上的行为。
#
# 产物一律留在用例目录里由断言现读，不用 | 分隔的结果串往回传 —— 结果串里的 | 一旦
# 进到 pattern 里就会被当成 case 的分支分隔符，把判据变成永远不触发的死代码。
_ecfg_run(){ # _ecfg_run <用例目录> <E> <CAP> <超时秒>；跑真实守护，产物留在用例目录
  local d="$1" e="$2" cap="$3" tmo="$4"
  mkdir -p "$d"
  : > "$d/dev"; : > "$d/dl"; : > "$d/out"; : > "$d/pfand.log"
  rm -f "$d/st" "$d/emerg" "$d/dl.cnt" "$d/lock"
  printf '{"curve":"s0i3"}\n' > "$d/curve"
  echo 85000 > "$d/temp"                # 热区文件是毫摄氏度；85C >= EMERG(80) 必进应急
  # 热区路径逐用例不同，必须现场生成。值里的前导反斜杠在未加引号的 heredoc 里原样保留
  # （反斜杠只在 $ ` \ 换行 前才是转义符），与 platform/*.conf 的写法一致。
  cat > "$d/plat.conf" <<PEOF
EC_ROOT=\_SB.PCI0.LPCB.EC0
FAN_DEVICE=\_SB.PCI0.LPCB.EC0.TFN1
THERMAL_ZONE=$d/temp
DEV=$d/dev
PEOF
  # 只换 E/CAP 两行，其余参数全部沿用出厂配置：DWELL/IV 等照常，
  # 免得用例顺手放宽了别的条件、把失败原因搅浑。
  sed "s/^E=100$/E=$e/; s/^CAP=70$/CAP=$cap/" config/pfand.conf.example > "$d/conf"
  timeout "$tmo" env PFAN_PLATFORM_CONF="$d/plat.conf" PFAN_DEV="$d/dev" \
    PFAN_DMESG=fake/bin/dmesg PFAN_DMESG_STATE="$d/st" PFAN_DMESG_LOG="$d/dl" \
    PFAN_LOCK="$d/lock" PFAN_CONF="$d/conf" PFAN_CURVE_FILE="$d/curve" \
    PFAN_EMERG_FILE="$d/emerg" PFAN_LOG="$d/pfand.log" \
    bash core/pfand >"$d/out" 2>&1
  # 退出码落盘而不从函数返回：调用方要的产物一律现读，返回值只当"跑过了"。
  echo "$?" > "$d/rc"
  return 0
}
_ecfg_rc(){ cat "$1/rc" 2>/dev/null || echo 缺; }                # 真实守护的退出码
_ecfg_cnt(){ grep -c "$2" "$1/pfand.log" 2>/dev/null || true; }   # 日志命中次数
_ecfg_fsl(){ grep '_FSL 1 ' "$1/dl" 2>/dev/null | tail -1; }      # 假设备累计请求流水末条

chk_ecfg_reject(){ # chk_ecfg_reject <名字> <E> <CAP>
  local name="$1" e="$2" cap="$3" d="$T/t13.$1" devtail n_bad n_loop n_fst
  _ecfg_run "$d" "$e" "$cap" 12
  devtail=$(tail -1 "$d/dev" 2>/dev/null)
  n_bad=$(_ecfg_cnt "$d" '不自洽'); n_bad=${n_bad:-0}
  n_loop=$(_ecfg_cnt "$d" '参数来源'); n_loop=${n_loop:-0}
  n_fst=$(grep -c '_FST' "$d/dl" 2>/dev/null || true); n_fst=${n_fst:-0}
  if [ "$n_bad" -eq 0 ]; then
    ng "$name: E=$e CAP=$cap 被自检【放行】—— 85°C 写 _FSL 1 $e（比日常上限 CAP=$cap 还弱）却记「立即满速」"
    echo "        设备尾=${devtail:-空} 流水末条=$(_ecfg_fsl "$d") 回读=$n_fst 次 日志末行=$(tail -1 "$d/pfand.log" 2>/dev/null)"
    return
  fi
  ok "$name: 自检拒绝 E=$e CAP=$cap 并记不自洽: $(grep '不自洽' "$d/pfand.log" | tail -1 | cut -c21-96)"
  if [ "$n_loop" -ne 0 ]; then
    ng "$name: 记了不自洽却仍进了主循环: $(grep '参数来源' "$d/pfand.log" | tail -1 | cut -c21-96)"
  else
    ok "$name: 没有进主循环（无参数来源横幅）"
  fi
  case "$devtail" in
    *'._FSL 1 100') ok "$name: 假设备最后收到的是 fail-safe 满速: $devtail" ;;
    *) ng "$name: 假设备最后收到的不是满速 100: ${devtail:-空}" ;;
  esac
  if [ "$n_fst" -ne 0 ]; then
    ng "$name: 假设备被回读了 _FST $n_fst 次 —— 自检之后并没有立刻退出"
  else
    ok "$name: 假设备一次都没被回读（确实在进主循环前就退出了）"
  fi
}
chk_ecfg_reject e_lt_cap 50 70
chk_ecfg_reject e_eq_cap 70 70

echo "== T13b: 配置不自洽必须【非零退出】，否则 Restart=on-failure 永不重试 =="
# core/pfand 自己写着这条规则（:123-125，平台配置不可用的那条 fail-safe 已经 exit 1），
# 而配置自检这条 fail-safe 曾经是 exit 0。systemd/pfand.service:11-12 写的是
# Restart=on-failure + RestartSec=15 —— exit 0 等于让守护就此死掉。
#
# 为什么这一条是本分支的责任：E == CAP 原本被【放行】（守护降级运行），所以那时
# 没人关心退出码；本分支把 E <= CAP 收紧成拒绝启动，于是一份原本能跑（虽然降级）的
# 配置被悄悄转成了 dead-loop。实测 E=70 CAP=70：写 _FSL 1 100 然后 exit 0，
# 风扇停在 100% 且 15s 后不再重试，只能等人来改配置。
#
# 改 exit 1 是严格更好，不是把"降级运行"换成"死循环"：重试的代价是零 ——
# 每次启动都会重写同一个 fail-safe 档位（就是紧挨着的那行 echo），
# 重试只是把同一次写入每 15s 重复一遍，配置一改好就自己接管。
# T13 已经断言假设备最后收到的是 _FSL 1 100，所以"重试重复的是同一次写入"有据。
_rc13b="$(_ecfg_rc "$T/t13.e_eq_cap")"
if [ "$_rc13b" = 0 ]; then
  ng "配置不自洽却 exit 0 —— Restart=on-failure 不会重试，风扇停在 100% 直到有人来改配置"
elif [ "$_rc13b" = 缺 ]; then
  ng "没拿到守护的退出码（$T/t13.e_eq_cap/rc 不存在）"
else
  ok "配置不自洽非零退出 rc=$_rc13b（15s 后自动重试，配置一改好就自己接管）"
fi
# 反向对照：下面的 T13c 用 15s 超时跑自洽配置，它进主循环后被 timeout 杀掉（rc=124），
# 与"配置不自洽时立刻退出"是两回事，所以只在这里断言"不自洽时不是 124"。
if [ "$_rc13b" = 124 ]; then
  ng "配置不自洽时守护没立刻退出而是活到超时 —— 自检是在进主循环之后才判的？"
fi

echo "== T13c: 反向对照 —— 自洽配置（E=100 CAP=70）必须照常接管，否则这条守卫就成了一律拒绝 =="
# 少了这一侧，上面两条即使恒真也看不出来。两侧都跑得出不同结论，判据才算被证明可区分。
_d="$T/t13.coherent"
_ecfg_run "$_d" 100 70 15
_nbad=$(_ecfg_cnt "$_d" '不自洽'); _nbad=${_nbad:-0}
_nloop=$(_ecfg_cnt "$_d" '参数来源'); _nloop=${_nloop:-0}
if [ "$_nbad" -ne 0 ]; then
  ng "自洽配置 E=100 CAP=70 被误拒 —— 守卫过宽: $(grep '不自洽' "$_d/pfand.log" | tail -1 | cut -c21-96)"
elif [ "$_nloop" -eq 0 ]; then
  ng "自洽配置 E=100 CAP=70 没能进主循环 —— 反向对照失败，T13 的判据没被证明可区分"
else
  ok "自洽配置照常接管并按应急满速（E=100 > CAP=70）: $(_ecfg_fsl "$_d")"
fi

echo
echo "test_control_paths: fails=$fails"; exit "$fails"
