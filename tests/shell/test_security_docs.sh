#!/usr/bin/env bash
# ② SECURITY.md + ⑭ logrotate 部署件的源码级守卫
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
fails=0; ok(){ echo "  [ok]   $1"; }; ng(){ echo "  [FAIL] $1"; fails=$((fails+1)); }

echo "== T1: SECURITY.md 存在且覆盖关键声明 =="
if [ -f SECURITY.md ]; then
  ok "SECURITY.md 存在"
  for kw in 'X-Pfan-Token' 'PFAN_ORIGIN_ALLOW' 'root' 'copytruncate' '403'; do
    grep -q "$kw" SECURITY.md && ok "提到 $kw" || ng "SECURITY.md 未提到 $kw"
  done
else ng "缺 SECURITY.md（开源仓库必须有漏洞披露与威胁模型）"; fi

echo "== T2: logrotate 配置存在且必须用 copytruncate（逐日志段断言）=="
LR=deploy/logrotate.d/pfan
if [ -f "$LR" ]; then
  ok "$LR 存在"
  grep -q 'copytruncate' "$LR" && ok "使用 copytruncate" || \
    ng "未用 copytruncate —— pfand 用 >> 追加且无信号处理，轮转会丢日志"
  grep -q 'pfand\.log' "$LR" && ok "指向 pfand.log" || ng "没有指向 /var/log/pfand.log"
  # 每个日志都要有【自己的段】，且段内必须有 copytruncate —— 只在文件里 grep 得到
  # copytruncate 不代表新日志被覆盖到（全局段与遗漏段都能被文件级 grep 放过）。
  for lg in pfand pfanel; do
    stanza=$(awk -v p="/var/log/$lg.log {" 'index($0,p)==1{f=1} f{print} f&&/^}/{exit}' "$LR")
    if [ -z "$stanza" ]; then
      ng "缺 /var/log/$lg.log 轮转段 —— 该日志永远不轮转（$lg 用 >> 追加）"
    elif echo "$stanza" | grep -q 'copytruncate'; then
      ok "$lg.log 段内含 copytruncate"
    else
      ng "$lg.log 段缺 copytruncate —— 普通轮转会让 >> 的 fd 指向被移走的文件"
    fi
  done
  grep -q 'su root syslog' "$LR" && ok "su root syslog（/var/log 是 775 root:syslog）" || \
    ng "缺 su root syslog —— logrotate 会以 insecure permissions 拒转"
else ng "缺 $LR"; fi

echo "== T3: deploy.sh 必须真的安装 logrotate 配置（否则文件只在仓库里躺着）=="
grep -q 'logrotate' scripts/deploy.sh && ok "deploy.sh 提及 logrotate" || \
  ng "deploy.sh 不安装 logrotate 配置 —— ⑭ 等于没落地"
grep -qE 'logrotate\.d/pfan' scripts/deploy.sh && ok "安装到 /etc/logrotate.d/pfan" || \
  ng "没有装到 /etc/logrotate.d/pfan"

echo "== T4: 部署后必须能通过 logrotate 语法检查（-d 演练）==="
grep -qE 'logrotate -d' scripts/deploy.sh && ok "deploy.sh 含 logrotate -d 自检" || \
  ng "deploy.sh 不做 logrotate 配置自检 —— 语法错了要等一个月才爆"

echo "== T5: SECURITY.md 的写接口规则必须与 pfanel.py 的门【对账】（关键词存在性会放过矛盾文档）=="
PF=server/pfanel.py
# 5a) 代码侧：token 必须【单独】判（无条件）。旧版是一行组合条件
#     `if tok != get_token() and not self._same_origin(origin)` —— Origin 可替代 token。
#     同一行里再出现 origin/_same_origin 即为回退。
tokline=$(grep -n 'tok != get_token()' "$PF" | head -1 | cut -d: -f1)
if [ -z "$tokline" ]; then
  ng "代码里找不到 token 判定 tok != get_token()"
elif sed -n "${tokline}p" "$PF" | grep -qi 'origin'; then
  ng "token 判定与 Origin 判在【同一行】—— 回退成 'token 或 Origin'，白名单 Origin 可免 token"
else
  ok "代码：token 单独判定（第 $tokline 行，不含 origin）"
fi
# 5b) token 判定必须先于 Origin 判定，且【两者都在】窗口里：_deny 单独出现不算数。
#     OR 语义（grep -q '_deny\|return'）曾让"删掉 return"静默通过：403 发出去之后
#     代码继续跑到 set_level，档位照样写进设备 —— HTTP 层看不见（urllib 收到 403
#     就返回了），只有设备侧流水才留得下证据。所以 deny 与 return 必须【同时】命中，
#     且 return 必须是独立语句（行首缩进 + return），不是注释/字符串里出现的字样。
orgline=$(grep -n 'if origin and not origin_allowed' "$PF" | head -1 | cut -d: -f1)
if [ -n "$tokline" ] && [ -n "$orgline" ] && [ "$tokline" -lt "$orgline" ]; then
  ok "代码：token 判定（$tokline 行）先于 Origin 判定（$orgline 行）"
  win=$(sed -n "$((tokline+1)),${orgline}p" "$PF")
  if ! echo "$win" | grep -q '_deny'; then
    ng "token 判定后窗口内没有 _deny —— 无 token 的请求连 403 都拿不到"
  elif ! echo "$win" | grep -qE '^[[:space:]]*return([[:space:];]|$)'; then
    ng "token 判定后有 _deny 却【没有 return】—— 403 发出后继续执行，写操作照样落到设备上"
  else
    ok "代码：token 不通过即 deny+return（Origin 判定救不回一个没有 token 的请求）"
  fi
