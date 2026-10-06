#!/usr/bin/env bash
# pfand 的平台解析测试：跑 PFAN_PROBE 看它真正解析出什么。
# 这条测试专门针对"只 grep 到 fail-safe 分支却没 source 加载器"这类缺陷 ——
# 纯静态断言（T7）抓不到，必须真跑一遍。
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
fails=0; ok(){ echo "  [ok]   $1"; }; ng(){ echo "  [FAIL] $1"; fails=$((fails+1)); }

out=$(PFAN_PROBE=1 PFAN_PLATFORM_CONF=platform/platform.conf.example bash core/pfand 2>&1)
rc=$?
echo "  --- pfand PFAN_PROBE 输出 ---"
echo "$out" | sed 's/^/    /'

if [ $rc -ne 0 ]; then
  ng "探针非零退出 rc=$rc"
else
  got=$(echo "$out" | sed -n 's/^FAN_DEVICE=//p')
  if [ -n "$got" ]; then ok "FAN_DEVICE 解析成功: $got"; else ng "FAN_DEVICE 为空 —— 加载器未被 source"; fi

  got=$(echo "$out" | sed -n 's/^THERMAL_ZONE=//p')
  if [ -n "$got" ]; then ok "THERMAL_ZONE 解析成功: $got"; else ng "THERMAL_ZONE 为空"; fi

  got=$(echo "$out" | sed -n 's/^CANDIDATES=//p')
  if [ -n "$got" ] && [ -f "$got" ]; then ok "候选清单可读: $got"; else ng "候选清单不可读: '$got'"; fi

  got=$(echo "$out" | sed -n 's/^LOADER=//p')
  if [ -n "$got" ] && [ -f "$got" ]; then ok "加载器存在: $got"; else ng "加载器路径无效: '$got'"; fi
fi

echo "test_pfand_probe: fails=$fails"; exit "$fails"
