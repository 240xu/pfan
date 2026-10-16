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

_ecfg_run(){ # _ecfg_run <用例目录> <E> <CAP> <超时秒> [额外sed]；跑真实守护，产物留在用例目录
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
  # 只换显式给出的那几个键，其余参数全部沿用出厂配置：DWELL/IV 等照常，
  # 免得用例顺手放宽了别的条件、把失败原因搅浑。
  # 第 5 个参数（可选）= 额外的 sed 表达式，用来改 L0..L5 这类【没有形参】的键。
  # 必须用 ";" 分隔：GNU sed 会把 s/// 后面那个空格读成 flag，一个空格就报
  # "unknown option to `s'"。后果不是"安静地过"而是更阴的一种：sed 整条失败、
  # $d/conf 留空，守护退回脚本内置缺省值，于是【这条用例根本没被构造出来】，
  # 断言会以"守卫坏了"的样子报错，误导排查方向（2026-10-11 写本用例时先踩过）。
  local expr="s/^E=100$/E=$e/; s/^CAP=70$/CAP=$cap/"
  [ -n "${5:-}" ] && expr="$expr; $5"
  sed "$expr" config/pfand.conf.example > "$d/conf"
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
# 下界判据有两种字面（core/pfand 里 E/CAP/L0 一条、L1..L5 一条），
# 所以「有没有命中下界判据」必须用二选一，不能只认其中一句。
_ecfg_bnd(){ grep -c '档位下界非法\|低于 _FPS 最低档 25' "$1/pfand.log" 2>/dev/null || true; }

echo "== T12: 档位下界守卫必须是【行为】不是 grep —— E/CAP/L0..L5 任一 < 25 都必须真的挡住停转 =="
# ---- 为什么原来那两条 grep 是假的（2026-10-09 的 319fdc3 加进来的）----
# 原文是 grep -qE 'L0.*< *25|_cfg_bad.*L0|\[ "\$E" -lt' core/pfand，验的是
# "某段文本在文件里"，不是"行为成立"。实测把它换成
#     if [ "$E" -lt 25 ] || [ "$CAP" -lt 25 ] || [ "$L0" -lt 25 ]
#  -> if [ "$E" -lt 0 ]  || [ "$CAP" -lt 0 ]  || [ "$L0" -lt 0 ]
# （等于把整条下界检查关掉、恢复"最热温度写 _FSL 1 0"的停转缺陷）之后，
# 整份测试照样 fails=0。T13 的注释已经写过"守卫被整段删掉它照样绿"，
# 这里是同一个错的第二份拷贝。
#
# ---- 判据全在运行时 ----（复用下面那套 _ecfg_run 假设备，一行源码都不看）
# 每例都跑【真实守护】（85°C，>= EMERG），然后断言四件事：
#   a) 假设备最后收到的是 ._FSL 1 100 —— 绝不能是 _FSL 1 0（0 就是风扇停转）
#   b) 日志命中的必须是【本守卫自己那一条】判据，不是隔壁的关系判据顺手抓的
#   c) 没有参数来源横幅 + 一次 _FST 都没回读 => 确实在进主循环【之前】就退出了
#   d) 退出码非 0 且不是 124（124 = 被 timeout 杀 = 还活着在主循环里）
#
# ---- 两条必须说在前面的话 ----
# 1) 【设备收到 100 这件事本身分辨不出接受与拒绝】：合法配置在 85°C 走应急分支
#    也是 setL "$E" = _FSL 1 100，字节一模一样（T13c 实测）。所以 a 是安全契约
#    （绝不能写出 0），分辨靠 b/c/d。
# 2) b 不能弱写成"日志里有某句下界的话"：E=0 / CAP=0 还会同时被 E<=CAP 的关系
#    判据抓住（core/pfand:203-207）。那样的话把下界那行整个改成 -lt 0 之后，
#    E=0 照样被拒、行为一模一样 —— 那样的断言在测关系判据，不是在测本守卫。
#    所以每一例都点名【该命中哪一条】。
#
# ---- 哪些是真的"独立钉住"，哪些不是（2026-10-11 复审后按实测改写）----
# 前一版这里写着 l0_24/l5_24/iso"单独钉住"两条下界检查。那句话站不住：
# 它只被 M1/M2（把检查整个关掉）验证过，没被边界变异验证过。
# 2026-10-11 复审实测：把 L1..L5 循环的 -lt 25 改成 -le 25，整份测试照样 fails=0。
# 原因不是通用检查在替它抓（见下），而是【没有任何一个用例把 25 放到 L1..L5 上】：
# 出厂配置的 L1..L5 是 30/40/50/60/70，而唯一压在下界上的出厂值是 L0=25 ——
# L0 归 :213 那行管，根本走不到 L1..L5 循环。边界根本没被触发过。
# 先把另外两条判据各自能抓什么摆清楚，否则"独立"二字没有意义：
#   · 通用循环（:183-190）只查【空/非数字】。实测 L5=-1 被它抓（配置项 L5 非法），
#     但 L5=24 这种"合法数字、越界小值"它一律放过。所以它从不替下界检查背锅。
#   · 关系判据（:203-204）只涉及 EMERG_REL/EMERG、T5/EMERG、L5/CAP、E/CAP，
#     【完全不涉及 L0 与 L1..L4】。
# 由此可证（不是推断，是逐条对上面的判据范围做的排除）：
#   · L0     —— 独立钉住：除 :213 外无任何判据会碰 L0=24。
#   · L1..L5 —— 独立钉住：L5=24 不触发 L5>CAP；L1..L4 连关系判据都进不去。
#   · E      —— 【不可能独立钉住】：要让 E<25 且不被 E<=CAP 抓住，就得 CAP<E<25，
#               于是 CAP<25，:213 的 CAP 子句【同时】成立。E 子句永远不是唯一原因。
#   · CAP    —— 【不可能独立钉住】：要让 CAP<25 且不被 L5>CAP 抓住，就得 L5<=CAP<25，
#               于是 L5 越界，L1..L5 循环【同时】成立。
# 所以 e0/cap0 断言的是"这份配置被 :213 那行挡下了"（M1/M4/M5 实测可区分），
# 【不】断言"没有 E<=CAP 它就挡不住"—— 后者是 core/pfand 的性质，不是本测试的。
_chk_bnd_reject(){ # <名字> <E> <CAP> <额外sed> <该命中的下界判据>
  local name="$1" e="$2" cap="$3" extra="$4" want="$5" d="$T/t12.$1"
  _ecfg_run "$d" "$e" "$cap" 12 "$extra"
  local devtail rc nb nl nr
  devtail=$(tail -1 "$d/dev" 2>/dev/null)
  rc=$(_ecfg_rc "$d"); nb=$(_ecfg_cnt "$d" "$want"); nl=$(_ecfg_cnt "$d" '参数来源')
  nr=$(grep -c '_FST' "$d/dl" 2>/dev/null || true)
  nb=${nb:-0}; nl=${nl:-0}; nr=${nr:-0}
  case "$devtail" in                                              # a) 设备侧
    *'._FSL 1 100') ok "$name: 假设备最后收到的是 fail-safe 满速 100（不是 0）: $devtail" ;;
    *'._FSL 1 0')   ng "$name: 假设备收到了 _FSL 1 0 —— 风扇停转，本守卫就是要防这个" ;;
    *)               ng "$name: 假设备最后收到的不是满速 100: ${devtail:-空}" ;;
  esac
  if [ "$nb" -ge 1 ]; then                                          # b) 点名判据
    ok "$name: 命中的是本守卫那条判据: $(grep "$want" "$d/pfand.log" | tail -1 | cut -c21-96)"
  else
    ng "$name: 没有命中下界判据「$want」—— 可能只是被关系判据顺手抓了，那样测的不是本守卫"
  fi
  if [ "$nl" -eq 0 ]; then                                           # c) 没进主循环
    ok "$name: 没有进主循环（无参数来源横幅）"
  else
    ng "$name: 进了主循环: $(grep '参数来源' "$d/pfand.log" | tail -1 | cut -c21-96)"
  fi
  if [ "$nr" -eq 0 ]; then                                           # c) 没回读
    ok "$name: 假设备一次都没被回读 _FST（确实在 getL 之前就退出了）"
  else
    ng "$name: 假设备被回读了 _FST $nr 次 —— 自检之后并没有立刻退出"
  fi
  if [ "$rc" = 124 ]; then                                           # d) 退出码
    ng "$name: rc=124 —— 守护活到了超时，说明自检之后它还在跑"
  elif [ "$rc" = 缺 ] || [ "$rc" = 0 ]; then
    ng "$name: rc=$rc —— 必须非零退出，Restart=on-failure 才会在 15s 后重试"
  else
    ok "$name: 自检后立刻非零退出 rc=$rc"
  fi
}
# E=0 / CAP=0：这两种是专家审计点名的停转形态。0 写进设备就是 _FSL 1 0。
# CAP=0 更阴：apply() 把目标钳到 0 之后 d=|0-written|=0 < DEAD，于是【不写不记日志】，
# 风扇停在 ensure_s0i3 握手留下的 0 上，连日志都没有。
_chk_bnd_reject e0    0   70 's/^E=100$/E=0/'   '档位下界非法'
_chk_bnd_reject cap0  100 0   's/^CAP=70$/CAP=0/' '档位下界非法'
# L0=24 / L5=24：低于固件 _FPS 表最低档 25。这两例通用循环（只查非数字，24 是合法
# 数字）与关系判据（不涉及 L0；L5=24 不触发 L5>CAP）全程沉默，所以【只有】下界检查
# 会碰它们 —— 这是 :213 与 L1..L5 循环各自独立钉住的【拒绝侧】证据。
# （边界侧由下面 L3=25 与出厂 L0=25 两个反向对照提供；两侧都要有才算钉住。）
_chk_bnd_reject l0_24 100 70 's/^L0=25$/L0=24/' '档位下界非法'
_chk_bnd_reject l5_24 100 70 's/^L5=70$/L5=24/' '低于 _FPS 最低档 25'
# iso：CAP=20 且 L5=20 —— 关系判据 E<=CAP（100<=20 否）/ L5>CAP（20>20 否）都不成立，
# 通用循环也放过（两个都是合法数字），全程只有两条下界检查在响。
_chk_bnd_reject iso   100 20 's/^CAP=70$/CAP=20/; s/^L5=70$/L5=20/' '档位下界非法'
_isir=$(_ecfg_cnt "$T/t12.iso" '不自洽'); _isir=${_isir:-0}
if [ "$_isir" -eq 0 ]; then
  ok "iso: 关系判据确实全程沉默（不自洽=0）—— 这次拒绝只可能是下界检查干的"
