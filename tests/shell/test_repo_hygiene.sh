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
# 唯一要防的是【碰撞】：CLI 与 logrotate 从同一个暂存源安装（历史缺陷：两者都落到
# $STAGE/pfan，于是 logrotate 规则装成 /usr/local/bin/pfan、CLI 装成 /etc/logrotate.d/pfan）。
# 判定：解析出两个安装源，比它们是否同名 —— 不强制某一种改法。
D=scripts/deploy.sh
cli_src=$(grep 'install -m 755' "$D" | grep 'usr/local/bin/pfan$' \
          | sed -n 's/.*\$STAGE\/\([A-Za-z0-9._/-]*\).*/\1/p')
lr_src=$(grep 'install -m 644' "$D" | grep '/etc/logrotate.d/pfan$' \
         | sed -n 's/.*\$STAGE\/\([A-Za-z0-9._/-]*\).*/\1/p')
if [ -z "$cli_src" ] || [ -z "$lr_src" ]; then
  ng "认不出安装源（CLI=[$cli_src] logrotate=[$lr_src]）—— deploy.sh 结构变了？守卫需同步"
elif [ "$cli_src" = "$lr_src" ]; then
  ng "CLI 与 logrotate 都从 [$cli_src] 安装 —— 必然互相覆盖，装出来的是错的东西"
else
  ok "CLI 源=[$cli_src] ≠ logrotate 源=[$lr_src]，无碰撞"
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

sec "T10: pre-push 的跳过分支不得用 && 链（set -e 下条件为假 = 无理由拒推）"
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

sec "T11: vendored 资源必须被部署、被冒烟、被 CI 覆盖（漏一个=面板全挂且闸门全绿）"
# 2026-10-08 专家审计 C1：panel/app.js 改成 import 本地 /pfan-vendor-uplot.js 之后，
# deploy.sh 完全没有 transfer/install vendor/，smoke 也只校验 4 个非 vendor 文件 ——
# 于是一次部署就会让 ESM import 500 → 整个 app.js 不执行（连 boot() 都不跑），
# 而 deploy.sh / smoke.sh / pre-push 三道闸门【全部报绿】。这比没有闸门更危险。
VF='panel/vendor/uPlot.esm.js'
if grep -qF "$VF" scripts/deploy.sh; then
  ok "deploy.sh 会传输并安装 vendor 资源"
else
  ng "deploy.sh 不碰 panel/vendor —— 部署后面板会全挂，而所有闸门仍然报绿"
fi
if grep -q 'beszel_data/vendor' scripts/deploy.sh; then
  ok "deploy.sh 会在目标机创建 vendor 目录"
else
  ng "deploy.sh 没建 vendor 目录 —— 首台机器上 install 会失败"
fi
if grep -q 'pfan-vendor-uplot' scripts/smoke.sh; then
  ok "smoke.sh 会验证 vendor 路由"
else
  ng "smoke.sh 不验 vendor 路由 —— 部署漏装时冒烟仍报绿"
fi
if grep -qF "$VF" scripts/ci.sh; then
  ok "ci.sh 必需文件清单包含 vendor 资源"
else
  ng "ci.sh 不要求 vendor 资源存在 —— 误删后 CI 仍绿"
fi

sec "T12: 恢复点必须覆盖第 3 步覆盖的每一个路径（否则半途失败不可回滚）"
# 专家审计 C2：恢复点原本只备 5 个 /usr/local/bin/* 二进制，而第 3 步还会覆盖
# /etc/logrotate.d/pfan、/usr/local/lib/pfan/platform.sh、/etc/pfan/fan-candidates.txt
# 与 4 个面板文件。中途失败 = 新二进制 + 旧面板的混合态，而重跑 deploy 会把混合态
# 再备一次 —— 原始好状态永远丢失。
for path in /etc/logrotate.d/pfan /usr/local/lib/pfan/platform.sh \
            /etc/pfan/fan-candidates.txt /opt/beszel/beszel_data/index.html \
            /opt/beszel/beszel_data/styles.css /opt/beszel/beszel_data/app.js \
            /opt/beszel/beszel_data/core.js; do
  if grep -qF "$path" scripts/deploy.sh; then
    # 出现在备份段（step 1，mkdir 恢复点那一段）才算数；只在安装段出现是不够的
    # 备份段的窗口必须是【整个 step 1】，不能用硬编码行号——上一个版本用 1,32p，
    # 备份块一超过就误报"没备份"（守卫自己先崩，比没守卫更糟）
    if awk '/^echo "== 1\//,/^echo "== 2\//' scripts/deploy.sh | grep -qF "$path"; then
      ok "恢复点覆盖 $path"
    else
      ng "第3步会覆盖 $path，但恢复点没备份它 —— 中途失败不可回滚"
    fi
  else
    ng "deploy.sh 里找不到 $path（安装段被改过？守卫需要同步）"
  fi
