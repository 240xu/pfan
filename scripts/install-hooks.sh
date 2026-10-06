#!/usr/bin/env bash
# 安装仓库内的 git 钩子（.git/hooks 不受版本控制，clone 后需手动装一次）
set -euo pipefail
root=$(git rev-parse --show-toplevel)
install -m 755 "$root/hooks/pre-push" "$root/.git/hooks/pre-push"
echo "installed: .git/hooks/pre-push"