else
  ng "iso: 关系判据也响了（不自洽=$_isir）—— 这例证明不了下界检查能独立起作用"
fi

echo "-- 反向对照：出厂配置必须照常接管（L0=25 恰好就压在下界上）"
# 少了这一侧，上面每一条即使恒真也看不出来：一个"一律拒绝"的守卫能全绿。
# 它同时是【边界】对照 —— 25 是 _FPS 表的最低档、合法值，所以把
# `-lt 25` 改成 `-le 25`（边界不再触发）时，这里会立刻红。
_d12="$T/t12.coherent"
_ecfg_run "$_d12" 100 70 15 ''
if [ "$(_ecfg_cnt "$_d12" '参数来源')" -eq 0 ]; then
  ng "反向对照：出厂配置 E=100 CAP=70 L0=25 被误拒 —— 守卫过宽，或下界被写成了 -le 25"
else
  # 15s：_ecfg_fsl 读的是假设备的回读流水，而 setL "$E" 写在【第一次】getL 之后，
  # 要等第二个 IV(10s) 回合的 getL 才会被采进流水 —— 10s 超时这里会是空的（同 T13c）。
  ok "反向对照：出厂配置（L0=25 恰在下界上）照常接管: $(_ecfg_fsl "$_d12")"
fi
if [ "$(_ecfg_bnd "$_d12")" -ne 0 ]; then
  ng "反向对照：出厂配置被判了档位下界非法 —— L0=25 是合法值: $(grep -E '档位下界非法|低于' "$_d12/pfand.log" | tail -1 | cut -c21-96)"
