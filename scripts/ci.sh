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
REQUIRED_FILES="core/pfand core/pfan core/platform.sh server/pfanel.py server/pfan_platform.py core/pfanctl/pfanctl.c core/pfanctl/Makefile panel/index.html panel/styles.css panel/app.js panel/core.js platform/platform.conf.example platform/fan-candidates.txt config/pfand.conf.example systemd/pfand.service systemd/pfanel.service systemd/pfanctl.service scripts/ci.sh scripts/smoke.sh scripts/smoke-lib.sh hooks/pre-push ruff.toml"
for f in $REQUIRED_FILES; do
  [ -f "$f" ] || { echo "MISSING: $f" >&2; rc=1; }
done

# smoke.sh 只读守卫 —— 静态断言代码行无写操作（复审 I3：之前只在 Task 4 手跑过一次）
step "smoke.sh read-only guard"
SMOKE_FORBIDDEN='POST|set_level|set_curve|rm -|ufw (allow|delete|reset)|systemctl (start|stop|restart)|> */etc/'
if [ ! -f scripts/smoke.sh ]; then
  echo "MISSING: scripts/smoke.sh" >&2; rc=1
elif grep -vE '^[[:space:]]*#' scripts/smoke.sh | grep -nE "$SMOKE_FORBIDDEN" > "$HOME/.cache/pfan-smoke-guard" 2>/dev/null; then
  echo "smoke.sh 含写操作:" >&2; cat "$HOME/.cache/pfan-smoke-guard" >&2; rc=1
else
  echo "ok: smoke.sh 代码行无写操作"
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