else
  ng "代码：找不到先于 Origin 判定的 token 判定（门顺序变了？）"
fi
# 5c) 文档侧：必须写明【无条件 token / Origin 不能替代 / 只比主机名 / 不带 Origin 只看 token】。
#     缺任何一条，文档就可能在描述一条与代码不同的规则。
for kw in '无条件' '不能替代' '只比对主机名' '不带 Origin'; do
  grep -q "$kw" SECURITY.md && ok "文档写明 $kw" || ng "SECURITY.md 未写明「$kw」—— 文档会掩盖门的真实规则"
done
# 5d) 真正的行为断言必须存在（文档措辞可以骗人，HTTP 行为测试骗不了）。
#     第二条是唯一能在 HTTP 层抓到"deny 之后没有 return"的检查：
#     只看 403 状态码永远是绿的，必须看【服务端有没有留下副作用】。
for t in test_write_requires_token_even_from_allowed_origin \
         test_tokenless_post_has_no_server_side_effect; do
  if grep -q "$t" tests/python/test_http.py; then
    ok "行为测试 $t 存在（指向真实行为断言）"
  else
    ng "缺行为测试 $t（只靠文档关键词不够；无副作用那条删掉后 deny-without-return 就没人抓）"
  fi
done

echo "== T6: 设计文档的目标行不得比触发表里【实际关闭】的条数多 =="
# 这个仓库存在的理由就是不再宣称没验证过的东西，而设计文档自己最容易变成第一个
# 谎：目标行写「四条被关闭」，触发表里却只有三行打了 ✅ —— 读的人只看目标行。
# W1 的教训更具体：它的机理经复核根本不成立（guard() 排在 snapshot() 与 DB 写入
# 之前，持续性异常只会跳过本轮后半段，下一轮开头照常先调 guard()），
# 但目标行照样把它算进了"已关闭"。
SPEC=docs/superpowers/specs/2026-10-10-fan-safety-and-honesty-design.md
if [ -f "$SPEC" ]; then
  _goal=$(grep -m1 '可达的停转/欠冷却路径被关闭' "$SPEC" || true)
  if [ -z "$_goal" ]; then
    ng "SPEC 里找不到「可达的停转/欠冷却路径被关闭」的目标行 —— 条款被删或改写，这条守卫失守"
  else
    _num=$(printf '%s' "$_goal" | grep -oE '[0-9]+条|[一二三四五六]条' | head -1)
    case "$_num" in
      一条) claim=1 ;; 二条) claim=2 ;; 三条) claim=3 ;; 四条) claim=4 ;;
      *) claim="${_num%%条}" ;;
    esac
    closed=$(grep -cE '^\| \*\*(F|W)[0-9]+\*\*.*✅ 已关闭' "$SPEC" || true)
    closed=${closed:-0}
    if [ "$claim" = "$closed" ]; then
      ok "目标行声称关闭 $claim 条，触发表里恰好 $closed 条标了 ✅"
    else
      ng "目标行声称关闭 $claim 条，触发表里只有 $closed 条标了 ✅ —— 目标行是假的：$_goal"
    fi
  fi
  # 反向：W1 必须【不许】出现在已关闭那一列。
  if grep -qE '^\| \*\*W1\*\*.*✅ 已关闭' "$SPEC"; then
    ng "W1 被标成已关闭 —— 它的机理经复核不成立（guard 排在 snapshot/DB 之前），本分支并未关闭它"
  else
    ok "W1 未被列入已关闭"
  fi
else
  ng "缺 $SPEC"
fi

echo "== T7: SECURITY.md 不得把 token 说成写路径的鉴权边界 =="
# 2026-10-09 外部审计：pfanel.py 的 _panel() 把 __PFAN_TOKEN__ 注入 app.js，
# 而 /pfan、/pfan.js 是【免鉴权 GET】——所以「持有有效 token」对任何能访问面板的人都是
# 现成的，curl 一次 GET 就有。SECURITY.md 却把它写成写接口的保护栏。
# 任何由客户端自己提交的 HTTP 门都能被 curl 满足（含 Origin、Host）；脚本客户端唯一
# 伪造不了的是【一个从未被传输的秘密】，而这里它被发到了公网上。
# 这条守卫钉住"如实描述"，防止它被改回去。命名用 T7：本文件里 T6 已被 SPEC 那条占用。
if grep -qE '必须带有效 .?X-Pfan-Token.?，\*\*无条件\*\*' SECURITY.md; then
  ng "SECURITY.md 仍把 token 描述为无条件保护 —— 它是无鉴权 GET 就能拿到的值"
else
  ok "SECURITY.md 不再把 token 说成写路径的鉴权边界"
fi
grep -qE '非浏览器客户端|无鉴权客户端|curl.{0,12}GET 就有了|应用层不认证任何人' SECURITY.md \
  && ok "SECURITY.md 明说了非浏览器客户端取到 token 的情形" \
  || ng "SECURITY.md 没有说明非浏览器客户端等同无鉴权"
# 反向：文档若只写"上一节是假的"，读者会以为整个安全模型都不成立。
# 三条仍有效的边界 + guard 上限必须同时在文，否则矫枉过正。
for kw in 'Origin 白名单是真实有效的浏览器 CSRF 边界' '不发 ACAO' 'GUARD_TEMP' '隧道的可达性就是边界'; do
  grep -q "$kw" SECURITY.md && ok "SECURITY.md 保留了仍然成立的边界：$kw" || \
    ng "SECURITY.md 缺「$kw」—— 只写失效的一面会让读者以为整个安全模型是假的"
done
echo

echo "test_security_docs: fails=$fails"; exit "$fails"
