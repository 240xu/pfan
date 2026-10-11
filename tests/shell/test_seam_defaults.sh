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
  grep -qF -- "$lit" "$f" || { ng "$f 缺 $lit  ($why)"; return; }
  # 锚定（Minor 10）：只做 grep -qF 的话，字面量被【延长】时照样命中子串 ——
  # `PFAN_LOCK:-/run/pfanel.lock.bak` 与 `PFAN_DMESG:-dmesgX` 都会假绿。
  # 这里要求字面量后面紧跟的不是路径/标识符字符（即值到此为止），
  # 后缀漂移一律判红。awk 的 index() 是字面查找，literal 里的 . " ( ) 不用转义。
  if awk -v lit="$lit" '
    {
      s = $0
      while (1) {
        i = index(s, lit)
        if (i == 0) break
        if (substr(s, i + length(lit)) !~ /^[A-Za-z0-9_.\/~+-]/) { found = 1; exit }
        s = substr(s, i + length(lit))
      }
    }
    END { exit found ? 0 : 1 }' "$f"; then
    ok "$f 含 $lit  ($why)"
  else
    ng "$f 里的 $lit 被延长成了别的值（后缀漂移）—— 缺精确的 $lit  ($why)"
  fi
}

# 用 python【真实解析】缺省值，而不是 grep 单行字面量 ——
# 2026-10-08 实例：自动格式化把 os.environ.get("PFAN_LOCK", "/run/pfanel.lock") 折成
# 两行，grep 型钉子当场失效，而这条正是防"三个程序锁分叉"的守卫 —— 格式化器悄悄
# 废掉安全守卫，比没有守卫更危险。解析 AST 后，折行/改引号都影响不到它。
py_default(){ # py_default <env名> <期望缺省> <说明>
  local name="$1" want="$2" why="$3" got
  got=$(python3 - "$name" <<'PYEOF'
import ast, sys
name = sys.argv[1]
src = open("server/pfanel.py", encoding="utf-8").read()
for node in ast.walk(ast.parse(src)):
    if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) \
       and node.func.attr == "get" and node.args:
        a0 = node.args[0]
        if isinstance(a0, ast.Constant) and a0.value == name and len(node.args) > 1:
            a1 = node.args[1]
            if isinstance(a1, ast.Constant):
                print(a1.value); break
PYEOF
  )
  if [ "$got" = "$want" ]; then
    ok "server/pfanel.py 的 $name 缺省 = $got  ($why)"
  else
    ng "server/pfanel.py 的 $name 缺省 = '${got:-<解析不到>}'，期望 '$want'  ($why)"
  fi
}

echo "== T1: PFAN_LOCK 三处必须同为 /run/pfanel.lock（单槽设备共锁）=="
pin core/pfand  'PFAN_LOCK:-/run/pfanel.lock' 'pfand'
pin core/pfan   'PFAN_LOCK:-/run/pfanel.lock' 'pfan'
py_default PFAN_LOCK /run/pfanel.lock pfanel
py_default PFAN_DMESG dmesg pfanel

echo "== T2: PFAN_DMESG 三处必须同为 dmesg（消费者都靠它找 RESULT 行）=="
# core/pfan 是本次提交新增的第三个消费者：`PFAN_DMESG:-dmesgX` 会让 `pfan get`
# 静默执行 `sudo -n dmesgX`、一条 RESULT 都读不到，而 T2 旧版只钉 pfand/pfanel。
pin core/pfand  'PFAN_DMESG:-dmesg' 'pfand'
pin core/pfan   'PFAN_DMESG:-dmesg' 'pfan'

echo "== T3: 状态与配置文件路径 =="
pin core/pfand  'PFAN_CONF:-/etc/pfand.conf' '权威曲线'
pin core/pfand  'PFAN_CURVE_FILE:-/var/lib/pfanel/curve.state' '曲线状态'
pin core/pfand  'PFAN_EMERG_FILE:-/var/lib/pfanel/emerg.state' '应急锁(⑬)'
pin core/pfand  'PFAN_LOG:-/var/log/pfand.log' '守护日志'
# 这三条原先是文本钉（整行 grep 'os.environ.get("X", "Y")'）。它们能死在格式化上 ——
# 本文件自己的开头就写着这个教训：自动格式化把一个 os.environ.get 折成两行，grep 型
# 钉子当场失效，而"格式化器悄悄废掉安全守卫，比没有守卫更危险"。改走 py_default
# （AST 解析，折行免疫）。shellcheck:disable=SC2016 下面那几条是 bash 语法，不受影响。
py_default PFAN_CONF         '/etc/pfand.conf'            'pfanel 读同一份曲线'
py_default PFAN_CURVE_FILE    '/var/lib/pfanel/curve.state' 'pfanel 写同一份状态'
py_default PFAN_TOKEN_FILE    '/var/lib/pfanel/token'      '鉴权令牌'