done

sec "T13: 已修的缺陷不得继续以『已知缺陷/修好前不要跑』形式留在文档里（专家审计 C3/C4）"
# 这些警告在修复后继续存在，会让人拒跑一个已经正确的脚本，或按幻影缺陷手工绕路。
for bad_phrase in '修好前不要跑' 'deploy.sh 不在本轮' ; do
  if grep -qF "$bad_phrase" README.md docs/OPERATIONS.md 2>/dev/null; then
    ng "文档仍把已修的暂存名冲突写成待修：\"$bad_phrase\""
  else
    ok "文档不再声称 deploy.sh 有待修缺陷（\"$bad_phrase\"）"
  fi
done
# C4：spec 不得把未发生的文档改动标成已完成
if grep -qE 'README 同步改为如实描述。' docs/specs/2026-10-06-pfan-design.md 2>/dev/null; then
  ng "spec 仍有一行未加限定地声称『README 同步改为如实描述』"
else
  ok "spec 里该声称已带限定/订正说明"
fi

echo "== T16: 恢复点必须由【安装清单】派生，而不是手抄路径列表 =="
# 专家审计 I-1 + 我实测：原 T12 只检查那 10 个路径的【文本】出现在第 1 步窗口里。
# 变异证明 —— 把备份循环清空、把路径名留在注释里，T12 的 7 条断言全绿。
# 现在改成：把第 3 步的 install 目标解析出来，要求每一个都在第 1 步的备份列表里。
# 取目标路径：install 行的【最后一个字段】就是目标（源路径形如 '$STAGE/xxx' 或
# $STAGE/xxx，无空格），所以 awk '{print $NF}' 是对的。但第 1 步的备份列表里
# pfan-cli 记作 pfan（CLI 装成 /usr/local/bin/pfan），需要映射回去。
# 用 sed 而不是 grep -oE + $NF：install 行里源路径与目标之间有对齐空格
# （`'$STAGE/pfand'        /usr/local/bin/pfand`），字段法会漏掉一半目标。
# 目标恒为以 / 开头的绝对路径且在行尾，所以按行尾匹配最稳。
_install_dst=$(awk '/3\/5 安装/,/4\/5/' scripts/deploy.sh \
              | sed -n 's/.*install -m [0-9]* [^ ]*  *\(\/[^ ]*\).*/\1/p' \
              | sed "s|^'/usr/local/bin/pfan-cli'$|/usr/local/bin/pfan|" \
              | sort -u)
# platform.conf 只在【缺失时】写入、不覆盖，且恢复点刻意不含它（改动它的是平台
# 探测结果，不是一次部署的产物）—— 但它仍然是 install 目标，所以显式豁免并说明。
_install_real=$(printf '%s\n' $_install_dst | grep -v '^/etc/pfan/platform.conf$')
_backup_src=$(awk '/1\/5 目标机建恢复点/,/2\/5 传输/' scripts/deploy.sh \
              | grep -oE '/(etc|usr|opt)/[A-Za-z0-9_./-]+' | sed 's|/$||' | sort -u)
_n=0
for _d in $_install_real; do
  [ -n "$_d" ] || continue
  case "$_d" in
    /usr/local/bin/pfan|/usr/local/bin/pfand|/usr/local/bin/pfanel.py|\
    /usr/local/bin/pfan_platform.py|/usr/local/bin/pfan_core.py)
      _c=$(printf '%s\n' "$_backup_src" | grep -c "$(basename "$_d")" || true) ;;
    /etc/logrotate.d/pfan) _c=$(printf '%s\n' "$_backup_src" | grep -c '/etc/logrotate.d/pfan' || true) ;;

    *) _c=$(printf '%s\n' "$_backup_src" | grep -cF "$_d" || true) ;;
  esac
  if [ "$_c" -ge 1 ]; then
    ok "恢复点覆盖 $_d"
  else
    ng "第3步会覆盖 $_d，但恢复点没备份它 —— 中途失败不可回滚"
    _n=$((_n+1))
  fi
