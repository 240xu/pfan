#!/usr/bin/env bash
# Task 1 验收：源码从远端权威副本完整入库
set -euo pipefail
cd "$(dirname "$0")/.."
[ "$(wc -l < core/pfand)" -eq 248 ]
[ "$(wc -l < core/pfan)" -eq 33 ]
[ "$(wc -l < server/pfanel.py)" -eq 601 ]
[ "$(wc -l < core/pfanctl/pfanctl.c)" -eq 129 ]
[ "$(wc -l < panel/pfanpanel.html)" -eq 541 ]
[ "$(grep -c __PFAN_TOKEN__ panel/pfanpanel.html)" -eq 1 ]
[ "$(grep -c 'obj-m' core/pfanctl/Makefile)" -eq 1 ]
find . -type f -size 0 -not -path './.git/*' -not -path './scripts/*' | grep -q . && { echo "有空文件"; exit 1; }
# BASELINE.sha256 是【导入时刻】的溯源记录，不是"文件永不变更"的不变式。
# 源码此后会随 P1/P2 演进，故此处不做哈希比对（Task 2 Ruling）。
echo "verify-import: PASS"
