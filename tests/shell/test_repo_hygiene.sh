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

sec "T4: BASELINE.* 要么有活消费者，要么不存在（孤立的假安全控制）"
# 理由见附录 A：这类文件的唯一消费者一旦被删，它就从"门禁"退化成"看起来像门禁"——
# 仓库可写者能同时改文件和哈希，没有信任锚；真实一致性由 smoke 对目标机的比对承担。
# 用通配遍历实际存在的 BASELINE.* —— 硬编码文件名会漏掉新造的孤儿。
# 必须 --exclude 本文件：注释里提到某个孤儿名，就会让它"有消费者"，测试满足自己的断言。
for bl in BASELINE.*; do
  [ -e "$bl" ] || continue
  if [ -e "$bl" ]; then
    # 除 git/文档外，是否还有脚本/源码读它
    if grep -rqF "$bl" --exclude-dir=.git --exclude='*.md' --exclude="$(basename "$0")" . 2>/dev/null; then
      ok "$bl 存在且有代码消费者"
    else
      ng "$bl 存在但除文档外无人读取 —— 孤立的假安全控制，删除或恢复消费者"
    fi
  else
    ok "$bl 不存在"
  fi
done

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

sec "T9: smoke 必须比对内核模块源码（deploy.sh 不同步 /opt/pfanctl，别处无人看管）"
if grep -qF 'core/pfanctl/pfanctl.c' scripts/smoke.sh && grep -qF '/opt/pfanctl/pfanctl.c' scripts/smoke.sh; then
  ok "smoke.sh 会比对仓库与目标机的 pfanctl.c"
else
  ng "smoke.sh 不比对 pfanctl.c —— 源码漂移后仓库就不再描述在跑的内核模块"
fi
if grep -q 'pfanctl.ko' scripts/smoke.sh && grep -qE 'stale|比 pfanctl.c 旧' scripts/smoke.sh; then
  ok "smoke.sh 会检测 .ko 编译过期（源码改了没重建）"
else
  ng "smoke.sh 不检测 .ko 是否过期 —— 改了源码却没重建时无人报警"
fi

sec "T10: pre-push 的跳过分支不得用 `&&` 链（set -e 下条件为假 = 无理由拒推）"
# 2026-10-08 实测：机器不可达时，`[ "${PFAN_SKIP_SMOKE:-0}" = 1 ] && echo ...` 在
# set -e 下返回 1，整个钩子以 rc=1 退出 —— 日志恰好停在上一行，push 被无理由拒绝。
# 正确写法是 if。守卫只断言形态，不执行钩子（那要连机器）。
if grep -qE '^\s*\[ "\$\{PFAN_SKIP_SMOKE:-0\}" = 1 \] &&' hooks/pre-push; then
  ng "pre-push 跳过分支仍用 [ ... ] && 链 —— set -e 下条件为假会无理由拒绝 push"
elif grep -q 'PFAN_SKIP_SMOKE' hooks/pre-push; then
  ok "pre-push 跳过分支用 if 而非 && 链（机器不可达时可正常放行）"
else
  ng "pre-push 里找不到 PFAN_SKIP_SMOKE 分支"
fi

echo "test_repo_hygiene: fails=$fails"
exit "$fails"
