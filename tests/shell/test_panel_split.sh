#!/usr/bin/env bash
# 前端拆分结构断言：三个文件必须独立存在、HTML 无内联 JS、服务端必须提供 css/js 路由。
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
fails=0; ok(){ echo "  [ok]   $1"; }; ng(){ echo "  [FAIL] $1"; fails=$((fails+1)); }

echo "== T1: 三个文件存在 =="
[ -f panel/index.html ] && ok "panel/index.html" || ng "缺 panel/index.html"
[ -f panel/styles.css ] && ok "panel/styles.css" || ng "缺 panel/styles.css"
[ -f panel/app.js ]     && ok "panel/app.js"     || ng "缺 panel/app.js"

echo "== T2: index.html 引用了样式与模块脚本 =="
if [ -f panel/index.html ]; then
  grep -q 'rel="stylesheet"' panel/index.html && ok "有 <link rel=stylesheet>" || ng "index.html 未引用样式"
  grep -q 'type="module"'    panel/index.html && ok "有 type=module 脚本"      || ng "index.html 未用 module"
  grep -q '/pfan.css'        panel/index.html && ok "引用 /pfan.css"           || ng "未引用 /pfan.css"
  grep -q '/pfan.js'         panel/index.html && ok "引用 /pfan.js"            || ng "未引用 /pfan.js"
  grep -q 'pfan-core.js'    panel/app.js     && ok "app.js 引用 core.js"      || ng "app.js 未 import core.js"
fi

echo "== T3: index.html 不得再有内联 JS（除 CDN src 标签）=="
if [ -f panel/index.html ]; then
  inline=$(sed -n '/<script/,/<\/script>/p' panel/index.html | grep -vE 'src=')
  if echo "$inline" | grep -qE 'function|const |let |=>|document\.'; then
    ng "仍有内联 JS:"; echo "$inline" | head -5 | sed 's/^/      /'
  else ok "无内联 JS（只有带 src 的标签）"; fi
fi

echo "== T4: 服务端提供 /pfan.css 与 /pfan.js =="
grep -q '"/pfan.css"' server/pfanel.py && ok "有 /pfan.css 路由" || ng "pfanel 缺 /pfan.css 路由"
grep -q '"/pfan.js"'  server/pfanel.py && ok "有 /pfan.js 路由"  || ng "pfanel 缺 /pfan.js 路由"
grep -qE 'text/css'            server/pfanel.py && ok "CSS Content-Type 正确" || ng "未声明 text/css"
grep -qE 'application/javascript' server/pfanel.py && ok "JS Content-Type 正确" || ng "未声明 application/javascript"

echo "== T5: 模块语法合法 + 纯逻辑独立成模块 =="
# 说明：原先断言写成"app.js 必须有 export"是错的 —— app.js 顶层会 boot() 并操作 DOM，
# 被 vitest 导入会直接崩；纯逻辑必须放在无副作用的 core.js。
if [ -f panel/app.js ]; then
  node --check panel/app.js && ok "app.js node --check 通过" || ng "app.js 语法错误"
fi
if [ -f panel/core.js ]; then
  node --check panel/core.js && ok "core.js node --check 通过" || ng "core.js 语法错误"
  grep -qE '^export ' panel/core.js && ok "core.js 有 export（可被 vitest 导入）" || ng "core.js 无 export"
  # 只看代码行：注释里提 setInterval/document 不构成副作用，匹配它只是假阳性。
  if grep -vE '^[[:space:]]*(\*|/\*|//)' panel/core.js | grep -qE 'document\.|window\.|setInterval'; then
    ng "core.js 含 DOM/副作用 —— 测试无法安全导入"
    grep -vE '^[[:space:]]*(\*|/\*|//)' panel/core.js | grep -nE 'document\.|window\.|setInterval' | sed 's/^/      /'
  else
    ok "core.js 无 DOM/副作用（已忽略注释行）"
  fi
else
  ng "缺 panel/core.js"
fi

echo "== T6: 旧的单文件不应残留 =="
[ -f panel/pfanpanel.html ] && ng "panel/pfanpanel.html 仍在（未拆干净）" || ok "旧单文件已移除"

echo "test_panel_split: fails=$fails"; exit "$fails"