done
echo "  （共 $(printf '%s\n' $_install_real | grep -c . ) 个安装目标，已全部被恢复点逻辑覆盖；platform.conf 因只在缺失时写而豁免）"
echo
echo "== T17: 开源前置条件：LICENSE / NOTICE / 第三方声明 =="
# 专家审计 checklist 第 1-3 项（硬阻断）：仓库声称 GPL-3.0-or-later 却没有 LICENSE，
# 于是它其实是「保留一切权利」，GitHub 显示 No license，npm 也无法归类。
if [ -s LICENSE ]; then ok "LICENSE 存在且非空"; else ng "缺 LICENSE —— 声称 GPL-3.0-or-later 却不发许可证，等于保留一切权利"; fi
# 不能只判存在：得是 GPL-3.0 全文（35KB 左右），不是随手写的三行标题
_lb=$(wc -c < LICENSE 2>/dev/null || echo 0)
if [ "$_lb" -gt 30000 ]; then
  ok "LICENSE 是 GPL-3.0 全文（$_lb 字节）"
else
  ng "LICENSE 只有 $_lb 字节 —— 不是 GPL-3.0 全文（应有 34000+ 字节）"
fi
grep -q 'TERMS AND CONDITIONS' LICENSE 2>/dev/null \
  && ok "LICENSE 含 TERMS AND CONDITIONS 正文" \
  || ng "LICENSE 不含 GPL 正文（可能只是个标题或占位文件）"
grep -q 'END OF TERMS AND CONDITIONS' LICENSE 2>/dev/null \
  && ok "LICENSE 正文完整（含结尾标记）" \
  || ng "LICENSE 缺结尾标记 —— 文本被截断"
if [ -s NOTICE ]; then ok "NOTICE 存在"; else ng "缺 NOTICE —— copyleft 项目应登记独立实现声明与第三方组件"; fi
grep -q 'uPlot' NOTICE 2>/dev/null \
  && ok "NOTICE 登记了内嵌的 uPlot" \
  || ng "NOTICE 未登记内嵌的 uPlot（MIT 与 GPL-3.0 兼容但 §5(d) 要求随分发保留声明）"
grep -q '独立实现' NOTICE 2>/dev/null \
  && ok "NOTICE 含独立实现声明（copyleft 项目尤其重要）" \
  || ng "NOTICE 缺独立实现声明"
node -p "require('./package.json').license || ''" 2>/dev/null | grep -q 'GPL-3.0-or-later' \
  && ok "package.json 声明 license=GPL-3.0-or-later" \
  || ng "package.json 未声明 license（npm 无法归类该包）"
# 内嵌的 MIT 文件必须随代码一起提交
if [ -s panel/vendor/uPlot.LICENSE ]; then ok "panel/vendor/uPlot.LICENSE 随代码提交"; else ng "panel/vendor/uPlot.LICENSE 缺失 —— 分发 MIT 代码却不带其许可证"; fi
echo
echo "== T18: 仓库里不得有 U+FFFD（UTF-8 替换字符）—— 损坏的字符会静默留在文档与注释里 =="
# 2026-10-09 一轮批量编辑里我自己引入了 18 处 U+FFFD，横跨 6 个文件（脚本、测试、
# 文档），其中两处是更早就存在的。肉眼扫不出来 —— 中文注释里一个词被写坏成
# 「可」后面跟三个坏字节这种形态，不影响任何语法检查，
# 但它会原样出现在给读者看的手册里。所以必须机器检测，不能靠眼睛。
_fffd=$(grep -rlP '\x{FFFD}' --exclude-dir=.git --exclude-dir=node_modules \
         --exclude-dir=.superpowers --exclude-dir=.ruff_cache --exclude-dir=__pycache__ \
         . 2>/dev/null)
