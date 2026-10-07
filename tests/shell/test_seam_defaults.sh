#!/usr/bin/env bash
# 接缝缺省值必须【逐条等于生产值】，且必须【在每个读取它的文件里】被钉住。
# 复审 I3：只钉了 pfanel 一份，pfand/pfan 里的同一接缝漂移后全套测试仍然绿 ——
# 最危险的是 PFAN_LOCK：三个程序共用单槽设备的同一把锁，字面量一旦分叉就回到
# 2026-10-05 审计修掉的那个竞态，而且没有任何测试会红。
# 断言的是【源码字面量】（不是运行值）：测试进程里这些变量全被 override 了。
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
fails=0; ok(){ echo "  [ok]   $1"; }; ng(){ echo "  [FAIL] $1"; fails=$((fails+1)); }

pin(){ # pin <file> <literal> <说明>
  local f="$1" lit="$2" why="$3"
  [ -f "$f" ] || { ng "缺文件 $f"; return; }
  if grep -qF "$lit" "$f"; then ok "$f 含 $lit  ($why)"
  else ng "$f 缺 $lit  ($why)"; fi
}

echo "== T1: PFAN_LOCK 三处必须同为 /run/pfanel.lock（单槽设备共锁）=="
pin core/pfand  'PFAN_LOCK:-/run/pfanel.lock' 'pfand'
pin core/pfan   'PFAN_LOCK:-/run/pfanel.lock' 'pfan'
pin server/pfanel.py 'os.environ.get("PFAN_LOCK", "/run/pfanel.lock")' 'pfanel'

echo "== T2: PFAN_DMESG 两处必须同为 dmesg（消费者都靠它找 RESULT 行）=="
pin core/pfand  'PFAN_DMESG:-dmesg' 'pfand'
pin server/pfanel.py 'os.environ.get("PFAN_DMESG", "dmesg")' 'pfanel'

echo "== T3: 状态与配置文件路径 =="
pin core/pfand  'PFAN_CONF:-/etc/pfand.conf' '权威曲线'
pin core/pfand  'PFAN_CURVE_FILE:-/var/lib/pfanel/curve.state' '曲线状态'
pin core/pfand  'PFAN_EMERG_FILE:-/var/lib/pfanel/emerg.state' '应急锁(⑬)'
pin core/pfand  'PFAN_LOG:-/var/log/pfand.log' '守护日志'
pin server/pfanel.py 'os.environ.get("PFAN_CONF", "/etc/pfand.conf")' 'pfanel 读同一份曲线'
pin server/pfanel.py 'os.environ.get("PFAN_CURVE_FILE", "/var/lib/pfanel/curve.state")' 'pfanel 写同一份状态'
pin server/pfanel.py 'os.environ.get("PFAN_TOKEN_FILE", "/var/lib/pfanel/token")' '鉴权令牌'

echo "== T4: 设备与平台路径 =="
pin core/platform.sh 'PFAN_PLATFORM_CONF:-/etc/pfan/platform.conf' '平台配置定位器（事故根因那份）'
pin core/pfand  'PFAN_PLATFORM_SH:-/usr/local/lib/pfan/platform.sh' '加载器'
pin core/pfan   'PFAN_PLATFORM_SH:-/usr/local/lib/pfan/platform.sh' '加载器'
pin core/pfan   'PFAN_THERMAL_DIR:-/sys/class/thermal' '热区目录'
pin server/pfanel.py 'os.environ.get("PFAN_PANEL_DIR", "/opt/beszel/beszel_data")' '面板部署目录'
pin server/pfanel.py '_PLAT.get("DEV", "/dev/pfanctl")' '设备兜底路径'

echo "== T5: PFAN_PORT / PFAN_PROBE =="
pin server/pfanel.py 'os.environ.get("PFAN_PORT", "8789")' '面板端口'
pin core/pfand  'PFAN_PROBE:-0' '探测模式开关'

echo "test_seam_defaults: fails=$fails"; exit "$fails"
