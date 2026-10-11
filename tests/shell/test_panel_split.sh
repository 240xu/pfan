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

# 取出 panel/app.js 里某个顶层函数的【函数体】：逐字符先剥掉注释与字符串，再按
# 大括号配对计深度。打印的仍是原始行（只看深度，不改内容），所以报红时看到的是源码。
#
# 为什么不用 sed 的 '/^function sizeOf/,/^}/'：那个范围一旦闭合大括号被缩进或改写，
# 就一路吃到文件尾 —— fitChart 被重新算回 sizeOf 头上，断言又悄悄退回全文 grep，
# 而那正是本次要消灭的东西（缺陷回来了，守卫照样绿）。找不到函数时输出为空，
# 调用方判负 => 报红，不会静默通过。
#
# ⚠ 2026-10-11 复现：【裸计大括号】本身就是缺陷。往 sizeOf 里塞一个落单的 `{`
# （`/* 见 fitChart 的 {width,height */` —— 块注释把 `}` 吃掉了），
# "函数体"就从 8 行涨到整个文件 318 行；fitChart 里那一份 `el.parentElement || el`
# 于是同时满足下面两条收窄后的 grep，fails 归 0 —— 恰好对 `const box = el;`
# （＝恢复那个最贵的无界增高缺陷）这个 mutation 完全失明。所以下面这个扫描器
# 必须跳过 // 行注释、/* */ 块注释、单双引号串、模板字面量的文本段、regex 字面量，
# 只数真代码里的括号。
_fnbody(){ # _fnbody <文件> <函数名>
  awk -v fn="$2" '
    # rxstart: 上一个有意义的代码字符若是这些，则随后的 "/" 开的是 regex 而非除号。
    # （app.js 现在既无 regex 字面量也无除号；留着这条是为了将来在 app.js 里
    #  写 s.replace(/\{/g, ...) 时不会把 regex 里的括号当成结构括号。）
    function rxstart(p){ return (p == "" || p ~ /[(,=:[!&|?{};+*%~^<>-]/) }
    # scan: 从头扫一行，更新 st/hd/d；函数体闭合时返回 1。
    #   st: 0 代码 / 1 行注释 / 2 块注释 / 3 单引号串 / 4 双引号串 / 5 模板文本段 / 6 regex
    #   hd: 模板 ${...} 洞里的括号深度（洞里的括号是模板自己的，不计入函数体）
    function scan(s,   i, c, nc, n, q) {
      n = length(s)
      for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        nc = (i < n ? substr(s, i + 1, 1) : "")
        if (st == 1) { if (c == "\\") i++; continue }              # // 行注释
        if (st == 2) {                                              # /* */ 块注释
          if (c == "*" && nc == "/") { st = 0; i++ }
          else if (c == "/" && nc == "*") { st = 2; i++ }
          else if (c == "\\") i++
          continue
        }
        if (st == 3 || st == 4) {                                   # 单 / 双引号串
          q = (st == 3 ? "\047" : "\"")
          if (c == "\\") { i++; continue }
          if (c == q) st = 0
          continue
        }
        if (st == 5) {                                              # 模板字面量文本段
          if (c == "\\") { i++; continue }
          if (c == "`") { st = 0; continue }
          if (c == "$" && nc == "{") { st = 0; hd = 1; i++; continue }
          continue
        }
        if (st == 6) {                                              # regex 字面量
          if (c == "\\") { i++; continue }
          if (incl) { if (c == "]") incl = 0; continue }
          if (c == "[") { incl = 1; continue }
          if (c == "/") {
            st = 0
            while (i < n && substr(s, i + 1, 1) ~ /[dgimsuvy]/) i++
          }
          continue
        }
        if (c == "/" && nc == "/") { st = 1; i++; continue }        # ---- 以下是代码区 ----
        if (c == "/" && nc == "*") { st = 2; i++; continue }
        if (c == "\"")  { st = 4; continue }
        if (c == "\047") { st = 3; continue }
        if (c == "`")   { st = 5; continue }
        if (c == "/" && rxstart(prev)) { st = 6; incl = 0; continue }
        if (c == "{") { if (hd) hd++; else d++; prev = c; continue }
        if (c == "}") {
          if (hd) { hd--; if (!hd) st = 5; prev = c; continue }
          d--; prev = c
          if (d <= 0) return 1
          continue
        }
        if (c != " " && c != "\t") prev = c
      }
      if (st == 1) st = 0        # 行注释到行尾即止
      return 0
    }
    BEGIN { st = 0; hd = 0; d = 0; prev = ""; incl = 0; found = 0 }
    {
      if (!found) {
        if ($0 ~ ("^(async +)?function " fn "\\(")) { found = 1 }
        else next
      }
      print
      if (scan($0)) exit
    }
  ' "$1"
}

# 提取器自己也必须能看见自己坏掉。这一条不是装饰：上面那个扫描器要是哪天又漏了
# 一种语法，这里的三条判据仍然会把"提取跑飞"报成红，而不是让 fitChart 的同名串
# 悄悄顶替 sizeOf。跑飞的三种形态与判据一一对应：
#   1) 没找到函数            -> 输出为空；
#   2) 一路吃到文件尾 / 提前停在内层 } -> 末行不是顶格 "}"；
#   3) 吞进了后面的顶层函数   -> 体内出现第二个 ^function / ^async function。
# 正常时输出为空（调用方判 -z 即为可信）。
_fnbody_runaway(){ # _fnbody_runaway <函数名> <函数体>；不可信则打印原因到 stdout
  local name="$1" body="$2" last others
  if [ -z "$body" ]; then echo "没找到 function $name（提取为空）"; return; fi
  last=$(printf '%s\n' "$body" | tail -1)
  if [ "$last" != "}" ]; then
    echo "函数体末行是 [$last]，不是顶格 }（提取提前停住，或一路吃到了文件尾）"; return
  fi
  others=$(printf '%s\n' "$body" | tail -n +2 | grep -cE '^(async +)?function ' || true)
  if [ "$others" -ne 0 ]; then
    echo "函数体里混进了 $others 个别的顶层 function 定义（提取跑飞）"; return
  fi
}

echo "== T4a: _fnbody 提取器自检（剥注释/字符串，以及「跑飞」判据本身）=="
# 提取器和它的守卫都不能是"看着对"。这里用一个合成 fixture 同时钉两件事：
#   · 扫描器确实跳过注释与字符串里的括号（否则 probe2 会被吞进来）；
#   · 三条「跑飞」判据每一条都确实会对跑飞的提取报红 —— 下面三段各喂一种坏提取，
#     故意让它们只能被其中某一条抓住，免得判据写错了也没人知道。
_t4a_fixture=$(mktemp)
cat > "$_t4a_fixture" <<'FIXTURE'
function probe(el) {
  // 行注释里的一个落单 { 和一个 }
  /* 块注释里的 {width,height —— 结尾的 } 被注释吃掉了 */
  const s = "字符串里的 } 和 {";
  const t = `模板文本段里的 { }，加上洞 ${ JSON.stringify({ a: 1 }) }`;
  const r = /[{}]/g;
  const n = el.parentElement || el;
  return { width: n.getBoundingClientRect().width };
}
function probe2() {
  return 1;
}
FIXTURE
_t4a_body=$(_fnbody "$_t4a_fixture" probe)
if printf '%s\n' "$_t4a_body" | grep -q '^function probe2'; then
  ng "提取器自检：probe 的函数体吞进了 probe2（注释/字符串里的括号被当成了结构括号）"
else
  ok "提取器自检：注释、字符串、模板文本段、regex 里的括号都没被计入深度"
fi
if [ "$_t4a_body" = "$(printf '%s\n' "$_t4a_body" | head -10)" ] \
   && printf '%s\n' "$_t4a_body" | grep -q 'el\.parentElement || el'; then
  ok "提取器自检：probe 恰好取到自己的 10 行（没早停、没多吞）"
else
  ng "提取器自检：probe 的提取不是恰好 10 行"; printf '%s\n' "$_t4a_body" | sed 's/^/      /'
fi
# 坏提取 A：整份 fixture 当函数体。末行恰好是顶格 }，所以只有「体内有第二个顶层
# function 定义」这条能抓住它 —— 另外两条在这份输入上都会放行。
if _t4a_why=$(_fnbody_runaway probe "$(cat "$_t4a_fixture")") && \
   printf '%s' "$_t4a_why" | grep -q '顶层 function 定义'; then
  ok "守卫自检 A：吞进后续顶层函数 ⇒ 由「体内有第二个顶层定义」报红（$_t4a_why）"
else
  ng "守卫自检 A：吞进后续顶层函数却没报红，或是被别的判据抓住的 —— $_t4a_why"
fi
# 坏提取 B：只截到 probe 内部就停（模拟"提前停在内层 }"）。体内没有第二个顶层函数，
# 所以只有「末行必须是顶格 }」这条能抓住它。
if _t4a_why=$(_fnbody_runaway probe "$(printf '%s\n' "$_t4a_body" | head -5)") && \
   printf '%s' "$_t4a_why" | grep -q '不是顶格'; then
  ok "守卫自检 B：提前停在内层括号 ⇒ 由「末行必须是顶格 }」报红（$_t4a_why）"
else
  ng "守卫自检 B：提前停住却没报红，或是被别的判据抓住的 —— $_t4a_why"
fi
# 坏提取 C：空提取（函数根本不存在）。
if _t4a_why=$(_fnbody_runaway probe ""); then
  ok "守卫自检 C：函数不存在、提取为空 ⇒ 由「提取为空」报红（$_t4a_why）"
else
  ng "守卫自检 C：空提取却没报红 —— 守卫不是真的在看"
fi
if [ -z "$(_fnbody_runaway probe "$_t4a_body")" ]; then
  ok "守卫自检：合法的提取不被误报"
else
  ng "守卫自检：合法的提取被误报：$(_fnbody_runaway probe "$_t4a_body")"
fi
rm -f "$_t4a_fixture"

echo "== T4: 图表高度必须取自父容器，不能取自 uPlot 自己（否则 h=h+32 无界增长）=="
# 专家审计 CRITICAL 1（浏览器实测）：sizeOf 量的是 #ch1，而 #ch1 的高度是 uPlot 的
# .u-wrap 高度【加上】32px 的 .u-legend（.u-wrap 的兄弟节点）。把这个测量值原样喂回
# uPlot.setSize 就是 h = h + 32 —— 没有不动点。实测 #ch1 长到 11744px、页面 7658px。
#
# ⚠ 判据必须限定在【sizeOf 的函数体】里，不能 grep 全文（2026-10-11 收窄）：
# `parentElement` 与 `el.parentElement || el` 这两个串在 sizeOf 和 fitChart 里
# 各出现一次（fitChart 观察父容器、同样是对的）。原文是全文 grep，于是把 sizeOf
# 改回 `const box = el;`（＝恢复那个最贵的无界增高缺陷）之后，fitChart 里那一份
# 照样命中，fails 仍然是 0 —— 守卫对它要防的那个缺陷是瞎的。两条都收窄到函数体。
#
# 这一对是【字面量级】结构哨兵，不是行为契约。行为契约在 tests/js/core.test.js
# （把 sizeOf/fitChart 原样取出来真跑，断言 setSize 被调几次）。
#
# 实测（2026-10-11，app.js 里量测对象换一种等价的取法）：
#   el.closest('.chartbox') || el   —— 行为完全相同（量到的还是同一个 .chartbox），
#     但这两条 grep 照样红，fails=2；vitest 127 passed。
#   也就是说这两条只认 `parentElement` 这一个【拼写】：拼写一变（对错都一样）就红。
# 因此它们不能单独用来说明"改动是对的"——判断对错要看 tests/js/core.test.js：
#   同一个改法下，那边绿=行为没变（legit / 上面 127 passed）；
#   而 const box = el;、closest('.chart')、closest('.nope') 三种真正量错对象的写法，
#   那边都是 6 failed（2026-10-11 实测）。
#
# 收窄到函数体本身有个前提：提取必须是对的。所以先过一遍 _fnbody_runaway ——
# 提取一旦跑飞（吞进 fitChart 或后面任何顶层定义），下面两条 grep 就等于又变回
# 全文 grep，而 grep 照旧全绿，正是 2026-10-11 复现出来的那个"守卫对缺陷失明"。
# 没有这一句，下面两条的收窄是假的。
_sizeof_body=$(_fnbody panel/app.js sizeOf)
_sizeof_why=$(_fnbody_runaway sizeOf "$_sizeof_body")
if [ -z "$_sizeof_why" ]; then
  ok "sizeOf 的函数体提取可信（不是跑飞的全文）"
else
  ng "sizeOf 的函数体提取不可信：$_sizeof_why —— 下面的两条 grep 会退化成全文 grep"
fi
if printf '%s\n' "$_sizeof_body" | grep -qE 'parentElement'; then
  ok "sizeOf 的函数体内量的是 parentElement（.chartbox 由 CSS 定高、不含图例）"
else
  ng "sizeOf 的函数体内没量 parentElement —— 量的是 uPlot 自己的盒子，h=h+32 无界增长"
fi
if printf '%s\n' "$_sizeof_body" | grep -qE 'el\.parentElement \|\| el'; then
  ok "sizeOf 明确取父元素矩形"
else
  ng "sizeOf 没明确取父元素矩形"
fi
echo
echo "test_panel_split: fails=$fails"; exit "$fails"
