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
# ⚠ 不能只判 'beszel_data' 这个词出现过：变异证明把第 5 段整个比对删掉、
# 注释里留着 beszel_data，T6 照样绿。判据必须是【真的执行了 sha256 比对】。
_s5=$(awk '/部署件比对|^printf.*5\./,/^printf.*6\./' scripts/smoke.sh)
if [ -z "$_s5" ]; then _s5=$(awk '/beszel_data/{f=1} f' scripts/smoke.sh | head -40); fi
# 路径现在是 $PANEL_DIR（从 platform.conf 派生），判据必须跟着走
if printf '%s' "$_s5" | grep -vE '^[[:space:]]*#' | grep -qE 'sha256sum .*\$PANEL_DIR'; then
  ok "smoke.sh 对面板目录真的执行 sha256 比对"
else
  ng "smoke.sh 没有对面板目录执行 sha256 比对 —— 比对被删了也会报绿"
fi
if printf '%s' "$_s5" | grep -qE '\$PANEL_DIR/\$f|\$PANEL_DIR/[a-z]+\.(html|js|css)'; then
  ok "第 5 段比对的是线上文件（逐个文件名）"
else
  ng "第 5 段没有逐个比对线上文件"
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
# ⚠ 不能只判 'probe_rc=' 出现过：变异证明把 `|| probe_rc=$?` 删掉、只留
# `probe_rc=0` 这行初始化，T8 照样绿 —— 而初始化恰恰是它不该认的东西。
if grep -qE '\|\| *probe_rc=\$\?' hooks/pre-push; then
  ok "pre-push 用 '|| probe_rc=\$?' 接住 ssh 退出码"
else
  ng "pre-push 没有捕获 ssh 退出码（'|| probe_rc=\$?'）—— 不可达时原因不打印、PFAN_SKIP_SMOKE 无效"
fi
_prc=$(grep -c 'probe_rc' hooks/pre-push 2>/dev/null || echo 0)
[ "$_prc" -ge 2 ] || ng "pre-push 里 probe_rc 只出现 $_prc 次 —— 捕获那条被删了"

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
# ⚠ 四条子检查全部从「字符串出现过」改成「结构上真的做了那件事」。审计 I-5 的变异：
#   把 deploy.sh 里 vendor 的三条 install 全删掉（保留备份/传输/注释），四条子检查
#   全部照绿 —— 因为它们判的是路径字符串出现过，而备份清单里也有这些路径。
# 判据一：vendor 必须出现在【传输行】或【install 行】上，而不是任意位置。
if grep -E "^[[:space:]]*(S |sudo -n install )" scripts/deploy.sh | grep -qF "$VF" \
   || grep -E "^S panel/vendor/" scripts/deploy.sh >/dev/null 2>&1; then
  ok "deploy.sh 在【传输/install 行】上处理 vendor 资源"
else
  ng "vendor 只出现在备份清单或注释里，没有被真正传输/安装 —— 部署后面板会全挂而闸门全绿"
fi
# 判据二：必须有 install 到 vendor 目录（备份 ≠ 安装）。
# 注意路径现在是 $PDIR（从 platform.conf 派生），不再字面量 beszel_data ——
# 所以判据也必须跟着，否则改一次部署路径守卫就误报（这本身就是守卫该有的行为：
# 路径从单一事实源派生后，硬编码字面量的守卫第一个失效）。
if grep -E 'install .*\$PDIR/vendor/' scripts/deploy.sh | grep -q .; then
  ok "deploy.sh 把 vendor 文件 install 到 \$PDIR/vendor"
else
  ng "deploy.sh 没有 install 到 vendor 目录 —— 只有备份，线上仍然没有这个文件"
fi
# 判据三：必须真的 mkdir（首台机器上目录不存在时 install 会失败）
if grep -E 'mkdir .*\$PDIR(/vendor)?' scripts/deploy.sh | grep -q .; then
  ok "deploy.sh 创建 vendor 目录"
else
  ng "deploy.sh 没建 vendor 目录 —— 首台机器上 install 会失败"
fi
# 判据三之二：三处必须同源（deploy / smoke / pfanel 都从 platform.conf 派生）
_d=$(grep -cE '^PANEL_DIR="\$\{PFAN_PANEL_DIR' scripts/deploy.sh 2>/dev/null || echo 0)
_sm=$(grep -cE '^PANEL_DIR="\$\{PFAN_PANEL_DIR' scripts/smoke.sh 2>/dev/null || echo 0)
_py=$(grep -cE 'PFAN_PANEL_DIR", _PLAT\.get\("PANEL_DIR"' server/pfanel.py 2>/dev/null || echo 0)
if [ "$_d" -ge 1 ] && [ "$_sm" -ge 1 ] && [ "$_py" -ge 1 ]; then
  ok "面板目录在 deploy/smoke/pfanel 三处同源派生（改 platform.conf 一处即可）"
else
  ng "面板目录不同源（deploy=$_d smoke=$_sm pfanel=$_py）—— 改一处会让另两处静默指错目录"
fi
grep -qE '^PANEL_DIR=' platform/platform.conf.example \
  && ok "platform.conf.example 声明了 PANEL_DIR（单一事实源）" \
  || ng "platform.conf.example 没有 PANEL_DIR —— 三处派生会各自落回默认"
# 判据三之三：已存在但【缺 PANEL_DIR】的 platform.conf 必须被幂等补上，两个条件分开判。
# 2026-10-11：`pfan detect --write` 直到本次提交才写 PANEL_DIR，而 deploy 只在文件
# 【缺失】时写它 —— 凡此前跑过 detect 的机器上都没有该键（实测目标机
# `sudo grep -c '^PANEL_DIR=' /etc/pfan/platform.conf` = 0），pfanel.py 于是静默落回
# 代码里的字面量兜底，与本脚本/smoke.sh 读 example 分歧。
#
# ⚠ 这是【结构守卫】：deploy.sh 的这一段是远端 sudo 段，本机跑不起来，只能判形态。
# 能抓的是两种真实退化 —— 幂等门被删（每次部署都追加一行）、追加语句被删
# （目标机永远拿不到该键）。抓不到的是远端执行本身失败（那要真机部署才验）。
_b3a=$(awk '/3a\. 平台配置/,/fan-candidates\.txt/' scripts/deploy.sh)
if printf '%s\n' "$_b3a" | grep -q "grep -q '\^PANEL_DIR='"; then
  ok "deploy.sh 补 PANEL_DIR 前先判该键在不在（重复部署不重复追加）"
