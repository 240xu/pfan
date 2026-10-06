#!/usr/bin/env bash
# pfan detect 行为测试：热区探测（假 /sys/class/thermal）+ ACPI 探测替身。
# 断言同时校验 rc 与 stderr 关键字 —— 只看 rc 会被 pfan 的设备前置检查假绿。
set -uo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd); cd "$repo" || exit 1
fails=0; ok(){ echo "  [ok]   $1"; }; ng(){ echo "  [FAIL] $1"; fails=$((fails+1)); }
TMP=$(mktemp -d "${XDG_CACHE_HOME:-$HOME/.cache}/detect.XXXXXX"); trap 'rm -rf "$TMP"' EXIT

run(){ # run <thermal_dir> <probe_mode> -> out/err/rc
  out=$(PFAN_THERMAL_DIR="$1" PFAN_ACPI_PROBE="$2" bash core/pfan detect 2>"$TMP/err")
  rc=$?; err=$(cat "$TMP/err")
}

echo "== T1: 唯一 x86_pkg_temp 被选中 =="
mkdir -p "$TMP/z1/thermal_zone0" "$TMP/z1/thermal_zone5"
echo INT3400 > "$TMP/z1/thermal_zone0/type"; echo x86_pkg_temp > "$TMP/z1/thermal_zone5/type"
run "$TMP/z1" "ok:\_SB.PC00.LPCB.EC0"
if echo "$out" | grep -q 'THERMAL_ZONE=.*/thermal_zone5/temp'; then
  ok "选中 zone5"
else ng "未选中 zone5: out='$out' err='$err' rc=$rc"; fi
if echo "$out" | grep -q 'EC_ROOT=\\_SB.PC00.LPCB.EC0'; then
  ok "ACPI 替身 EC_ROOT 生效"
else ng "EC_ROOT 未取自替身: out='$out'"; fi

echo "== T2: 0 个 x86_pkg_temp 必须失败并说明原因 =="
mkdir -p "$TMP/z0/thermal_zone0"; echo pch_cannonlake > "$TMP/z0/thermal_zone0/type"
run "$TMP/z0" "ok:\_SB.PCI0.LPCB.EC0"
if [ $rc -ne 0 ] && echo "$err" | grep -q '没有 x86_pkg_temp'; then
  ok "rc=$rc 且报『没有 x86_pkg_temp』"
else ng "rc=$rc err='$err'（必须非零且说明原因，防止被设备前置检查假绿）"; fi

echo "== T3: 多个 x86_pkg_temp 必须失败（索引因机器而异，猜不得）=="
mkdir -p "$TMP/zd/thermal_zone1" "$TMP/zd/thermal_zone2"
echo x86_pkg_temp > "$TMP/zd/thermal_zone1/type"; echo x86_pkg_temp > "$TMP/zd/thermal_zone2/type"
run "$TMP/zd" "ok:\_SB.PCI0.LPCB.EC0"
if [ $rc -ne 0 ] && echo "$err" | grep -q '匹配到 2 个'; then
  ok "rc=$rc 且报『匹配到 2 个』"
else ng "rc=$rc err='$err'"; fi

echo "== T4: ACPI 探测全失败必须拒绝（不许回退默认值）=="
mkdir -p "$TMP/za/thermal_zone0"; echo x86_pkg_temp > "$TMP/za/thermal_zone0/type"
run "$TMP/za" "fail"
if [ $rc -ne 0 ] && echo "$err" | grep -q 'ACPI'; then
  ok "rc=$rc 且报 ACPI 失败"
else ng "rc=$rc err='$err'（回退默认值 = 静默选错路径）"; fi

echo "== T5: --write 落盘内容可被加载器读回 =="
run "$TMP/za" "ok:\_SB.PCI0.LPCB.EC0"
PFAN_THERMAL_DIR="$TMP/za" PFAN_ACPI_PROBE="ok:\_SB.PCI0.LPCB.EC0" \
  bash core/pfan detect --write "$TMP/out.conf" >/dev/null 2>&1
if [ -f "$TMP/out.conf" ] && pfan_ok=$(PFAN_PLATFORM_CONF="$TMP/out.conf" bash -c '. core/platform.sh; pfan_plat THERMAL_ZONE') \
   && echo "$pfan_ok" | grep -q 'thermal_zone0/temp'; then
  ok "写盘后可被 pfan_plat 读回: $pfan_ok"
else ng "--write 未生成可读配置 (有文件=$([ -f "$TMP/out.conf" ] && echo y || echo n))"; fi

echo "test_detect: fails=$fails"; exit "$fails"
