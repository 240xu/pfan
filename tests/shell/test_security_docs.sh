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
# 5b) token 判定必须先于 Origin 判定，且中间必须有 deny+return（两道门串联，第一道不通过就走人）
orgline=$(grep -n 'if origin and not origin_allowed' "$PF" | head -1 | cut -d: -f1)
if [ -n "$tokline" ] && [ -n "$orgline" ] && [ "$tokline" -lt "$orgline" ]; then
  ok "代码：token 判定（$tokline 行）先于 Origin 判定（$orgline 行）"
  if sed -n "$((tokline+1)),${orgline}p" "$PF" | grep -q '_deny\|return'; then
    ok "代码：token 不通过即 deny+return（Origin 判定救不回一个没有 token 的请求）"
  else
    ng "token 判定后没有 deny/return —— 可能被后面的 Origin 判定放行（OR 语义）"
  fi
else
  ng "代码：找不到先于 Origin 判定的 token 判定（门顺序变了？）"
fi
# 5c) 文档侧：必须写明【无条件 token / Origin 不能替代 / 只比主机名 / 不带 Origin 只看 token】。
#     缺任何一条，文档就可能在描述一条与代码不同的规则。
for kw in '无条件' '不能替代' '只比对主机名' '不带 Origin'; do
  grep -q "$kw" SECURITY.md && ok "文档写明 $kw" || ng "SECURITY.md 未写明「$kw」—— 文档会掩盖门的真实规则"
done
# 5d) 真正的行为断言必须存在（文档措辞可以骗人，HTTP 行为测试骗不了）
if grep -q 'test_write_requires_token_even_from_allowed_origin' tests/python/test_http.py; then
  ok "行为测试 test_write_requires_token_even_from_allowed_origin 存在（指向真实行为断言）"
else
  ng "缺行为测试：无 token + 白名单 Origin 必须 403（只靠文档关键词不够）"
fi

echo "test_security_docs: fails=$fails"; exit "$fails"