if [ -n "$_fffd" ]; then
  ng "这些文件含 U+FFFD（损坏字符）：$(echo "$_fffd" | tr '\n' ' ')"
  printf '%s\n' "$_fffd" | while read -r f; do
    [ -n "$f" ] || continue
    grep -nP '\x{FFFD}' "$f" 2>/dev/null | head -2 | sed 's/^/      /'
  done
else
  ok "全仓库无 U+FFFD（无损坏字符）"
fi
echo
echo "== T19: 文档不得声称一个本仓库无法核实的结论已实操验证 =="
# 审计 I-8：OPERATIONS 的回滚流程写着"未经目标机实操验证"，而它列出的"恢复点里没有的
# 东西"里有 7 个面板文件 —— 那些文件其实都在恢复点里。带"[未验证]"标记的错误陈述比
# 没有标记更糟：它看起来像是被审过的。
# 现在回滚流程已在目标机实操（恢复点 /root/backups/pfan-deploy-<timestamp> 的实际
# 布局核对），所以那句"未经实操验证"必须消失；而真正无法核实的仍要带 [未验证]。
if grep -qF '未经目标机实操验证' README.md docs/OPERATIONS.md 2>/dev/null; then
  ng "回滚流程已在目标机实操过，文档却仍写『未经目标机实操验证』"
else
  ok "回滚流程的验证状态与实际一致（已实操验证）"
fi
# 反向：恢复点确实覆盖了面板文件，文档不得再说它没有
if grep -qE '恢复点里没有的东西|面板 4 文件.*只备份' docs/OPERATIONS.md 2>/dev/null; then
  ng "文档仍声称恢复点不含面板文件 —— 实际 10/10 都在（2026-10-09 核实）"
else
  ok "文档不再声称恢复点缺面板文件"
fi
# logrotate-pfan 这个路径从未存在于仓库
# 只在【声称它存在】的语境里判失败：OPERATIONS 里有一句「本页此前把它写成
# $STAGE/logrotate-pfan」，那是订正说明，提到这个名字是对的。所以排除含
# 「此前」/「写成」的行，只抓把它当现有路径讲的地方。
if grep -rn 'logrotate-pfan' README.md docs/ 2>/dev/null | grep -vE '此前|写成|从不存在' \
     | grep -q .; then
  ng "文档仍把 \$STAGE/logrotate-pfan 当成现有路径 —— 它从未在仓库里存在过"
  grep -rn 'logrotate-pfan' README.md docs/ 2>/dev/null | grep -vE '此前|写成|从不存在' | sed 's/^/      /'
else
  ok "文档不再把不存在的 \$STAGE/logrotate-pfan 当成现有路径（订正说明中的提及不计）"
fi
echo
echo "== T20: Python 侧默认值断言必须走 AST，不得退回文本钉 =="
# 审计 I-6：test_seam_defaults 的 py_default（AST 解析）当时只用在 PFAN_LOCK 与
# PFAN_DMESG 两处，其余 7 个仍是整行 grep 'os.environ.get("X", "Y")'。本文件开头
# 写着这个教训：自动格式化把那行折成两行，grep 型钉子当场失效。
# 实证：把 pfanel.py 的 PFAN_PORT 折成 5 行（语法正确）后，grep -cF 匹配数 = 0。
# 注意不要写 `grep -c ... || echo 0`：grep -c 在 0 匹配时已经输出 0 并返回 1，
# 再 || 补一个 0 就得到两行，字符串比较随之失败（我第一版就这么写错了）。
_grep_pins=$(grep -cE "^[[:space:]]*pin server/pfanel\.py" tests/shell/test_seam_defaults.sh 2>/dev/null)
_grep_pins=${_grep_pins:-0}
if [ "$_grep_pins" = "0" ]; then
  ok "test_seam_defaults 对 pfanel.py 已无文本钉（全部走 AST）"
else
  ng "test_seam_defaults 还有 $_grep_pins 处 pin server/pfanel.py 文本钉 —— 格式化即失效"
fi
grep -q 'py_default PFAN_PORT' tests/shell/test_seam_defaults.sh \
  && ok "PFAN_PORT 等缺省由 py_default（AST）断言" \
  || ng "PFAN_PORT 未走 AST 断言"
grep -q 'plat_default DEV' tests/shell/test_seam_defaults.sh \
  && ok "_PLAT.get(\"DEV\") 缺省由 AST 断言" \
  || ng "_PLAT.get(\"DEV\") 缺省未走 AST 断言"
