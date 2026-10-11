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

echo "== T6: detect --write 必须写出 PANEL_DIR，否则 pfanel 会落回硬编码兜底 =="
# 2026-10-09 的 9eb0043 把面板目录改成从 platform.conf 派生，并声称成了单一事实源。
# 但 `pfan detect --write` 只输出 5 个键、不含 PANEL_DIR，而 deploy 只在文件【缺失】时
# 写 platform.conf —— 于是任何已经跑过 detect 的机器上，pfanel.py 的
# _PLAT.get("PANEL_DIR", <兜底>) 读不到该键、静默落回代码里的字面量，而
# deploy.sh / smoke.sh 读的是仓库 example 的值。两个源，只是今天恰好相同。
# 实测 2026-10-11：目标机 `sudo grep -c '^PANEL_DIR=' /etc/pfan/platform.conf` = 0。
#
# 判据不能只是"输出里有 PANEL_DIR="。detect 若自己抄一份字面量写出去，那条断言照样绿，
# 而单一事实源恰恰被打破 —— 一条看不见自己失败的断言比没有断言更危险。
# 所以这里断言【值取自仓库 example】：造一份 PANEL_DIR=哨兵 的 example、用接缝指过去，
# 输出必须跟着哨兵走。抄字面量的实现会在这里露馅（哨兵 != 字面量）。
# 接缝 PFAN_PLATFORM_EXAMPLE 与 PLAT_CAND 同形（core/pfan 里相邻定义），
# 生产从不设置它。
_ex="$TMP/example.conf"
sed "s|^PANEL_DIR=.*|PANEL_DIR=$TMP/sentinel-panel|" platform/platform.conf.example > "$_ex"
# 注意：detect --write 结束时会把 "已写入 <path>" 打到【stdout】，配置本体在文件里。
# 所以必须把这次调用的 stdout 丢掉再单独读文件，否则命令替换里混进那句话，
# 断言在实现修好之后依然会红（判据落在错误的对象上）。
PFAN_THERMAL_DIR="$TMP/za" PFAN_ACPI_PROBE="ok:\_SB.PCI0.LPCB.EC0" \
  PFAN_PLATFORM_EXAMPLE="$_ex" \
  bash core/pfan detect --write "$TMP/out6.conf" >/dev/null 2>&1
_got=$(sed -n 's/^PANEL_DIR=//p' "$TMP/out6.conf" 2>/dev/null | head -1)
if [ "$_got" = "$TMP/sentinel-panel" ]; then
  ok "detect --write 的 PANEL_DIR 取自仓库 example（不是抄一份字面量）: $_got"
else
  ng "detect --write 的 PANEL_DIR='${_got:-<没有这一键>}'，期望 '$TMP/sentinel-panel' —— 漏写或抄字面量都落到这里"
fi
# 对照：不设接缝的正常路径必须写出仓库 example 里那个真实值。
# 少了这一条，上面那条在【默认路径整个坏掉、只有接缝路径还通】时照样绿。
_exreal=$(sed -n 's/^PANEL_DIR=//p' platform/platform.conf.example | head -1)
PFAN_THERMAL_DIR="$TMP/za" PFAN_ACPI_PROBE="ok:\_SB.PCI0.LPCB.EC0" \
  bash core/pfan detect --write "$TMP/out6r.conf" >/dev/null 2>&1
_gotreal=$(sed -n 's/^PANEL_DIR=//p' "$TMP/out6r.conf" 2>/dev/null | head -1)
if [ "$_gotreal" = "$_exreal" ] && [ -n "$_exreal" ]; then
  ok "默认路径写出的 PANEL_DIR = example 的值: $_gotreal"
else
  ng "默认路径 PANEL_DIR='${_gotreal:-<没有这一键>}' != example 的 '${_exreal:-<example 没声明>}'"
fi
# 反向控制：example 缺 PANEL_DIR 时 detect 必须拒绝，不能写出 PANEL_DIR= 空值。
# pfanel.py 的 get() 只看 key 在不在 —— 空字符串会被当成有效路径
# （PANEL_DIR="" -> VENDOR_DIR="vendor" -> 面板从进程 cwd 读）。这条判的是"拒绝"，
# 上面两条判的是"值对"，方向不同，缺一不可。
grep -v '^PANEL_DIR=' platform/platform.conf.example > "$TMP/ex_nopanel.conf"
rc6c=0
PFAN_THERMAL_DIR="$TMP/za" PFAN_ACPI_PROBE="ok:\_SB.PCI0.LPCB.EC0" \
  PFAN_PLATFORM_EXAMPLE="$TMP/ex_nopanel.conf" \
  bash core/pfan detect --write "$TMP/out6c.conf" >/dev/null 2>&1 || rc6c=$?
if [ "$rc6c" -ne 0 ] && [ ! -f "$TMP/out6c.conf" ]; then
  ok "example 缺 PANEL_DIR 时 detect 拒绝落盘（rc=$rc6c）"
else
  ng "example 缺 PANEL_DIR 时 detect 仍写出配置（rc=$rc6c 存在=$([ -f "$TMP/out6c.conf" ] && echo y || echo n)）—— 会写出 PANEL_DIR= 空值，pfanel 把空串当路径"
fi
echo "test_detect: fails=$fails"; exit "$fails"
