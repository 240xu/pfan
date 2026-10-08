#!/usr/bin/env bash
# test_repo_hygiene.sh — 仓库卫生守卫：把 P0 附录 A（T1~T4）钉死，防回潮。
# 只做只读静态断言：不联网、不碰目标机、【不】跑 npm test / ci.sh
# （npm test = ci.sh，ci.sh 又会跑本文件 → 真跑会无限递归）。
# 用法：bash tests/shell/test_repo_hygiene.sh
set -uo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
cd "$repo" || exit 1
fails=0
ok(){ printf '  [ok]   %s\n' "$1"; }
ng(){ printf '  [FAIL] %s\n' "$1"; fails=$((fails+1)); }
sec(){ printf '\n== %s ==\n' "$1"; }

# package.json 字段取值（node 必需 —— ci.sh 的 vitest/node --check 已经依赖它）
jget(){ node -p "require('./package.json').$1 || ''" 2>/dev/null || true; }

sec "T1: npm test 不得是恒失败桩，且必须指向仓库内真实存在的脚本"
ts=$(jget scripts.test)
if [ -z "$ts" ]; then
  ng "package.json 缺 scripts.test"
else
  case "$ts" in
    *"no test specified"*|*"&& exit 1"*)
      ng "scripts.test 仍是恒失败桩: $ts" ;;
    *)
      ok "scripts.test = $ts" ;;
  esac
  refs=$(printf '%s' "$ts" | grep -oE '(^|[[:space:]])(scripts|tests|hooks)/[A-Za-z0-9._/-]+\.(sh|js)' | tr -d ' ' || true)
  if [ -z "$refs" ]; then
    ng "scripts.test 未指向任何仓库脚本（无法证明它跑的是真实检查）: $ts"
  else
    for r in $refs; do
      if [ -f "$r" ]; then ok "scripts.test 引用存在: $r"; else ng "scripts.test 引用不存在的文件: $r"; fi
    done
  fi
fi

sec "T2: package.json 不得引用不存在的文件"
main=$(jget main)
if [ -z "$main" ]; then
  ok "无 main 字段（非库包，不指向不存在的 index.js）"
elif [ -f "$main" ]; then
  ok "main 指向存在文件: $main"
else
  ng "main 指向不存在的文件: $main"
fi
for k in directories.doc directories.test; do
  v=$(jget "$k")
  if [ -z "$v" ]; then
    ok "$k 未设置"
  elif [ -e "$v" ]; then
    ok "$k = $v 存在"
  else
    ng "$k = $v 不存在"
  fi
done

sec "T3: README 不得出现 ./scripts/install-hooks.sh 形式（Termux 无 /usr/bin/env，rc=126）"
if grep -qF './scripts/install-hooks.sh' README.md; then
  ng "README 仍含 ./scripts/install-hooks.sh"
else
  ok "README 无 ./scripts/install-hooks.sh"
fi
if grep -qF 'bash scripts/install-hooks.sh' README.md; then
  ok "README 用 bash scripts/install-hooks.sh"
else
  ng "README 缺 bash scripts/install-hooks.sh 的正确写法"
fi
# 旧的自相矛盾句（钩子会 skip，smoke 从不 skip）不许再出现
if grep -qF 'smoke 不 skip 只 FAIL' README.md; then
  ng "README 仍含自相矛盾的 smoke 跳过表述"
else
  ok "README 无『smoke 不 skip 只 FAIL』矛盾句"
fi

sec "T4: BASELINE.sha256 要么有活消费者，要么不存在（孤立的假安全控制）"
if [ -f BASELINE.sha256 ]; then
  # 只认代码消费者（scripts/hooks/deploy/源码），docs/specs 里提它不算
  cons=$(grep -rlF 'BASELINE.sha256' scripts hooks deploy core server panel systemd config platform 2>/dev/null || true)
  if [ -n "$cons" ]; then
    ok "BASELINE.sha256 有代码消费者: $(printf '%s' "$cons" | tr '\n' ' ')"
  else
    ng "BASELINE.sha256 存在但无任何代码消费者（verify-import.sh 已于 43da01a 删除）"
  fi
else
  ok "BASELINE.sha256 不存在（孤立文件已移除）"
fi

sec "T5: smoke.sh 失败码必须先切成 3 位再比较（防 000000 污染数值比较）"
# 断言的是【赋值后立刻切片】，不是错误文案里顺手截断（文案里已有 \${c:0:3} 但比较仍拿全串）
if grep -qF 'code=${code:0:3}' scripts/smoke.sh; then
  ok "公网入口 code 赋值后立即取 \${code:0:3}"
else
  ng "scripts/smoke.sh 缺 code=\${code:0:3}（\$(curl ... || echo 000) 可能拼成 000000）"
fi
if grep -qF 'c=${c:0:3}' scripts/smoke.sh; then
  ok "静态路由 c 赋值后立即取 \${c:0:3}"
else
  ng "scripts/smoke.sh 静态路由段缺 c=\${c:0:3}（比较仍拿未切片的串）"
fi

sec "T6: smoke 第 5 段必须比对真实部署件（线上服务 /opt/beszel/beszel_data，不是仓库副本）"
if grep -qF 'beszel_data' scripts/smoke.sh; then
  ok "smoke.sh 涉及 /opt/beszel/beszel_data 部署件"
else
  ng "smoke.sh 第 5 段只扫仓库 panel/ 副本 —— 测的不是线上真正服务的字节"
fi


sec "T7: deploy.sh 暂存不能让 logrotate 配置与 CLI 抢同一个名字"
# core/pfan 暂存后叫 $STAGE/pfan；若 deploy/logrotate.d/pfan 也 scp 到 $STAGE/，
# 两者同名互相覆盖 —— 结果是把 logrotate 规则装成 /usr/local/bin/pfan、把 CLI 装成
# 日志轮转规则，而暂存后 `ls` 完全看不出来（两份内容都"在"，只是名字被抢了）。
if grep -qF '$STAGE/logrotate-pfan' scripts/deploy.sh; then
  ok "logrotate 用独立暂存名 \$STAGE/logrotate-pfan"
else
  ng "logrotate 仍暂存为 \$STAGE/pfan —— 会覆盖 CLI，下一次部署就装错"
fi
if grep -q 'STAGE/pfan.*usr/local/bin/pfan' scripts/deploy.sh; then
  ok "CLI 仍从 \$STAGE/pfan 安装（该名字未被 logrotate 抢走）"
else
  ng "deploy.sh 里找不到 CLI 安装行 —— 安装目标变了？"
fi

sec "T8: pre-push 必须接住 ssh 探测的退出码，否则跳过分支是死代码"
# set -e 下命令替换赋值的退出码就是 ssh 的退出码：机器不可达时钩子在这里直接中止
# （rc=255），下面"打印原因 + 接受 PFAN_SKIP_SMOKE"一行都不会执行。
if grep -q 'probe_rc=' hooks/pre-push; then
  ok "pre-push 用 probe_rc 显式接住 ssh 退出码"
else
  ng "pre-push 未接住 ssh 退出码 —— 不可达时原因不打印、PFAN_SKIP_SMOKE 无效"
fi

echo "test_repo_hygiene: fails=$fails"
exit "$fails"