echo
echo "== T21: 曲线预设必须有【受支持的启用路径】与【部署路径】 =="
# 审计 I-7 + M4：两套预设原先零消费者 —— 面板、pfanel、deploy、smoke、文档都不引用，
# 想用只能手工 cp 覆盖 /etc/pfand.conf，而 OPERATIONS.md 恰恰写着「不要手改，否则
# 下次 smoke 必红」。也就是说交付了一个用不了的配置。
# 现在：deploy 传到 /opt/pfanctl/presets，pfan preset list/show/apply 是入口。
grep -q 'S config/pfand.conf.cool-quiet config/pfand.conf.performance' scripts/deploy.sh \
  && ok "deploy.sh 传输两套预设" \
  || ng "deploy.sh 不传预设 —— 它们无法通过任何受支持路径上机"
grep -q '/opt/pfanctl/presets/pfan.conf.cool-quiet' scripts/deploy.sh \
  && ok "预设安装到 pfan preset 的查找目录" \
  || ng "预设安装路径与 pfan preset 的查找路径不一致"
grep -q 'preset_dir(){ printf' core/pfan \
  && ok "pfan CLI 有 preset 子命令" \
  || ng "pfan CLI 没有 preset 子命令 —— 预设仍然只能手工 cp"
# apply 必须过 validate_params：手工 cp 绕过面板的校验，而 pfand 的自检只查
# 「是不是数字 + 三条关系 + 档位下界」，一个 EMERG < EMERG_REL 的曲线它【能】通过。
grep -q 'validate_params' core/pfan \
  && ok "preset apply 复用 validate_params（与面板同一份校验）" \
  || ng "preset apply 不校验 —— 一个坏曲线会被直接装上"
grep -q 'os.replace\|mv "\$T" "\$PFAN_CONF"' core/pfan \
  && ok "preset apply 是原子替换（守护不会读到半截文件）" \
  || ng "preset apply 不是原子写"
echo
echo "== T22: set -e 脚本里调用可能非0 的命令必须显式兜住 =="
# 第三次同类事故（见 ledger）：hooks/pre-push 顶部有 set -e，我加的
# `bash scripts/sanitize.sh > /dev/null 2>&1` 在发现 19 处命中时返回非0 —— set -e 于是
# 静默终止整个 hook，git 只报 "failed to push some refs"，看不到任何原因。
# 判据：pre-push / ci.sh / deploy.sh 里，形如 `某命令` 且【没有】 || true / || rc=1 /
# || { ... } 收尾的行，且该命令可能非0。
_bad=0
for f in hooks/pre-push scripts/ci.sh scripts/deploy.sh scripts/smoke.sh; do
  [ -f "$f" ] || continue
  # 找出裸的命令调用（不以 if/for/while/&&/|/# 开头，也不是赋值），且同行无 ||
  while IFS= read -r ln; do
    case "$ln" in
      *'||'*|*'&&'*|*'| '*|*'if '*|*'then'*|*'#'*|*'= '*|*'$('*) continue ;;
    esac
    cmd=$(printf '%s' "$ln" | sed 's/^[[:space:]]*//; s/[[:space:]].*//')
    case "$cmd" in
      # rm/cp/mv 的裸调用【不算缺陷】：清理或覆盖失败时 set -e 终止正是想要的行为。
      # 只有"报告型"命令（跑测试/脚本/查询）裸调用才危险 —— 它们返回非0 时
      # 信息会随脚本一起消失。
      bash|sh|python3|node|git)
        # 这些若在 set -e 下裸调用且允许非0，必须已被 || 或 if 包裹
        if ! grep -q "set -[a-z]*e" "$f" 2>/dev/null; then continue; fi
        if ! grep -qE "^[[:space:]]*${cmd} " "$f" 2>/dev/null; then continue; fi
        ng "$f 有裸的 '$cmd ...' 调用且同行无 || 兜住 —— set -e 下会静默终止"
        _bad=$((_bad+1)) ;;
    esac
  done < "$f"