else
  ok "反向对照：出厂配置没有被判下界非法（L0=25 = _FPS 最低档，合法）"
fi

echo "-- 边界对照：L1..L5 的下界同样是 25，必须也放行 Lk=25"
# 上面那个出厂对照只把 25 放在 L0 上，而 L0 归 :213 那行管，【走不到 L1..L5 循环】。
# 结果是循环自己的 -lt/-le 边界从来没被触发过：2026-10-11 复审把循环改成
# `-le 25` 之后整份测试照样 fails=0（复盘见上面"哪些是真的独立钉住"那段）。
# 出厂 L1..L5 是 30/40/50/60/70，全都离 25 很远，所以必须专门造一个 Lk=25。
# L3=25：合法（>= _FPS 最低档），且不出现在任何关系判据里，因此这一例唯一的
# 变量就是"循环在 25 这个边界上放不放行"。
_d12b="$T/t12.l3_25"
_ecfg_run "$_d12b" 100 70 10 's/^L3=50$/L3=25/'
if [ "$(_ecfg_cnt "$_d12b" '参数来源')" -eq 0 ]; then
  ng "边界对照：L3=25（= _FPS 最低档，合法）被误拒 —— L1..L5 循环的下界被写成了 -le 25: $(grep -E '档位下界非法|低于' "$_d12b/pfand.log" | tail -1 | cut -c21-96)"
