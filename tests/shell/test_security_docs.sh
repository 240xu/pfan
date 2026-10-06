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

echo "== T2: logrotate 配置存在且必须用 copytruncate =="
LR=deploy/logrotate.d/pfan
if [ -f "$LR" ]; then
  ok "$LR 存在"
  grep -q 'copytruncate' "$LR" && ok "使用 copytruncate" || \
    ng "未用 copytruncate —— pfand 用 >> 追加且无信号处理，轮转会丢日志"
  grep -q 'pfand\.log' "$LR" && ok "指向 pfand.log" || ng "没有指向 /var/log/pfand.log"
else ng "缺 $LR"; fi

echo "== T3: deploy.sh 必须真的安装 logrotate 配置（否则文件只在仓库里躺着）=="
grep -q 'logrotate' scripts/deploy.sh && ok "deploy.sh 提及 logrotate" || \
  ng "deploy.sh 不安装 logrotate 配置 —— ⑭ 等于没落地"
grep -qE 'logrotate\.d/pfan' scripts/deploy.sh && ok "安装到 /etc/logrotate.d/pfan" || \
  ng "没有装到 /etc/logrotate.d/pfan"

echo "== T4: 部署后必须能通过 logrotate 语法检查（-d 演练）==="
grep -qE 'logrotate -d' scripts/deploy.sh && ok "deploy.sh 含 logrotate -d 自检" || \
  ng "deploy.sh 不做 logrotate 配置自检 —— 语法错了要等一个月才爆"

echo "test_security_docs: fails=$fails"; exit "$fails"
