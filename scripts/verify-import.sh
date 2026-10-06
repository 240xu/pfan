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
sha256sum -c BASELINE.sha256 --quiet
echo "verify-import: PASS"