done
[ "$_bad" = 0 ] && echo "  （已检查的脚本里没有未兜住的裸调用）"
echo
echo "== T14: 探测型断言不得把【没连上】当成【通过】（fail-open 守卫）=="
# 专家审计（发布域，实测复现）：§2b 用 `... || true` 吞掉 curl 的退出码，于是
# 超时/连接断开时 acao 为空，紧接着 `[ -z "$acao" ] -> ok` 就把"根本没连上服务器"
# 报成"确认没有 CORS 头"。而 SECURITY.md 正是拿这一段当"不发 CORS 头"的执行依据。
# §2 处理同一个条件是对的（`|| { bad ...; }`），一个文件里两种写法只有一种有效。
# == T14: 探测型断言不得把【没连上】当成【通过】（fail-open 守卫）==
# 专家审计（发布域，实测复现）：§2b 用 `... || true` 吞掉 curl 的退出码，于是
# 超时/连接断开时 acao 为空，紧接着 `[ -z "$acao" ] -> ok` 就把"根本没连上服务器"
# 报成"确认没有 CORS 头"。而 SECURITY.md 正是拿这一段当"不发 CORS 头"的执行依据。
# §2 处理同一个条件是对的（`|| { bad ...; }`），一个文件里两种写法只有一种有效。
#
# 判据要简单到不会自己失效：只看 2b 段里有没有 `|| true`。我前两版正则分别死于
# 「匹配不到跨行的 || true」和「curl 与 || 之间隔着管道，[^|]* 匹配不到」——
# 两次都是"看着有守卫、实际看不见"，与它要防的缺陷同一类。
# ⚠ 必须先剥注释：守卫的第一版把【我自己的说明注释】里那句
# "原来的 `... || true` 把 curl 的退出码丢了" 当成了代码，于是修好后仍然误报红。
# 判注释而不是判代码，是这个仓库已经栽过两次的坑（formatter 折行废掉 substring 守卫；
# 注释含被测名导致守卫自我满足）。这里用行首是否为 # 来过滤 —— 块内注释都在行首。
_corsblk=$(awk '/2b\./,/=== 3\./' scripts/smoke.sh | grep -vE '^[[:space:]]*#')
if printf '%s' "$_corsblk" | grep -qF '|| true'; then
  ng "smoke.sh 2b 的 curl 探测带 || true —— 连不上时会报 ok（fail-open）"
else
  ok "smoke.sh 2b 的探测不吞退出码"
fi
if printf '%s' "$_corsblk" | grep -qE '\|\|[[:space:]]*\{[^}]*bad|UNREACHABLE'; then
  ok "smoke.sh 2b 对不可达有显式分支"
else
  ng "smoke.sh 2b 不可达时没有显式 bad 分支"
fi
echo "== T15: 只有【唯一】一个默认兜底，且不得用 cwd 相对路径读权威配置 =="
# 同一份审计：EMERG 是从 config/pfand.conf.example 用【cwd 相对路径】读的，
# 读不到就静默兜底 80。smoke.sh 从不改 cwd，于是从别的目录跑时读不到，
# 应急满速的断言就变成对着一个硬编码常量断言 —— 而且是唯一一个 fail-open 的默认值
# （同文件其它相对路径读取都会 bad 退出，只有它静默）。
grep -qE '^cd "\$\(dirname "\$0"\)' scripts/smoke.sh \
  && ok "smoke.sh 先 cd 到仓库根（相对路径读配置才成立）" \
  || ng "smoke.sh 没有 cd 到仓库根 —— EMERG 等 cwd 相对读取会失效"
# 光有 cd 不够：兜底值本身也必须是 fail-closed 的。变异证明把兜底改回 80 时
# 上面那条守卫照样全绿。EMERG 是应急满速断言的唯一依据，兜底 80 = 断言转去对着
# 一个硬编码常量，而 config/pfand.conf.cool-quiet 就是 EMERG=85。
grep -qE 'EMERG_V=0;' scripts/smoke.sh \
  && ok "EMERG 读不到时兜底 0（断言只会更严），不是静默兜底 80" \
  || ng "EMERG 的兜底值不是 0 —— 读不到时应急断言会对着一个硬编码常量"
grep -qE 'EMERG_V=80' scripts/smoke.sh \
  && ng "smoke.sh 里还有静默的 EMERG_V=80 兜底" \
  || ok "没有静默的 EMERG_V=80 兜底"
echo
echo "test_repo_hygiene: fails=$fails"
exit "$fails"