echo "== T4: 设备与平台路径 =="
pin core/platform.sh 'PFAN_PLATFORM_CONF:-/etc/pfan/platform.conf' '平台配置定位器（事故根因那份）'
pin core/pfand  'PFAN_PLATFORM_SH:-/usr/local/lib/pfan/platform.sh' '加载器'
pin core/pfan   'PFAN_PLATFORM_SH:-/usr/local/lib/pfan/platform.sh' '加载器'
pin core/pfan   'PFAN_THERMAL_DIR:-/sys/class/thermal' '热区目录'
# PANEL_DIR 的出厂值也从这里取：detect 把它写进生成的 platform.conf，pfanel.py
# 再从那份配置读（见 9eb0043 与本轮 Task 3）。指错 example 会让 detect 写出的
# PANEL_DIR 与 deploy.sh / smoke.sh 读的那个 example 分叉 —— 正是本文件开头
# 拿 PFAN_LOCK 分叉当反面教材的那一类，所以按同样的 `pin` 钉住。
pin core/pfan   'PFAN_PLATFORM_EXAMPLE:-$(dirname "$0")/../platform/platform.conf.example' 'detect 写 PANEL_DIR 的取值来源'
# PANEL_DIR 的缺省现在来自 platform.conf（单一事实源），所以断言的是
# 「pfanel.py 从 _PLAT 取」这个结构，而不再钉死具体路径 —— 换部署目录时
# 改 platform/platform.conf.example 一处即可，这里不必同步（这正是本次重构的目的）。
_pdir=$(python3 - <<'PYEOF'
import ast
src = open("server/pfanel.py", encoding="utf-8").read()
for node in ast.walk(ast.parse(src)):
    if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) \
       and node.func.attr == "get" and node.args:
        a0 = node.args[0]
        if isinstance(a0, ast.Constant) and a0.value == "PFAN_PANEL_DIR":
            d = node.args[1]
            if isinstance(d, ast.Call):
                print("FROM_PLATCONF"); break
PYEOF
)
if [ "$_pdir" = "FROM_PLATCONF" ]; then
  ok "server/pfanel.py 的 PANEL_DIR 缺省来自 platform.conf（单一事实源）"
else
  ng "server/pfanel.py 的 PANEL_DIR 没从 platform.conf 取 —— 换部署目录要改多处"
fi
# 并且 platform.conf.example 必须真的声明了它
grep -qE '^PANEL_DIR=.+' platform/platform.conf.example \
  && ok "platform.conf.example 声明了 PANEL_DIR=$(sed -n 's/^PANEL_DIR=//p' platform/platform.conf.example | head -1)" \
  || ng "platform.conf.example 没声明 PANEL_DIR —— 派生会落回代码里的兜底值"
# _PLAT.get("DEV", ...) is not os.environ.get; same AST approach, different accessor
plat_default(){ # plat_default <key> <expected-default> <why>
  local key="$1" want="$2" why="$3" got
  got=$(python3 - "$key" <<'PYEOF'
import ast, sys
key = sys.argv[1]
src = open("server/pfanel.py", encoding="utf-8").read()
for node in ast.walk(ast.parse(src)):
    if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) \
       and node.func.attr == "get" and node.args:
        a0 = node.args[0]
        if isinstance(a0, ast.Constant) and a0.value == key and len(node.args) > 1:
            a1 = node.args[1]
            if isinstance(a1, ast.Constant):
                print(a1.value); break
PYEOF
  )
  if [ "$got" = "$want" ]; then
    ok "server/pfanel.py 的 $key 缺省 = $got  ($why)"
  else
    ng "server/pfanel.py 的 $key 缺省 = '${got:-<解析不到>}'，期望 '$want'  ($why)"
  fi
}
plat_default DEV '/dev/pfanctl' '设备兜底路径'

echo "== T5: PFAN_PORT / PFAN_PROBE =="
py_default PFAN_PORT         '8789'                       '面板端口'
pin core/pfand  'PFAN_PROBE:-0' '探测模式开关'

echo "test_seam_defaults: fails=$fails"; exit "$fails"
