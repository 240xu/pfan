#!/bin/bash
# 发布前的脱敏门：扫描仓库里的环境绑定字符串。
#
# 为什么需要它：这是一个针对特定机器的运维仓库，里面散布着内网地址、公网隧道
# 主机名、个人 SSH 用户名与私钥路径。作为**私有**仓库这没问题；一旦远端指向公开
# 仓库，这些字符串就会把某个人的家庭网络拓扑、活跃的服务入口和账号名一起公开。
#
# 设计上刻意不做无脑替换：`HOST="${PFAN_HOST:-192.168.1.10}"` 这类代码默认值
# 删了就坏，替换成占位符会让 fork 之后的行为与文档不符。所以本脚本的职责是
# **报告并阻断推送**，由作者逐处裁决：要么改掉，要么写进 allowlist 并说明理由。
#
# 规则来源（后者覆盖/追加前者）：
#   1. 内置通用规则 —— 对任何公开仓库都成立的禁止项
#   2. scripts/sanitize.local —— 本仓库特有的禁止项（gitignored，不提交）
#   3. scripts/sanitize.allow —— 逐条豁免，格式 <正则><TAB><理由>（【已提交】）
#
# 第 2 条与第 3 条的分界就是「可复现性」：sanitize.local 是本机特有的禁止项，别人
# 看了学不到东西，所以不提交；sanitize.allow 是这个仓库【每一处豁免的理由】，删掉
# 它之后门对所有人恒红且无处可豁免（这正是 2026-10-10 之前的状态），所以它必须跟着
# 仓库走，并且对 fork 同样可用。
#
# 用法：
#   bash scripts/sanitize.sh            # 检查并列出违规（发现即非零退出）
#   bash scripts/sanitize.sh --list     # 只列出【实际编译】的规则，不扫描
#
# --list 为什么必须遍历 $RULES 而不是印一段散文：2026-10-10 实测，原来的 --list 印了
# 5 类规则，脚本实际只编译了 3 条（缺 <用户>@<主机> 与私网网段），而 `pfan@` 就在本仓库
# 的可执行文件里躺着、一条都没被拦住。散文与实现可以各说各话，正是这个门存在的目的
# 要拦的那类失败（宣称能看见而实际上看不见）。现在 --list 直接打印 $RULES，宣称与实现
# 不可能不一致。
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

LOCAL_RULES="scripts/sanitize.local"
ALLOW="scripts/sanitize.allow"
SELF_FILE="scripts/sanitize.sh"

