#!/usr/bin/env bash
set -uo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd); cd "$repo" || exit 1
fails=0; ok(){ echo "  [ok]   $1"; }; ng(){ echo "  [FAIL] $1"; fails=$((fails+1)); }

[ -f core/platform.sh ] || { ng "core/platform.sh 不存在"; echo "test_platform_sh: fails=$fails"; exit "$fails"; }
. core/platform.sh
command -v pfan_plat >/dev/null 2>&1 || { ng "未定义 pfan_plat"; echo "test_platform_sh: fails=$fails"; exit "$fails"; }

EX="$repo/platform/platform.conf.example"

v=$(pfan_plat EC_ROOT "$EX"); rc=$?
if [ $rc -eq 0 ] && [ "$v" = '\_SB.PCI0.LPCB.EC0' ]; then ok "读 EC_ROOT = $v"; else ng "EC_ROOT='$v' rc=$rc"; fi

v=$(pfan_plat FAN_DEVICE "$EX"); rc=$?
if [ $rc -eq 0 ] && [ "$v" = '\_SB.PCI0.LPCB.EC0.TFN1' ]; then ok "读 FAN_DEVICE = $v"; else ng "FAN_DEVICE='$v' rc=$rc"; fi

v=$(pfan_plat NOPE "$EX"); rc=$?
if [ $rc -ne 0 ]; then ok "缺键返回非0"; else ng "缺键却 rc=0 输出='$v'"; fi

v=$(PFAN_PLATFORM_CONF=/nonexistent/platform.conf pfan_plat EC_ROOT); rc=$?
if [ $rc -ne 0 ]; then ok "缺文件返回非0"; else ng "缺文件却 rc=0 输出='$v'"; fi

# 与 python 侧同一份 example 必须读出相同值（双侧一致性）
pyv=$(python3 -c "import sys; sys.path.insert(0,'server'); from pfan_platform import load; print(load('$EX')['EC_ROOT'])" 2>/dev/null)
shv=$(pfan_plat EC_ROOT "$EX")
if [ "$pyv" = "$shv" ]; then ok "bash 与 python 读同一份文件结果一致"; else ng "不一致: bash='$shv' python='$pyv'"; fi

echo "test_platform_sh: fails=$fails"; exit "$fails"