else
  ng "deploy.sh 补 PANEL_DIR 没有幂等门 —— 每次部署都会再追加一行"
fi
if printf '%s\n' "$_b3a" | grep -q 'echo PANEL_DIR=\$PANEL_DIR >> /etc/pfan/platform.conf'; then
  ok "deploy.sh 把已解析的 \$PANEL_DIR 追加进 platform.conf（补的就是这次部署到的目录）"
else
  ng "deploy.sh 没有把 \$PANEL_DIR 追加进 platform.conf —— 已存在但缺该键的机器永远补不上"
fi
# 判据四：smoke 必须把 vendor 路由放进【被遍历的 URL 列表】。注意实际形态是
# `for u in /pfan.css ... /pfan-vendor-uplot.js ...` —— 路径在 for 的列表里，
# 请求由循环体内的 curl 发出。所以判据是"出现在 for 列表中"，不是"同行有 curl"。
_vurl=$(grep -E '^[[:space:]]*for [a-z_]+ in .*pfan-vendor-uplot' scripts/smoke.sh)
if [ -n "$_vurl" ]; then
  ok "smoke.sh 把 vendor 路由放进被遍历的 URL 列表"
else
  ng "smoke.sh 没把 vendor 路由放进遍历列表 —— 部署漏装时冒烟仍报绿"
fi
# 且循环体里真的发了请求（否则列表里的路径是摆设）
if grep -E 'curl .*\$u' scripts/smoke.sh | grep -q .; then
  ok "smoke.sh 对列表里的每个 URL 真的发请求"
else
  ng "smoke.sh 的遍历列表里有 vendor 路由但没有 curl \$u —— 根本没请求"
fi
# 判据五：ci 的必需文件清单要【逐个列出】三个 vendor 文件（漏一个就少一个守卫）
_vmiss=""
for _v in uPlot.esm.js uPlot.min.css uPlot.LICENSE; do
  grep -qF "$_v" scripts/ci.sh || _vmiss="$_vmiss $_v"
done
[ -z "$_vmiss" ] \
  && ok "ci.sh 必需清单含全部三个 vendor 文件" \
  || ng "ci.sh 必需清单缺：$_vmiss"


sec "T12: 恢复点必须覆盖第 3 步覆盖的每一个路径（否则半途失败不可回滚）"
# 专家审计 C2：恢复点原本只备 5 个 /usr/local/bin/* 二进制，而第 3 步还会覆盖
# /etc/logrotate.d/pfan、/usr/local/lib/pfan/platform.sh、/etc/pfan/fan-candidates.txt
# 与 4 个面板文件。中途失败 = 新二进制 + 旧面板的混合态，而重跑 deploy 会把混合态
# 再备一次 —— 原始好状态永远丢失。
# 面板路径在 deploy.sh 里已是 $PDIR（从 platform.conf 派生），所以这里比对的是
# 变量形态的字面量 "$PDIR/..."，而不是展开后的绝对路径 —— 否则换一个部署目录
# 守卫就误报（守卫必须跟着抽象走，否则它守的是一个已不存在的东西）。
for path in /etc/logrotate.d/pfan /usr/local/lib/pfan/platform.sh \
            /etc/pfan/fan-candidates.txt '$PDIR/index.html' \
            '$PDIR/styles.css' '$PDIR/app.js' '$PDIR/core.js'; do
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

echo "== T26: 文档不得把【已存在的东西】记成未完成 =="
# 2026-10-10：OPERATIONS.md 的发布前置条件里，sanitize.sh 明明存在且 rc=0，
# 那一行却还写着「脚本尚不存在」。发布清单谎报自己的状态比没有清单更糟 ——
# 半年后作者会照着它相信仓库还没准备好。
# ⚠ 判据必须是【存在性】，不能只判措辞：`状态：未完成` 本身可能完全正当
# （确实有活没干），所以这里对每个点名的东西真的去 test -e。
for _p in scripts/sanitize.sh; do
  # ⚠ 正则与路径必须分开：上一版把 sed 出来带反斜杠的字符串直接喂给 [ -e ]，
  # 于是 test 的是一个名字里真带反斜杠的文件 —— 永远不存在，于是永远 ok。
  # 守卫自己恒绿，正是它要防的那类缺陷。
  _re=$(printf '%s' "$_p" | sed 's/[.[\*^$]/\\&/g')
  if grep -qE "$_re" docs/OPERATIONS.md 2>/dev/null \
     && grep -qE '尚未创建|脚本尚不存在' docs/OPERATIONS.md 2>/dev/null; then
    if [ -e "$_p" ]; then
      ng "docs/OPERATIONS.md 仍称 $_p 尚未创建 —— 它存在（发布清单谎报自己的状态）"
    else
      ok "$_p 确实不存在，状态行成立"
    fi
  else
    ok "docs/OPERATIONS.md 不再把 $_p 记成尚未创建"
  fi
done
# 反向：豁免是【有意的保留】，文档必须点名它，不能只说「已处理」。
# 门本身在 scripts/sanitize.sh，它才有豁免清单；所以「逐条豁免」这句必须与它对齐。
if grep -q '未删除、已逐条豁免' docs/OPERATIONS.md 2>/dev/null \
   && grep -q 'sanitize.allow' docs/OPERATIONS.md 2>/dev/null; then
  ok "OPERATIONS.md 说明 LAN 地址是【逐条豁免】并点名 sanitize.allow（不是含糊的「已处理」）"
else
  ng "OPERATIONS.md 未说明 LAN 地址的保留方式是逐条豁免 —— 读者会以为该删没删"
