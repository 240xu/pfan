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