# ---- 收集规则：<正则><TAB><说明>，逐行 ----
RULES=$(cat <<'RULES'
\.ssh/(id_[A-Za-z0-9]+|pfan_deploy_key|[^ /]*\.pem)	私钥路径：公开仓库里不该出现具体密钥文件名
/Users/[A-Za-z0-9_.-]+/	macOS 用户目录：泄露本机用户名
(^|[^A-Za-z0-9_.-])([A-Za-z0-9_.-]{1,3}|[0-9A-Za-qs-z_.-][A-Za-z0-9_.-]*|r[0-9A-Za-np-z_.-][A-Za-z0-9_.-]*|ro[0-9A-Za-np-z_.-][A-Za-z0-9_.-]*|roo[0-9A-Za-su-z_.-][A-Za-z0-9_.-]*|root[A-Za-z0-9_.-]+)@([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}|(localhost[A-Za-z0-9.-]*[A-Za-z0-9]|[A-Za-z][A-Za-z0-9.-]{0,6}[A-Za-z0-9]|[A-Za-km-z][A-Za-z0-9.-]*[A-Za-z0-9]|l[A-Z0-9a-np-z.-][A-Za-z0-9.-]*[A-Za-z0-9]|lo[A-Z0-9a-bd-z.-][A-Za-z0-9.-]*[A-Za-z0-9]|loc[A-Z0-9b-z.-][A-Za-z0-9.-]*[A-Za-z0-9]|loca[A-Z0-9a-km-z.-][A-Za-z0-9.-]*[A-Za-z0-9]|local[A-Z0-9a-gi-z.-][A-Za-z0-9.-]*[A-Za-z0-9]|localh[A-Z0-9a-np-z.-][A-Za-z0-9.-]*[A-Za-z0-9]|localho[A-Z0-9a-rt-z.-][A-Za-z0-9.-]*[A-Za-z0-9]|localhos[A-Z0-9a-su-z.-][A-Za-z0-9.-]*[A-Za-z0-9])([^A-Za-z0-9.-]|$)|["'$][{]?[$]?[A-Za-z_{])	带用户名的远端目标（account + @ + host）：ssh/scp 的登录串与邮箱地址都在内；已排除 root 开头的登录名、以及 host 恰为 localhost 的目标
\b(10\.[0-9]{1,3}|192\.168|172\.(1[6-9]|2[0-9]|3[01]))(\.[0-9]{1,3}){2}\b	私网地址：暴露别人的网络拓扑（192.168.x.x / 10.x.x.x / 172.16-31.x.x）
RULES
# ---- account + @ + host 那条为什么长成这样（2026-10-10）----
# 改之前 --list 宣称「排除 root 开头 / host 是 localhost」，实现里【一点排除都没有】；
# 101fd08 先把宣称改对（--list 直接打 $RULES），这次把实现补上。要点四条：
#   1) 左边界 (^|[^A-Za-z0-9_.-]) 不是洁癖，是必需。没有它，正则会从 token 中间
#      起匹配：root@$HOST 里的 "oot@" 照样命中，于是「排除 root」是一句空话。
#      有了边界，token 才真的是【整个】token，才能判断它等不等于某个字面量。
#   2) POSIX ERE 没有负向断言也没有后行断言，写不出「不是 root」。唯一办法是按
#      【首个相异位】展开：比它短 / 第 1..4 位里有一位不同 / 比它长 —— 用户段 6 个分支。
#   3) 主机段同理展开 localhost（11 个分支），并用 ([^A-Za-z0-9.-]|$) 右边界逼它吃完
#      整个主机名。没有右边界的话 localhosty、localhost.example.com 会被一起误排除。
#      右边界只加在主机名这一支：IPv4 与 shell 变量（"x/$x）那两支原样不动。
#   4) 每个「字符类减一个字」都必须【真的减掉那一个字】。把 [A-Z0-9a-np-z.-] 写成
#      [A-Za-z0-9a-np-z.-] 会因为 a-z 又把 o 加回来 —— 排除静默失效， diff 看着只差
#      一个字符。所以每个这样的类都是机器逐字验过的，不要手改。
# 排除范围【只有】两处：登录名恰好 root、主机名恰好 localhost。二者都是本地自指
# 目标，指不出任何外部机器。rootpw / myroot / localhost.example.com 一律照拦。
# 规则块内【只能】放 <正则><TAB><说明>，一行一条，且正则与说明里都不能有 TAB —— 解析按第一个 TAB 切分。
# 私钥那条原来写成 ([A-Za-z0-9_.-]+)\.ssh/，而真实路径是 ~/.ssh/：波浪号不在字符类里，
# 于是这条【最该抓的】规则一条都匹配不到（2026-10-09 实测确认）。
)
if [ -f "$LOCAL_RULES" ]; then
  RULES="$RULES
$(grep -vE '^[[:space:]]*(#|$)' "$LOCAL_RULES")"
fi

# ---- 排除本脚本自身的规则文本行与说明注释 ----
# 规则里写着的正是它自己要匹配的正则，头部注释里也举着 `HOST="${PFAN_HOST:-192.168.1.10}"`
# 这个例子（它就是本门存在的那条理由）。不排除的话这个脚本永远过不了自己的门 ——
# 2026-10-09 的 .ssh/ 规则就是这样被 --list 散文里的 pfan_deploy_key 自曝的。
# 排除范围只有两处，且都只对【本文件】生效：
#   1. 规则块（heredoc 起止两行之间；起 = `RULES=$(cat`，止 = 下一个行首 `)`）
#   2. 本文件的注释行（行首空白之后是 #）
# 本文件的【代码行】不在排除范围内：那里真出现环境绑定照样报出来。
# ⚠ 规则文本里【不能】出现行首单独的 `)`，否则块范围会被截短。
SELF_BLOCK_START=$(grep -n '^RULES=\$(cat' "$SELF_FILE" | head -1 | cut -d: -f1)
SELF_BLOCK_END=$(awk -v s="${SELF_BLOCK_START:-0}" 'NR>s && /^\)$/ {print NR; exit}' "$SELF_FILE")

if [ "${1:-}" = "--list" ]; then
  echo "== 脱敏门规则：下面这份就是扫描时用的那份，逐条对应，无散文 =="
  # 每条规则编号输出：`  [N] <正则>` / `      └ <说明>`。编号不是为了好看，是为了让
  # "规则行"能被正则无歧义地数出来 —— 早先的缩进版 --list 里 `  共 N 条` 那行和规则
  # 行长得一模一样，任何按缩进计数的检查都会把它算成一条规则。
  _n=0
  printf '%s\n' "$RULES" | while IFS=$'\t' read -r re why; do
    [ -n "$re" ] || continue
    _n=$((_n + 1))
    printf '  [%d] %s\n      └ %s\n' "$_n" "$re" "$why"
  done
  echo "  共 $(printf '%s\n' "$RULES" | grep -c "$(printf '\t')") 条（含 scripts/sanitize.local 的追加项，若该文件存在）"
  exit 0
fi

# ---- 豁免：<正则>|<理由>，理由不能为空 ----
ALLOW_PATTERNS=()
if [ -f "$ALLOW" ]; then
  while IFS= read -r line; do
    case "$line" in ''|'#'*) continue ;; esac
    ALLOW_PATTERNS+=("$line")
  done < "$ALLOW"
fi

# ---- 只扫会被发布的文件 ----
FILES=$(git ls-files 2>/dev/null | grep -vE '^(LICENSE|NOTICE)$')
[ -n "$FILES" ] || { echo "[FAIL] git ls-files 为空（不是 git 仓库？）" >&2; exit 1; }

TMPF=$(mktemp "${TMPDIR:-/tmp}/pfansanitize.XXXXXX") || exit 1
trap 'rm -f "$TMPF"' EXIT
hits=0
report() { # report <file> <line> <说明> <命中文本>
  hits=$((hits + 1))
  printf '  %s:%s  [%s]\n      %s\n' "$1" "$2" "$3" "$4"
}

echo "=== 脱敏检查 ==="
# 用 %s\n 而不是 %s：后者把整块规则当成【一个参数】，下面的 while read 只会读到
# 第一行，剩下的规则连同其中的 | 一起塞进 $re，于是既数不对也匹配不到（实测）。
# 计数用 TAB 而不是 |：正则自身含 |（(id_x|pfan_deploy_key)），grep -c '|' 数出来的是
# 正则里的竖线，不是规则条数（实测数出 1，实际 3 条）。
echo "  规则 $(printf '%s\n' "$RULES" | grep -c "$(printf '\t')") 条；豁免 ${#ALLOW_PATTERNS[@]} 条"

while IFS=$'\t' read -r re why; do
  [ -n "$re" ] || continue
  case "$re" in '#'*) continue ;; esac
  # grep -n 的输出是 file:line:text；用 cut -d: -f1,2 拆出位置。
  # 不要用 while read 配 here-doc 展开 —— 命中多行时会被当成一行。
  # 也不要写 sed -n "${ln}p"：ln 里可能带 sed 无法解析的残字符。
  printf '%s\n' "$FILES" | xargs grep -nE "$re" 2>/dev/null \
    | cut -d: -f1,2 > "$TMPF" 2>/dev/null
  while IFS=: read -r f ln; do
    [ -n "$f" ] && [ -n "$ln" ] || continue
    if [ "$f" = "$SELF_FILE" ]; then
      # 规则块内的行必然命中自己 —— 整段跳过（范围见上）
      if [ -n "$SELF_BLOCK_START" ] && [ -n "$SELF_BLOCK_END" ] \
         && [ "$ln" -ge "$SELF_BLOCK_START" ] && [ "$ln" -le "$SELF_BLOCK_END" ]; then
        continue
      fi
      # 注释行里举的例子必然命中自己。判「行首空白之后是 #」而不是剥注释：
      # 剥注释会把命中原文也一起剥掉，正好把要找的那一行抹掉。
      case "$(awk -v n="$ln" 'NR==n {print; exit}' "$f" 2>/dev/null)" in
        \#*) continue ;;
      esac
    fi
    skipped=0
    for a in "${ALLOW_PATTERNS[@]}"; do
      [ -n "$a" ] || continue
      ar=${a%%$'\t'*}
      if printf '%s' "$f:$ln" | grep -qE "$ar" 2>/dev/null; then skipped=1; break; fi
    done
    [ "$skipped" = 1 ] && continue
    txt=$(awk -v n="$ln" 'NR==n {print; exit}' "$f" 2>/dev/null | cut -c1-90)
    report "$f" "$ln" "$why" "$txt"
  done < "$TMPF"
done <<EOF
${RULES}
EOF

echo
if [ "$hits" -gt 0 ]; then
  cat >&2 <<EOF
[FAIL] 发现 $hits 处环境绑定字符串 —— 公开前必须逐处处理。

  三条路，缺一不可：
    a) 改掉它（推荐：代码默认值改成环境变量必填、文档改成占位符）
    b) 写进 $ALLOW（已提交，逐条豁免），每行 "<正则><TAB><为什么可以留>"
    c) 确认它【不】敏感 —— 例如 PRIVATE LAN 网段本身不含信息，
       但作为默认值出现在公开代码里会让 fork 者困惑，仍建议改。

  送出去。自有主机名应当整体改成 <your-host> 之类的占位符。
EOF
  exit 1
fi
echo "  [ok] 未发现环境绑定字符串"