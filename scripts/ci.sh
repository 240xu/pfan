#!/usr/bin/env bash
# scripts/ci.sh — 开发机本地 CI。任一子检查非 0 即整体失败。
# 目标机不装这些工具，故本脚本只在开发机执行。
# Termux 注意：/usr/bin/env 不存在，请用 `bash scripts/ci.sh` 调用。
set -uo pipefail
rc=0
step(){ printf '\n=== %s ===\n' "$1"; }
want(){ command -v "$1" >/dev/null 2>&1 || { echo "MISSING: $1" >&2; rc=1; }; }

sh_files=()
for f in core/pfand core/pfan scripts/*.sh hooks/*; do
  [ -f "$f" ] && sh_files+=("$f")
done

for f in "${sh_files[@]}"; do
  step "bash -n $f"
  bash -n "$f" || rc=1
done

# 必需文件清单 —— 缺一个就报红（复审 C1：之前 [ -f ] && 数组追加会静默跳过删除的文件）
step "required file inventory"
REQUIRED_FILES="core/pfand core/pfan core/platform.sh server/pfanel.py server/pfan_platform.py core/pfanctl/pfanctl.c core/pfanctl/Makefile panel/index.html panel/styles.css panel/app.js panel/core.js panel/vendor/uPlot.esm.js panel/vendor/uPlot.min.css panel/vendor/uPlot.LICENSE platform/platform.conf.example platform/fan-candidates.txt config/pfand.conf.example systemd/pfand.service systemd/pfanel.service systemd/pfanctl.service scripts/ci.sh scripts/smoke.sh scripts/smoke-lib.sh hooks/pre-push ruff.toml"
for f in $REQUIRED_FILES; do
  [ -f "$f" ] || { echo "MISSING: $f" >&2; rc=1; }
done

# smoke.sh 只读守卫 —— 静态断言代码行无写操作（复审 I3：之前只在 Task 4 手跑过一次）
step "smoke.sh read-only guard"
SMOKE_FORBIDDEN='POST|set_level|set_curve|rm -|ufw (allow|delete|reset)|systemctl (start|stop|restart)|> */etc/'
# 必须覆盖 smoke.sh 【以及它 source 的所有文件】：
#   变异证明 —— 往 scripts/smoke-lib.sh 里追加
#   `sudo -n rm -f /etc/pfand.conf` 与 `curl -X POST`，smoke.sh 一行没动，
#   旧守卫照样报 "ok: smoke.sh 代码行无写操作"，零个 CI 失败。
# 而 smoke.sh:23 确实 `. "$(dirname "$0")/smoke-lib.sh"`。
# 提取方式：取 source/. 那一行的【最后一个引号段】。不试图解析路径表达式
#   （`. "$(dirname "$0")/smoke-lib.sh"` 里第一个引号段是 "$0"，解析它只会得到 scripts/$0）。
SMOKE_FILES=$(grep -E '^[[:space:]]*(\.|[[:space:]]source)[[:space:]]' scripts/smoke.sh \
             | grep -oE '"[^"]+"' | tail -1 | tr -d '"' | sed 's|.*/|scripts/|')
SMOKE_FILES="scripts/smoke.sh $SMOKE_FILES"
if [ -z "$(echo "$SMOKE_FILES" | tr ' ' '\n' | grep -c .)" ]; then
  echo "MISSING: smoke 文件集解析为空" >&2; rc=1
else
  # 不落临时文件：原来的 `> "$HOME/.cache/pfan-smoke-guard"` 一旦重定向失败
  # （HOME 指向不存在的目录即触发），复合命令非零 -> 走 else -> 报 ok（自我击穿））。
  # ⚠ 必须剥掉【字符串字面量】再匹配：smoke.sh 里有一条 bad 消息是
  # "…insmod 会报 Invalid parameters，/dev/pfanctl 不出现，pfanctl/pfand/pfanel 全挂…"
  # —— 它是给人看的说明，却包含 `/dev/pfanctl` 与 `pfand`，直接匹配会把这句
  # 说明判成写操作，ci 于是自己把自己判红（2026-10-09 实际发生）。
  # 剥引号内容比剥注释更根本：注释里也不会有真写操作。
  _hits=$(for f in $SMOKE_FILES; do
            [ -f "$f" ] || { echo "$f 不存在" >&2; continue; }
            sed 's/"[^"]*"//g; s/'"'"'[^'"'"']*'"'"'//g' "$f" \
              | grep -vE '^[[:space:]]*#' \
              | grep -nE "$SMOKE_FORBIDDEN" | sed "s|^|$f:|"
          done)
  if [ -n "$_hits" ]; then
    echo "smoke 文件含写操作（$SMOKE_FILES）:" >&2; echo "$_hits" >&2; rc=1
  else
    echo "ok: smoke 文件代码行无写操作（$SMOKE_FILES）"
  fi
fi

step "shellcheck (-S error)"
want shellcheck
if [ "${#sh_files[@]}" -gt 0 ]; then
  shellcheck -S error "${sh_files[@]}" || rc=1
else
  echo "no shell files"; rc=1
fi

step "ruff check server/"
want ruff
ruff check server/ || rc=1

if compgen -G "tests/python/*.py" >/dev/null 2>&1; then
  step "pytest tests/python"
  want pytest
  python3 -m pytest -q tests/python || rc=1
else
  echo "SKIP pytest (no tests/python/*.py)"
fi

# PFAN_SKIP_SHELL_TESTS=1 供 tests/shell/test_guards.sh 在 scratch 里调本脚本时
# 关闭测试层，否则 scratch ci.sh -> 测试 -> 再开 scratch -> 无限递归。
if [ "${PFAN_SKIP_SHELL_TESTS:-0}" = 1 ]; then
  echo "SKIP shell tests (PFAN_SKIP_SHELL_TESTS=1)"
elif compgen -G "tests/shell/*.sh" >/dev/null 2>&1; then
  step "shell tests (tests/shell)"
  for t in tests/shell/*.sh; do bash "$t" || rc=1; done
else
  echo "SKIP shell tests (none yet)"
fi

if compgen -G "tests/js/*.test.js" >/dev/null 2>&1; then
  step "vitest tests/js"
  if [ -f node_modules/vitest/vitest.mjs ]; then
    node node_modules/vitest/vitest.mjs run tests/js || rc=1
  else
    echo "MISSING: node_modules/vitest/vitest.mjs (npm i -D vitest)"; rc=1
  fi
else
  echo "SKIP vitest (no tests/js/*.test.js)"
fi

if [ -f panel/app.js ]; then
  step "node --check panel/app.js"
  node --check panel/app.js || rc=1
fi

printf '\n=== ci.sh: %s (rc=%d) ===\n' "$([ "$rc" -eq 0 ] && echo PASS || echo FAIL)" "$rc"
exit "$rc"