fi
echo

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
# `bash scripts/sanitize.sh > /dev/null 2>&1` 在发现命中时返回非0 —— set -e 于是
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
echo "== T23: SECURITY.md 作为【公开】文档必须可用 =="
# 审计 checklist 第 9 项：SECURITY.md 原来写「请在本仓库开 issue」，而远端是私有仓库 ——
# 对着私密 issue 通道说「开 issue」既不指向任何私密通道，也训练报告者把细节贴到公开处。
# 对一台 root 运行、/dev/pfanctl 等价于 root 的设备，这正是最不该发生的事。
grep -qE '请在本仓库开 issue' SECURITY.md \
  && ng "SECURITY.md 仍让报告者开 issue —— 远端是私有仓库，且会训练报告者公开细节" \
  || ok "SECURITY.md 不再指示开公开 issue"
grep -qE 'Report a vulnerability|私密漏洞报告|private vulnerability' SECURITY.md \
  && ok "SECURITY.md 指向 GitHub 私密漏洞报告" \
  || ng "SECURITY.md 没有指向私密漏洞报告通道"
grep -qE '^#+ *Supported Versions|^#+ .*支持版本' SECURITY.md \
  && ok "SECURITY.md 有 Supported Versions 段（GitHub 安全页需要才渲染）" \
  || ng "SECURITY.md 缺 Supported Versions 段"
grep -q '不要在公开' SECURITY.md \
  && ok "SECURITY.md 明确要求不要公开可利用细节" \
  || ng "SECURITY.md 未禁止公开可利用细节"
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
echo "== T24: 脱敏门的宣称必须与实现逐条对应，且新增的两条规则必须真的能拦住东西 =="
# 这条守卫针对的正是它自己这个失败类：8013ff0 的 --list 印了 5 类规则，脚本只编译了
# 3 条，缺的两条（带用户名的远端目标、私网网段）在 --list 上写着、在实现里没有，而 pfan
# 就在本仓库可执行文件里躺着。宣称与实现各说各话，跟这个门要拦的东西是同一种病。
#
# ⚠ 探针必须放在【仓库内且在 git index 里】：sanitize.sh 扫的是 `git ls-files`。
#   brief 原本用 `mktemp -d` 放到仓库外，那样的文件门永远看不见，断言只会恒红。
#   用 `git add -N`（intent-to-add）登记，trap 里连文件带 index 一起清掉。
_probe="scratch-t24-probe.md"
_san_root=$(git rev-parse --show-toplevel 2>/dev/null)
if [ -z "$_san_root" ]; then
  ng "不在 git 仓库里 —— 无法验证脱敏门"
