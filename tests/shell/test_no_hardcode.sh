#!/usr/bin/env bash
# 静态回归：硬编码路径必须归零（detect 的候选数组是【探测清单】，允许存在）。
# 含 backlog ⑲/②④ 的 CLI 钳制测试 —— 断言错误信息，防止被"缺设备"假绿。
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
fails=0; ok(){ echo "  [ok]   $1"; }; ng(){ echo "  [FAIL] $1"; fails=$((fails+1)); }
code(){ grep -vE '^[[:space:]]*#' "$@" 2>/dev/null; }
PC="PFAN_PLATFORM_CONF=platform/platform.conf.example"

echo "== T1: 硬编码 ACPI 根路径只允许出现在 detect 的候选数组里 =="
hit=$(code core/pfand core/pfan server/pfanel.py | grep -nE 'PC00\.|PCI0\.')
if [ -z "$hit" ]; then ok "PCI0/PC00 归零（候选已下沉到 platform/fan-candidates.txt）"
else ng "残留:"; echo "$hit" | sed 's/^/      /'; fi

echo "== T2: 无硬编码热区索引 =="
hit=$(code core/pfand core/pfan server/pfanel.py | grep -nE 'thermal_zone[0-9]+')
if [ -z "$hit" ]; then ok "thermal_zoneN 归零"; else ng "残留:"; echo "$hit" | sed 's/^/      /'; fi

echo "== T3: 三个运行单元都在读平台配置 =="
grep -q 'pfan_plat' core/pfand && ok "pfand 用 pfan_plat" || ng "pfand 未用 pfan_plat"
grep -q 'pfan_plat' core/pfan  && ok "pfan  用 pfan_plat" || ng "pfan 未用 pfan_plat"
grep -qE 'pfan_platform' server/pfanel.py && ok "pfanel 用 pfan_platform" || ng "pfanel 未用 pfan_platform"

echo "== T4/T5/T6: CLI 档位钳制（断言拒绝理由，不看 rc 而已）=="
# 必须由白名单拒绝（rc=2 + 说明 1..120），而不是走到 acquire 因缺设备退出（rc=1 + 设备提示）
chk(){ # chk <value> <期望关键词>
  local out rc
  out=$(env $PC bash core/pfan set "$1" 2>&1); rc=$?
  if [ $rc -ne 0 ] && echo "$out" | grep -q "$2"; then
    ok "set $1 被白名单拒绝：$(echo "$out" | head -1 | cut -c1-56)"
  else
    ng "set $1 rc=$rc —— 未给出『$2』理由（若提示设备说明根本没走到钳制）: $out"
  fi
}
chk 0   "1\.\.120"
chk 999 "1\.\.120"
chk abc "1\.\.120"
chk ""  "1\.\.120"

echo "== T7: platform.conf 不可用时 pfand 必须 fail-safe 写满速 =="
# 断言【只存在于新分支】的标记，避免与既有的配置自校验分支混淆
if grep -q '先跑 pfan detect' core/pfand && grep -q 'fail-safe 满速' core/pfand; then
  ok "pfand 有平台配置缺失的 fail-safe 分支（写 100% 后 exit 0，不进重启循环）"
else ng "pfand 缺少平台配置缺失的 fail-safe 分支"
fi

echo "== T8: 候选机型文件存在且格式正确 =="
n=$(grep -vE '^#|^$' platform/fan-candidates.txt 2>/dev/null | grep -cE '\\_SB\.[^ ]+ \\_SB\.[^ ]+')
if [ "$n" -ge 1 ]; then
  ok "platform/fan-candidates.txt 有 $n 组成对候选"
else ng "候选文件缺失或格式不符（应为每行两列，\_SB 开头）"
fi

echo "test_no_hardcode: fails=$fails"; exit "$fails"