else
  ok "边界对照：L3=25 照常接管（L1..L5 的下界 -lt 25 在边界上放行）"
fi
if [ "$(_ecfg_bnd "$_d12b")" -ne 0 ]; then
  ng "边界对照：L3=25 被判下界非法 —— 25 是 _FPS 表的合法最低档: $(grep -E '档位下界非法|低于' "$_d12b/pfand.log" | tail -1 | cut -c21-96)"
else
  ok "边界对照：L3=25 没有被判下界非法（25 = _FPS 最低档，合法）"
fi

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
# T12 原先也是 grep 源码的守卫（判据被整段删掉照样绿），现已换成同一套假设备上的
# 行为测试；两边共用下面这套 _ecfg_run —— 它原先定义在 T12 之后，为让 T12 能用已上移。
# 两边必须继续共用：各写一套假设备，等于两份会一起腐烂的断言。
#
# 产物一律留在用例目录里由断言现读，不用 | 分隔的结果串往回传 —— 结果串里的 | 一旦
# 进到 pattern 里就会被当成 case 的分支分隔符，把判据变成永远不触发的死代码。

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

echo "== T13d: 正常路径必须真的回读 _FST —— 判据在【设备收到了什么】，不在守护说了什么 =="
# T12/T13 的判据 c 是"假设备一次都没被回读 _FST"，它对两种情况【同样】成立：
#   (a) getL 根本没被走到（自检就拒了）
#   (b) getL 走到了，但那行 `echo "$F._FST" > "$DEV"` 被删了
# 两者都给 0 次。所以把读回删掉之后，没有任何一条断言会红：守护从此再也不知道
# 风扇的真实档位，DEAD 死区与每轮对账全部建在它自己的记忆上 —— 而那条记忆正是
# 它自己写的值，于是"对账"永远说"一致"。
#
# 本分支变异实测：删掉那行 echo 后整份 test_pfand_loop 只有 T9 会红，而它是
# 【硬币不是守卫】—— 6 次运行里红 4 次、绿 2 次。没有 _FST 请求时，假 dmesg
# 仍会为设备上【上一条 _FSL 写】吐一条新鲜 RESULT，于是 getL 常常把自己刚写的
# 档位当成"实际值"，T9 的对账照样触发；只有当它注入的 99 恰好落在 getL 的
# 第一次 dmesg 之后、第二次之前时，红才真的出现。把一个【三次里会漏过一次】的
# 检测称为"已被钉住"，就是本分支要消灭的那类东西。
#
# 复用的是 T13c 那一次真实运行（同一份自洽配置、同一个假设备目录）：T13c 已经
# 证明它进了主循环，这里再断言同一份流水里【设备确实收到了 ._FST 读】。
# 判据落在假设备收到的请求上，不是守护的日志：守护的 pfand.log 里从头到尾没有
# "_FST" 这两个字符，它写没写那行 echo，只有设备收没收到能作证。
# 断言 ≥1 而不是 ≥2：启动对齐后的第一次 getL 无条件发生（core/pfand:304），
# 走的是同一个通道同一个函数；而"每轮 IV 的那次回读"要等满一个 10s 周期，
# 把它也钉进来等于让判据依赖本机的负载（本仓已有负载相关抖动的实录）——
# 边界就说明在【通道存在】，不是【通道的节奏】。
_d13d="$T/t13.coherent"
_fan13d=$(sed -n 's/^FAN_DEVICE=//p' "$_d13d/plat.conf" 2>/dev/null)
if [ -z "$_fan13d" ]; then
  ng "T13d 前置：读不出假设备的 FAN_DEVICE（$_d13d/plat.conf）—— 判据抽不出来，先修夹具"
elif [ ! -s "$_d13d/dl" ]; then
  ng "T13d 前置：$_d13d/dl 为空 —— 假设备一次请求都没收到，T13c 那次运行没留下任何可判的证据"
else
  _f13d=$(grep -cF "${_fan13d}._FST" "$_d13d/dl" 2>/dev/null || true); _f13d=${_f13d:-0}
  if [ "$_f13d" -ge 1 ]; then
    ok "假设备收到 ${_f13d} 次 ${_fan13d}._FST 读（守护读的是风扇真实档位，不是自己的记忆）: $(grep -F "${_fan13d}._FST" "$_d13d/dl" | tail -1)"
  else
    ng "假设备一次 _FST 都没收到（流水里共 $(wc -l < "$_d13d/dl") 条请求，全是守护自己的写）—— getL 的读回没了，DEAD 死区与对账都建在记忆上"
  fi
fi

echo
echo "test_control_paths: fails=$fails"; exit "$fails"