else
  _t24_cleanup() {
    cd "$_san_root" 2>/dev/null || return 0
    rm -f "$_probe"
    git rm --cached --force -q "$_probe" 2>/dev/null
    git reset -q -- "$_probe" 2>/dev/null
    return 0
  }
  trap _t24_cleanup EXIT INT TERM

  # ---- 24a: --list 逐条印出【实际编译】的正则 ----
  # 从规则块里逐行取出正则，逐条要求它原样出现在 --list 输出里。散文里也可能写着
  # 长得像正则的东西（8013ff0 的 "~/.ssh/id_[a-z0-9]*" 就是），所以只验"出现"不够，
  # 还要验条数相等：--list 印出来的规则条数必须等于规则块的条数，一个不多一个不少。
  _blk_start=$(grep -n '^RULES=\$(cat' scripts/sanitize.sh | head -1 | cut -d: -f1)
  if [ -z "$_blk_start" ]; then
    ng "scripts/sanitize.sh 里找不到规则块起点（RULES=\$(cat ...）—— T24 自己先失效了"
  else
    # ⚠ 规则块的结束标记是【单独一行的 RULES】（heredoc 定界符），不是行首的 `)` ——
    #   `)` 收的是整个 $(...) 命令替换，在定界符之后三行。第一版按 `^\)$/` 停，
    #   多吞了两行注释和定界符本身，5 条数成 9 条，断言跟着一起错。
    _blk=$(awk -v s="$_blk_start" 'NR>s && /^RULES$/ {exit} NR>s {print}' scripts/sanitize.sh)
    _n_real=$(printf '%s\n' "$_blk" | grep -c "$(printf '\t')")
    _list=$(bash scripts/sanitize.sh --list 2>/dev/null)
    _n_list=$(printf '%s\n' "$_list" | grep -cE '^  \[[0-9]+\] ')
    if [ "$_n_list" = "$_n_real" ]; then
      ok "--list 印出 $_n_list 条规则，与编译进 RULES 的 $_n_real 条条数相等"
    else
      ng "--list 印了 $_n_list 条而编译了 $_n_real 条 —— 宣称与实现对不上"
    fi
    _miss=""
    while IFS="$(printf '\t')" read -r _re _why; do
      # 无 TAB 的行不是规则（块里还有非规则行），别拿它们去 --list 里找
      [ -n "$_re" ] && [ -n "$_why" ] || continue
      case "$_list" in
        *"$_re"*) ;;
        *) _miss="$_miss|$_re" ;;
      esac
    done <<< "$_blk"
    if [ -z "$_miss" ]; then
      ok "--list 里逐条都能找到编译进来的正则（无只宣不编的类别）"
    else
      ng "这些正则编译进来了但 --list 没印:${_miss}"
    fi
  fi

  # ---- 24b/24c: 每条新规则都必须真能拦住东西 ----
  # ⚠ 探针字符串【故意拆成碎片再拼】：门扫的是整个仓库，本测试文件也在里面。
  #   把「用户名@私网地址」那样一整串完整写出来的话，门会把本文件自己判成命中
  #   （2026-10-11 实测：光这一个文件就贡献了 10 处）—— 测试还没写完，
  #   自己的门先把自己判红了。拼出来的那一行仍然是货真价实的实例，拦的是它。
  _f_at='@'
  _f_user='dep''loy'
  _f_privip='10.44.''7.21'
  _f_privip2='192.168.''7.42'

  printf 'probe: ssh %s%s%s true\n' "$_f_user" "$_f_at" "$_f_privip" > "$_probe"
  git add -N "$_probe" 2>/dev/null
  if ! git ls-files | grep -qx "$_probe"; then
    ng "探针没进 git ls-files —— T24 的探针机制本身坏了，后两条断言无效"
  else
    # ⚠ 规则名必须与探针命中落在【同一行】。早先是分两次 grep 整个输出，那是两件
    #   互不相干的事：把「带用户名的远端目标」那条规则改废之后（M2 变异），探针仍被私网网段命中，
    #   而"带用户名的远端目标"这个串仍在输出里 —— 因为门会把命中行的【原文】也打出来，
    #   而那行正是本测试文件自己的 ok 消息。两个 grep 都过，规则已死，断言却报 [ok]。
    _out=$(bash scripts/sanitize.sh 2>/dev/null)
    if printf '%s\n' "$_out" | grep -F "$_probe:1" | grep -qF '带用户名的远端目标'; then
      ok "规则【带用户名的远端目标】能拦住带用户名的远端目标探针"
    else
      ng "规则【带用户名的远端目标】拦不住 <user>@<host> —— --list 宣称拦它，实现里没有"
    fi

    printf 'probe: target host is %s\n' "$_f_privip2" > "$_probe"
    _out=$(bash scripts/sanitize.sh 2>/dev/null)
    if printf '%s\n' "$_out" | grep -F "$_probe:1" | grep -qF '私网地址'; then
      ok "规则【私网地址】能拦住私网地址探针"
    else
      ng "规则【私网地址】拦不住私网地址 —— --list 宣称拦它，实现里没有"
    fi

    # 反向：该不拦的不能拦。公网 IP、npm 版本号、@占位符、三段式、172.32 都在
    # 私网之外；这条拦不住的话，一条什么都拦的规则也能让上面两条"通过"。
    printf 'dns 8.8.8.8\npkg uplot@1.6.32\nzone @TEMP@\nrange 172.32.0.1\nshort 192.168.1\n' > "$_probe"
    _out=$(bash scripts/sanitize.sh 2>/dev/null)
    if printf '%s\n' "$_out" | grep -qF "$_probe:"; then
      ng "新规则误报：公网 IP / npm 版本号 / 占位符 / 三段式 / 172.32 不该被拦"
    else
      ok "新规则不误报：公网 IP / npm 版本号 / 占位符 / 三段式 / 172.32 均未被拦"
    fi

    # ---- 24d: 这个脚本自己必须过得去自己的门 ----
    # 规则文本与头部注释里举的例子必然命中自己，为此排除了「本文件的规则块 + 注释行」。
    # 一旦有人把那个排除删掉，这个脚本就再也过不了自己 —— 和整个门对 fork 不可满足
    # 是同一类病（宣称能过，实际过不了），所以在这里钉死。
    # 反向也验一次：排除【只】对 sanitize.sh 生效，别处的带用户名远端目标该拦还得拦。
    #
    # ⚠ ⚠ 下面两断言都先把输出【收进变量】再 grep，【不】写 `sanitize.sh | grep -q`。
    #   本文件开头有 `set -uo pipefail`，而 grep -q 命中即退出并关掉管道 →
    #   sanitize.sh 收 SIGPIPE（141）→ pipefail 取最右边的非零 → `&&` 分支永远不走，
    #   断言把"命中了"报成"没命中"。第一版就是这么写的，而且只在绿的那条路径上
    #   看起来正常（grep 没命中时会读完整个输入，不会 SIGPIPE）—— fail-open 到看不出来。
    _self=$(bash scripts/sanitize.sh 2>/dev/null)
    if printf '%s\n' "$_self" | grep -q '^  scripts/sanitize\.sh:'; then
      ng "sanitize.sh 命中了自己（规则块/注释的自我排除被删或失效）—— 它过不了自己的门"
    else
      ok "sanitize.sh 过得去自己的门（规则块与注释的自我排除生效）"
    fi
    printf 'probe: ssh %s%s"$PFAN_HOST" true\n' "$_f_user" "$_f_at" > "$_probe"
    _self=$(bash scripts/sanitize.sh 2>/dev/null)
    if printf '%s\n' "$_self" | grep -qF "$_probe:1"; then
      ok "自我排除没有溢出到其它文件（探针仍被拦）"
    else
      ng "自我排除溢出：探针里的带用户名远端目标没被拦住"
    fi
  fi
  _t24_cleanup
  trap - EXIT INT TERM
  # 只查探针本身有没有留痕，【不】查整个工作区是否干净 —— 这个测试本来就是在带
  # 未提交改动的工作区里跑的，拿 git status 当判据会把开发者自己的改动算成失败。
  if [ -e "$_probe" ] || git ls-files | grep -qx "$_probe"; then
    ng "T24 跑完探针还留在仓库里（文件或 git index 里都有残留）"
  else
    ok "T24 探针已清除：文件与 git index 都无残留"
  fi
fi
echo "== T25: 豁免清单必须逐条必要、逐条不宽，且不能把门变成空门 =="
# 这条守卫针对 2026-10-10 之前的状态：scripts/sanitize.allow 在 .gitignore 里，而且
# 根本不存在。于是「门报红 → 写进 allow → 门变绿」这条路在新克隆和任何 fork 上都是
# 断的：门对所有人恒红（含作者自己），唯一能过的树是本机那份不存在的文件。
# 它提交进仓库之后，多出三条必须钉死的义务 —— 少一条，"全绿"就换了个意思：
#   1) 每条豁免都【单独】必要。删掉任何一条，门必须对它覆盖的那些行转红。
#      不钉的话，早晚有人会往里补一条 ^docs/.*$ 之类的宽模式，门从此恒绿而什么都不
#      再拦 —— 而"恒绿"正是这个门对外唯一可观察的输出。
#   2) 豁免不能比它声称的宽。这条是 2026-10-16 把锚定从【行号】换成【内容指纹】
#      之后才补上的：行号锚定时"同文件里新写的行照拦"是免费得到的，换成内容锚定
#      就得单独验 —— 一条锚在太短的片段上的豁免，会顺带放过同一文件里任何含这个
#      片段的新行。25c/25f 钉这一半。
#   3) 锚定不能脆。指纹锚定就是为了让"在豁免行上面插一段话"不再转红，25e 钉这一半。
# 三条一起才说明绿是"这 50 处被有理由地豁免了"，不是"门没长牙"。
#
# 实现取巧的地方必须说清楚：为什么不是"真的删一条、跑一遍门"。26 条各跑一次全仓库
# 扫描实测 3m38s（单次门实测 2s 上下，机器负载高时更久），CI 跑不起。这里改成：
# 把 allow 临时挪开【一次】拿到门
# 的原始命中清单（这一步是真的跑门），再对每条豁免算"它是否独占覆盖了至少一行"。
# 两者等价：一条豁免独占覆盖 0 行 ⇔ 删掉它门不会变红。
# ⚠ 本测试【自己重算一遍指纹与判定】，不复用 sanitize.sh 的 _exempt_by：两处实现
#   各算各的，才谈得上"两边对得上"。它同时是第二处 sha256 实现（sha256 就是为了让
#   两边算出同一个值才选的；cksum 只有 32 位 CRC，不够）。
# 挪动全程 trap 兜底；`_allow` 与 `_allow.t25` 都不会被扫（后者不在 git ls-files 里）。
_allow="scripts/sanitize.allow"
_stash=""
_t25_restore() {
  cd "$repo" 2>/dev/null || return 0
  if [ -n "$_stash" ]; then mv -f "$_stash" "$_allow" 2>/dev/null; _stash=""; fi
  return 0
}

if ! git ls-files --error-unmatch "$_allow" >/dev/null 2>&1; then
  ng "$_allow 没有被 git 跟踪 —— fresh clone 与 fork 上门恒红且无处可豁免"
  git check-ignore -q "$_allow" 2>/dev/null \
    && ng "$_allow 仍在 .gitignore 里（git check-ignore 命中）—— 就是它当初让门无处可豁免"
else
  ok "$_allow 已提交（fresh clone 与 fork 读到同一份豁免清单）"

  _probe="scratch-t25-probe.txt"
  trap _t25_restore EXIT INT TERM
  _t25_clean() {
    _t25_restore
    cd "$repo" 2>/dev/null || return 0
    rm -f "$_probe"
    git rm --cached --force -q "$_probe" 2>/dev/null
    git reset -q -- "$_probe" 2>/dev/null
    return 0
  }
  trap _t25_clean EXIT INT TERM

  # ---- 25a: 门现在必须自己就绿（allow 文件在场）----
  _san=$(bash scripts/sanitize.sh 2>/dev/null)
  if printf '%s\n' "$_san" | grep -q '^  \[ok\]'; then
    ok "当前树过得了自己的门（豁免清单生效后 0 命中）"
  else
    ng "豁免清单已在，但树仍然过不了自己的门 —— 有命中没被豁免到："
    printf '%s\n' "$_san" | grep -E '^  [^ ]+:[0-9]+  \[' | sed 's/^/       /' | head -20
  fi

  # ---- 25b: 逐条必要性（指纹锚定） ----
  # 把 allow 挪开跑一次门，拿到【原始】命中清单（这才是每条豁免在替谁顶罪）。
  mv -f "$_allow" "$_allow.t25" 2>/dev/null && _stash="$_allow.t25"
  if [ -z "$_stash" ]; then
    ng "临时挪开 $_allow 失败 —— 逐条必要性这条断言无效"
  else
    _raw_all=$(bash scripts/sanitize.sh 2>/dev/null | grep -oE '^  [^ ]+:[0-9]+' | sed 's/^  //')
    mv -f "$_stash" "$_allow" 2>/dev/null; _stash=""
    _n_pairs=$(printf '%s\n' "$_raw_all" | grep -c .)
    # ⚠ 按 file:line 去重再往下算：同一行被两条规则命中时门会印两遍（一规则一遍），
    #   不去重的话「这个指纹对应几处出现」会被数成 2，一条没问题的豁免会误报变宽。
    _raw=$(printf '%s\n' "$_raw_all" | sort -u)
    _n_raw=$(printf '%s\n' "$_raw" | grep -c .)
    if [ "$_n_raw" -lt 1 ]; then
      ng "挪开 allow 之后门一个命中都不报 —— 豁免清单【不是】在替这棵树顶罪，它要么是空的，要么规则已经瞎了"
    else
      ok "挪开 allow 后门报出 $_n_pairs 处原始命中、去重后 $_n_raw 处位置（豁免清单确实在顶罪）"

      # 条目按三段拆开：<文件正则><TAB><指纹表><TAB><理由>
      _e_file=(); _e_hash=()
      while IFS=$'\t' read -r _f1 _f2 _f3 _rest; do
        case "$_f1" in ''|'#'*) continue ;; esac
        _e_file+=("$_f1"); _e_hash+=("$_f2")
      done < "$_allow"
      _n_ent=${#_e_file[@]}
      if [ "$_n_ent" -lt 1 ]; then
        ng "$_allow 里一条豁免都没有 —— 门要么本来就绿（规则瞎了），要么靠 scripts/sanitize.local"
      else
        # ---- 形态检查：锚点必须是"钉死一个文件 + 64 位指纹"，不能是通配大范围 ----
        _wide=""; _badhash=""
        for _i in "${!_e_file[@]}"; do
          case "${_e_file[$_i]}" in
            '^'*'$') ;;
            *) _wide="$_wide ${_e_file[$_i]}(未用 ^…$ 锚死)" ;;
          esac
          case "${_e_file[$_i]}" in
            *'*'*) _wide="$_wide ${_e_file[$_i]}(含通配)" ;;
          esac
          for _one in $(printf '%s' "${_e_hash[$_i]}" | tr ',' ' '); do
            _h_clean=1
            case "$_one" in *[!0-9a-f]*) _h_clean=0 ;; esac
            [ "$_h_clean" = 1 ] && [ "${#_one}" = 64 ] || _badhash="$_badhash ${_one}"
          done
        done
        if [ -z "$_wide" ] && [ -z "$_badhash" ]; then
          ok "$_n_ent 条豁免的文件列全部 ^…$ 锚死且不含通配，指纹列全部是 64 位十六进制"
        else
          [ -n "$_wide" ] && ng "这些豁免的文件列不是钉死的单文件锚点：$_wide"
          [ -n "$_badhash" ] && ng "这些指纹不是 64 位十六进制：$_badhash"
        fi

        # ---- 每处原始命中的指纹与"在本文件内是否唯一"，各算一次 ----
        # ⚠ 唯一性是豁免的第三个条件（同一份内容在同一文件里出现两次就不放行），
        #   所以复算它，否则本测试算出来的覆盖关系与门不一致。
        # ⚠ sha256sum 找不到就让这些断言【报红】而不是跳过：算不出指纹时"没有一条
        #   豁免覆盖任何命中"必然成立，放行 = fail-open。
        _h_ok=0
        command -v sha256sum >/dev/null 2>&1 && _h_ok=1
        command -v shasum    >/dev/null 2>&1 && _h_ok=1
        if [ "$_h_ok" = 0 ]; then
          ng "找不到 sha256sum / shasum —— 本测试自己算不出指纹，逐条必要性这条断言无效"
        else
          _k_f=(); _k_n=(); _k_h=(); _k_u=()
          _t_sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}'
                      else shasum -a 256 | awk '{print $1}'; fi; }
          for _hl in $_raw; do
            _kf=${_hl%:*}; _kn=${_hl##*:}
            _kt=$(awk -v n="$_kn" 'NR==n {print; exit}' "$_kf" 2>/dev/null)
            _k_f+=("$_kf"); _k_n+=("$_kn")
            _k_h+=("$(_t_sha <<<"$_kt")")
            _kd=$(grep -cFx -e "$_kt" -- "$_kf" 2>/dev/null) || _kd=0
            _k_u+=("$_kd")
          done
          _hash_in() { # _hash_in <指纹> <逗号分隔指纹表>
            local want=$1 list=$2 one _old=$IFS
            IFS=','
            for one in $list; do [ "$one" = "$want" ] && { IFS=$_old; return 0; }; done
            IFS=$_old
            return 1
          }
          _covers() { # _covers <条目下标> <命中下标>
            local i=$1 k=$2
            [ "${_k_u[$k]}" = 1 ] || return 1
            [[ ${_k_f[$k]} =~ ${_e_file[$i]} ]] || return 1
            _hash_in "${_k_h[$k]}" "${_e_hash[$i]}"
          }
          _dead=""; _uncovered=""
          for _i in "${!_e_file[@]}"; do
            _excl=0
            for _k in "${!_k_f[@]}"; do
              _covers "$_i" "$_k" || continue
              _others=0
              for _j in "${!_e_file[@]}"; do
                [ "$_j" = "$_i" ] && continue
                _covers "$_j" "$_k" && _others=$((_others + 1))
              done
              [ "$_others" -eq 0 ] && _excl=$((_excl + 1))
            done
            [ "$_excl" -eq 0 ] && _dead="$_dead ${_e_file[$i]}"
          done
          # 反向：每处原始命中都必须被至少一条豁免覆盖（否则门不可能是绿的）
          for _k in "${!_k_f[@]}"; do
            _cov=0
            for _j in "${!_e_file[@]}"; do
              _covers "$_j" "$_k" && _cov=$((_cov + 1))
            done
            [ "$_cov" -eq 0 ] && _uncovered="$_uncovered ${_k_f[$k]}:${_k_n[$k]}"
          done
          if [ -z "$_dead" ]; then
            ok "$_n_ent 条豁免逐条都必要（每条都独占覆盖至少一处命中，删掉任何一条门都会转红）"
          else
            ng "这些豁免删掉也不会让门变红（覆盖的行被别人全包了 = 死重量）：$_dead"
          fi
          if [ -z "$_uncovered" ]; then
            ok "$_n_raw 处原始命中全部被至少一条豁免覆盖（清单与门一一对得上）"
          else
            ng "这些命中没有被任何豁免覆盖，可门却是绿的 —— 清单与实现对不上：$_uncovered"
          fi
          # ---- 方向二（逐条不宽）：每个指纹都恰好对应一处出现 ----
          # 一条锚在整行摘要上的豁免，天然匹配不到内容不同的任何一行；唯一还剩的两条
          # 放宽路径是"同一份内容在同文件里出现两次"（门会拒绝放行并报 WARN）与"指纹
          # 已经对不上任何一行"（那是指纹已经失效 = 纯死重量，删掉它对门毫无影响）。
          # 这一步把两条都钉死：对每个 (条目, 指纹) 组合数一遍该文件里内容完全相同的
          # 行，必须恰好 1 —— 0 是死重量，>1 是放宽。
          # 用 _raw 当候选集是充分的：内容相同 ⇒ 命中同一条规则 ⇒ 必然出现在 _raw 里。
          _wide2=""
          for _i in "${!_e_file[@]}"; do
            for _one in $(printf '%s' "${_e_hash[$_i]}" | tr ',' ' '); do
              _cnt=0
              for _k in "${!_k_f[@]}"; do
                [ "${_k_h[$_k]}" = "$_one" ] || continue
                [[ ${_k_f[$_k]} =~ ${_e_file[$_i]} ]] || continue
                _cnt=$((_cnt + 1))
              done
              [ "$_cnt" -eq 1 ] || _wide2="$_wide2 ${_e_file[$_i]}:${_one}(${_cnt} 处)"
            done
          done
          if [ -z "$_wide2" ]; then
            ok "每个指纹都恰好对应一处出现（0 处 = 失效的死重量，>1 处 = 豁免放宽，两种都没有）"
          else
            ng "这些指纹在本仓库里不是恰好对应一处出现（0 处 = 已失效的死重量，>1 处 = 豁免宽过了）：$_wide2"
          fi
        fi
      fi
    fi
  fi

  # ---- 25c: 同类别的新命中仍然被拦 ----
  # ⚠ 探针字符串照样【拆成碎片再拼】：本测试文件自己也在门的扫描范围内。
  _f_at='@'
  _f_user='dep''loy'
  _f_ip='10.44.''7.21'
  printf 'lan: %s\nprobe: ssh %s%s%s true\n' "$_f_ip" "$_f_user" "$_f_at" "$_f_ip" > "$_probe"
  git add -N "$_probe" 2>/dev/null
  if ! git ls-files | grep -qx "$_probe"; then
    ng "探针没进 git ls-files —— 25c 的探针机制坏了，后面的断言无效"
  else
    _out=$(bash scripts/sanitize.sh 2>/dev/null)
    if printf '%s\n' "$_out" | grep -E "^  $_probe:1 " | grep -qF '私网地址'; then
      ok "同类别的新私网地址仍然被拦（新行的内容与清单里任何指纹都对不上）"
    else
      ng "门放过了一个全新的私网地址 —— 豁免钉的不是那一行内容，是整个文件"
    fi
    if printf '%s\n' "$_out" | grep -E "^  $_probe:2 " | grep -qF '带用户名的远端目标'; then
      ok "同类别的新登录目标（用户名 + @ + 私网地址）仍然被拦"
    else
      ng "门放过了一个全新的登录目标 —— 豁免宽到把新写的同类内容也放过了"
    fi
  fi

  # ---- 25d: carve-out 必须【只】剩主机那一侧，且登录名一侧零排除 ----
  # 六行探针，两个方向同时钉：
  #   · 第 1、4、5、6 行 —— 登录名分别是 root / rootpw / myroot / roots，主机都是外部的。
  #     四行【必须】全部被拦。中间版本只拦后三行，放过第 1 行（登录名恰好 root），而
  #     那正是这道门最该拦的形态：账号名 + 外部机器。2026-10-15 撤掉了那个排除。
  #   · 第 2 行 —— 唯一留下的 carve-out：host 恰为 localhost。它【必须】不报。
  #   · 第 3 行 —— 同一文件里的真实登录目标，必须照拦，证明 carve-out 没顺手放过邻居。
  # 格式串里【一个 @ 都不写】—— 注释与格式串本身也在扫描范围内，而把 @ 和主机名
  # 直接写进格式串的话，@ 前面的 "s"（%s 的尾巴）会拿 % 当左边界、以自己为登录名
  # 把本文件判成命中。% 之后接域名看起来像"没写 @"，其实恰好是最坏的一种写法。
  _f_some='some''host'
  _f_root='ro''ot'
  _f_rootpw='root''pw'
  _f_myroot='my''root'
  _f_roots='roo''ts'
  _f_ex='example''.com'
  printf '%s%s%s\n%s%s%s\n%s%s%s\n%s%s%s\n%s%s%s\n%s%s%s\n' \
    "$_f_root" "$_f_at" "$_f_ex" \
    "$_f_user" "$_f_at" localhost \
    "$_f_user" "$_f_at" "$_f_some" \
    "$_f_rootpw" "$_f_at" "$_f_ex" \
    "$_f_myroot" "$_f_at" "$_f_ex" \
    "$_f_roots" "$_f_at" "$_f_ex" > "$_probe"
  _out=$(bash scripts/sanitize.sh 2>/dev/null)
  # 期望被拦的行号（升序）。第 2 行不在其中 —— 它是刻意留下的 carve-out。
  _want25d="1 3 4 5 6 "
  _got25d=$(printf '%s\n' "$_out" | grep -oE "^  $_probe:[0-9]+" \
    | grep -oE '[0-9]+$' | sort -n | tr '\n' ' ')
  if [ "$_got25d" = "$_want25d" ]; then
    ok "carve-out 只剩主机一侧：localhost 那行放过，登录名为 root/rootpw/myroot/roots 的四行全拦"
  else
    ng "carve-out 不对：期望拦下第 $_want25d 行，实际拦下第 $_got25d 行"
    printf '%s\n' "$_out" | grep -E "^  $_probe:" | sed 's/^/       /'
  fi
  # 拦下来的必须出自这一条规则，而不是碰巧被别的规则兜住。
  if printf '%s\n' "$_out" | grep -E "^  $_probe:" | grep -qF '带用户名的远端目标'; then
    ok "这五行确实由「带用户名的远端目标」这条规则拦下（不是别的规则碰巧兜住）"
  else
    ng "探针的命中里没有「带用户名的远端目标」这条规则 —— 25d 可能在测一个不相干的洞"
  fi

  # ---- 25e: 锚定必须抗位移 —— 在被豁免的行【上面】插一段，门仍然绿 ----
  # ⚠ 先把 25d 的探针文件彻底清掉再往下走：它在 git ls-files 里（25d 用 git add -N
  #   登记的），而它【本来就该被拦】——留着它，25e/25f 每次跑门都会红，红的原因还
  #   与本条要验的东西无关。gate 是全局的，前一个用例的探针必须先落地。
  _t25_clean
  trap _t25_clean EXIT INT TERM
  # 这条钉的是 2026-10-16 这次改动的全部动机：行号锚定时，任何在豁免行之上的编辑都会
  # 把门变红（本分支上因为三处互不相关的改动红过三次，每次都要手工重锚，而重锚是
  # 「悄悄放大覆盖面」的最佳时机）。指纹锚定之后，同样的编辑必须是【无事发生】。
  # 探针选 docs/OPERATIONS.md：它有 3 条豁免共 9 处被锚定的出现，全在第 13~274 行，
  # 插在文件最前面会把它们整体下移 1 —— 正是行号方案必然转红的那种编辑。
  # ⚠ 还原用 cp 而不是 git checkout：测试要跑在带未提交改动的工作区里。
  _shift_f="docs/OPERATIONS.md"
  _bak=$(mktemp "${TMPDIR:-/tmp}/pfan-t25e.XXXXXX") || _bak=""
  _restore_shift() {
    [ -n "$_bak" ] && [ -s "$_bak" ] && cp "$_bak" "$_shift_f" 2>/dev/null
    [ -n "$_bak" ] && rm -f "$_bak"
    return 0
  }
  if [ -z "$_bak" ] || ! cp "$_shift_f" "$_bak" 2>/dev/null; then
    ng "备份 $_shift_f 失败 —— 位移这条断言无效"
  else
    trap '_t25_restore; _restore_shift' EXIT INT TERM
    { printf '%s\n' '<!-- t25 probe: 与脱敏无关的一行插在所有被豁免的行之上 -->'
      cat "$_shift_f"; } > "${_bak}.new" && cat "${_bak}.new" > "$_shift_f"
    rm -f "${_bak}.new"
    _out=$(bash scripts/sanitize.sh 2>/dev/null)
    if printf '%s\n' "$_out" | grep -q '^  \[ok\]'; then
      ok "在被豁免的行上面插入一行后门仍然全绿（豁免锚在内容上，不受位移影响）"
    else
      ng "插入无关的一行就让门变红 —— 豁免仍然钉着行号，或者指纹对不上："
      printf '%s\n' "$_out" | grep -E '^  [^ ]+:[0-9]+  \[' | head -5 | sed 's/^/       /'
    fi
    _restore_shift
    _out=$(bash scripts/sanitize.sh 2>/dev/null)
    if printf '%s\n' "$_out" | grep -q '^  \[ok\]'; then
      ok "还原后门仍然全绿（探针确实清干净了）"
    else
      ng "还原之后门仍然红 —— 25e 的探针没清干净"
    fi
    trap _t25_restore EXIT INT TERM
  fi

  # ---- 25f: 方向二的端到端 —— 在【真的被豁免过的文件里】新写一行同类内容 ----
  # 25c 用的是 scratch 探针文件，它证明"新文件里的新行会被拦"；这里补上另一半：同一个
  # 被豁免过的文件里新写的行也必须被拦。否则"豁免锚在某一行上"就是空话 —— 一条
  # 锚在整行摘要上的豁免不该匹配任何内容不同的行，而内容锚定最容易丢的就是这一半。
  # 两处探针，都刻意用【不同的值】：同一类别、不同字面量。
  # ⚠ 探针字符串【拆成碎片再拼】：本测试文件自己也在门的扫描范围内。
  _probe2_f="docs/OPERATIONS.md"
  _probe2_g="scripts/deploy.sh"
  _bak2=$(mktemp "${TMPDIR:-/tmp}/pfan-t25f.XXXXXX") || _bak2=""
  _bak3=$(mktemp "${TMPDIR:-/tmp}/pfan-t25f.XXXXXX") || _bak3=""
  _restore2() {
    [ -n "$_bak2" ] && [ -s "$_bak2" ] && cp "$_bak2" "$_probe2_f" 2>/dev/null
    [ -n "$_bak3" ] && [ -s "$_bak3" ] && cp "$_bak3" "$_probe2_g" 2>/dev/null
    [ -n "$_bak2" ] && rm -f "$_bak2"
    [ -n "$_bak3" ] && rm -f "$_bak3"
    return 0
  }
  if [ -z "$_bak2" ] || [ -z "$_bak3" ] \
     || ! cp "$_probe2_f" "$_bak2" 2>/dev/null || ! cp "$_probe2_g" "$_bak3" 2>/dev/null; then
    ng "备份探针目标失败 —— 25f 这条断言无效"
  else
    trap '_t25_restore; _restore2' EXIT INT TERM
    _f_at2='@'
    _f_user2='probe''user'
    _f_ip2='10.44.''7.21'
    _f_ext='203.0.113.''5'
    printf '# t25f probe: lan %s\n' "$_f_ip2" >> "$_probe2_f"
    printf '# t25f probe: ssh %s%s%s true\n' "$_f_user2" "$_f_at2" "$_f_ext" >> "$_probe2_g"
    _out=$(bash scripts/sanitize.sh 2>/dev/null)
    # 行号用标记去找，【不】用 grep -c . 数：那个数的是非空行，而这两个文件里有空行
    # （OPERATIONS.md 320 行里只有 247 行非空）—— 数错了行号，断言会去查一个不存在的
    # 位置，然后报「门放过了」，而其实门没放过。断言指错地方比断言红更坏。
    _want_f=$(grep -n 't25f probe' "$_probe2_f" 2>/dev/null | tail -1 | cut -d: -f1)
    _want_g=$(grep -n 't25f probe' "$_probe2_g" 2>/dev/null | tail -1 | cut -d: -f1)
    if [ -n "$_want_f" ] && printf '%s\n' "$_out" | grep -qF "$_probe2_f:$_want_f "; then
      ok "在被豁免过的文档里新写的私网地址仍被拦（豁免没有顺着文件放宽）"
    else
      ng "门放过了 $_probe2_f:$_want_f 里新写的私网地址 —— 豁免宽到把整个文件放开了"
      printf '%s\n' "$_out" | grep -E "^  $_probe2_f:" | sed 's/^/       /'
    fi
    if [ -n "$_want_g" ] && printf '%s\n' "$_out" | grep -qF "$_probe2_g:$_want_g "; then
      ok "在被豁免过的脚本里新写的登录目标仍被拦（同上）"
    else
      ng "门放过了 $_probe2_g:$_want_g 里新写的登录目标 —— 豁免宽到把整个文件放开了"
      printf '%s\n' "$_out" | grep -E "^  $_probe2_g:" | sed 's/^/       /'
    fi
    _restore2
    _out=$(bash scripts/sanitize.sh 2>/dev/null)
    if printf '%s\n' "$_out" | grep -q '^  \[ok\]'; then
      ok "还原后门仍然全绿（25f 的探针确实清干净了）"
    else
      ng "还原之后门仍然红 —— 25f 的探针没清干净"
      printf '%s\n' "$_out" | grep -E '^  [^ ]+:[0-9]+  \[' | head -5 | sed 's/^/       /'
    fi
    trap _t25_restore EXIT INT TERM
  fi

  _t25_clean
  trap - EXIT INT TERM
  if [ -e "$_probe" ] || git ls-files | grep -qx "$_probe"; then
    ng "T25 跑完探针还留在仓库里（文件或 git index 都有残留）"
  else
    ok "T25 探针已清除：文件与 git index 都无残留"
  fi
  if [ -e "$_allow" ]; then
    ok "$_allow 已放回原处"
  else
    ng "$_allow 不见了 —— 挪开时没放回来"
  fi
fi

echo
echo "test_repo_hygiene: fails=$fails"
exit "$fails"
