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
#   3. scripts/sanitize.allow —— 逐条豁免，格式
#      <文件正则><TAB><内容指纹>[,<内容指纹>…]<TAB><理由>（【已提交】）
#      指纹是那一行逐字节内容的 sha256 —— 豁免钉的是【哪一行】，不是【第几行】。
#      为什么不用行号：行号会被它上面的任何一次编辑挪动，于是每改一次文件就得
#      手动重锚一遍，而重锚是「悄悄把覆盖面放大」的最佳时机（本分支上因为三处
#      无关的编辑重锚过三次）。指纹不会：内容没变，指纹就没变。
#      为什么不用「把那一行的字面量抄进来当正则」：本文件自己也在扫描范围内，
#      抄字面量等于在本文件里复制一份暴露；而正则锚点一旦选得太短，同一文件里
#      新写的、含同一个片段的行会被顺带放过 —— 那正是行号方案本来免费提供、
#      换成内容方案最容易丢掉的性质。
#
# 第 2 条与第 3 条的分界就是「可复现性」：sanitize.local 是本机特有的禁止项，别人
# 看了学不到东西，所以不提交；sanitize.allow 是这个仓库【每一处豁免的理由】，删掉
# 它之后门对所有人恒红且无处可豁免（这正是 2026-10-10 之前的状态），所以它必须跟着
# 仓库走，并且对 fork 同样可用。
#
# 用法：
#   bash scripts/sanitize.sh            # 检查并列出违规（发现即非零退出）
#   bash scripts/sanitize.sh --list     # 只列出【实际编译】的规则，不扫描
#   bash scripts/sanitize.sh --allow-list  # 只列出豁免，并把每条解析到当前的文件:行号
#
# --list 为什么必须遍历 $RULES 而不是印一段散文：2026-10-10 实测，原来的 --list 印了
# 5 类规则，脚本实际只编译了 3 条（缺 <用户>@<主机> 与私网网段），而 `<deploy user>@` 就在本仓库
# 的可执行文件里躺着、一条都没被拦住。散文与实现可以各说各话，正是这个门存在的目的
# 要拦的那类失败（宣称能看见而实际上看不见）。现在 --list 直接打印 $RULES，宣称与实现
# 不可能不一致。
#
# --allow-list 存在的理由：行号锚定时，「这一条现在放行的是哪一行」要靠人去
# 逐条数行；换成内容指纹之后这个信息从清单里消失了，于是补一个只读视图把它算
# 回来（指纹 -> 当前文件:行号）。它不参与判定，只是审计用的第二双眼睛：
# 判定逻辑只有下面 _covering_entries 那一个函数（主扫描里的 _exempt_by 只是它的调用方）。
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

LOCAL_RULES="scripts/sanitize.local"
ALLOW="scripts/sanitize.allow"
SELF_FILE="scripts/sanitize.sh"

# ---- 收集规则：<正则><TAB><说明>，逐行 ----
RULES=$(cat <<'RULES'
\.ssh/(id_[A-Za-z0-9]+|[^ /]*\.pem)	私钥路径：公开仓库里不该出现具体密钥文件名
/Users/[A-Za-z0-9_.-]+/	macOS 用户目录：泄露本机用户名
(^|[^A-Za-z0-9_.-])[A-Za-z0-9_.-]+@([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}|(localhost[A-Za-z0-9.-]*[A-Za-z0-9]|[A-Za-z][A-Za-z0-9.-]{0,6}[A-Za-z0-9]|[A-Za-km-z][A-Za-z0-9.-]*[A-Za-z0-9]|l[A-Z0-9a-np-z.-][A-Za-z0-9.-]*[A-Za-z0-9]|lo[A-Z0-9a-bd-z.-][A-Za-z0-9.-]*[A-Za-z0-9]|loc[A-Z0-9b-z.-][A-Za-z0-9.-]*[A-Za-z0-9]|loca[A-Z0-9a-km-z.-][A-Za-z0-9.-]*[A-Za-z0-9]|local[A-Z0-9a-gi-z.-][A-Za-z0-9.-]*[A-Za-z0-9]|localh[A-Z0-9a-np-z.-][A-Za-z0-9.-]*[A-Za-z0-9]|localho[A-Z0-9a-rt-z.-][A-Za-z0-9.-]*[A-Za-z0-9]|localhos[A-Z0-9a-su-z.-][A-Za-z0-9.-]*[A-Za-z0-9])([^A-Za-z0-9.-]|$)|["'$][{]?[$]?[A-Za-z_{])	带用户名的远端目标（account + @ + host）：ssh/scp 的登录串与邮箱地址都在内；仅 host 恰为 localhost 的目标被排除
\b(10\.[0-9]{1,3}|192\.168|172\.(1[6-9]|2[0-9]|3[01]))(\.[0-9]{1,3}){2}\b	私网地址：暴露别人的网络拓扑（192.168.x.x / 10.x.x.x / 172.16-31.x.x）
RULES
# ---- account + @ + host 那条为什么长成这样（2026-10-10 补实现，2026-10-15 收窄）----
# 沿革三句：改之前 --list 宣称「排除 root 开头 / host 是 localhost」而实现里一点排除都
# 没有；101fd08 先把宣称改对（--list 直接打 $RULES）；e02a3f2 那次把实现补上，两侧都
# 排除；2026-10-15 把登录名那一侧的排除撤掉 —— 第 5 条写为什么撤。要点五条：
#   1) 左边界 (^|[^A-Za-z0-9_.-]) 不是洁癖，是必需。没有它，正则会从 token 中间起匹配：
#      xlocalhost 里 localhost 这个后缀照样命中，于是「host 恰为 localhost」成了空话
#      （整个 token 被当成本机自指放过）。有了边界，token 才真的是【整个】token。
#   2) 排除只发生在主机一侧，而 POSIX ERE 没有负向断言也写不出「不是 localhost」。唯一
#      办法是按【首个相异位】展开：比它短 / 第 1..8 位里有一位不同 / 更长（正是它）——
#      主机段 11 个分支。
#   3) 主机段用 ([^A-Za-z0-9.-]|$) 右边界逼它吃完整个主机名。没有右边界的话
#      localhosty、localhost.example.com 会被一起误排除。右边界只加在主机名这一支：
#      IPv4 与 shell 变量（"x/$x）那两支原样不动。
#   4) 每个「字符类减一个字」都必须【真的减掉那一个字】。把 [A-Z0-9a-np-z.-] 写成
#      [A-Za-z0-9a-np-z.-] 会因为 a-z 又把 o 加回来 —— 排除静默失效， diff 看着只差
#      一个字符。所以每个这样的类都是机器逐字验过的，不要手改。
#   5) 登录名一侧【零排除】，这是 2026-10-15 的状态。中间版本两侧都排除，理由写的是
#      「二者都是本地自指目标，指不出任何外部机器」—— 那句话是假的：登录名是自由文本，
#      可以和上面任何一支主机配对，root@203.0.113.9 实测一行都不报（2026-10-15 复核），
#      而那恰好是这道门最该拦的形态。两侧根本不对称：主机侧被排除的字面量只有一个，
#      语义上不可能指向外部机器；登录名那一侧的排除则是无界的。同一个 carve-out 机制，
#      一头有界一头无界，所以只留有界那头。
# 剩下来的排除范围【只有】一处：主机名恰好 localhost。这是一条刻意的策略选择，不是
# 「它不敏感」的推论 —— 删掉它，deploy@localhost 这类默认值会被报出来，而它泄露的是
# 一个必然指向回环地址的字面量。tests/shell/test_repo_hygiene.sh 的 25d 双向钉住它：
# host 为 localhost 的不报，登录名为 root 的（连同 rootpw / myroot / roots）一律照报，
# 把登录名那一侧的排除加回去，测试立刻转红。
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
# 2026-10-09 的 .ssh/ 规则就是这样被 --list 散文里的具体密钥文件名自曝的。
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

# ---- 豁免：<文件正则><TAB><指纹>[,<指纹>…]<TAB><理由>，三段都不能为空 ----
# 字段 1 是对【路径】的正则（照旧用 ^…$ 锚死，别写 ^docs/.*$ 这种），字段 2 是那一行
# 逐字节内容的 sha256（逗号分隔，一条豁免可以钉住同一文件里的多处出现），字段 3 是
# 理由。解析按 TAB 切三段 —— 理由里也不能有 TAB。
ALLOW_PATTERNS=()
if [ -f "$ALLOW" ]; then
  # `|| [ -n "$line" ]`：文件末尾少一个换行时 read 会返回非零，于是最后一条豁免被
  # 悄悄丢掉 —— 表现为「凭空多出几处命中」，而不是「清单少了一条」，很难查。
  # （2026-10-16 实测踩到：写完新格式的清单忘了收尾换行，最后一条没进数组。）
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    ALLOW_PATTERNS+=("$line")
  done < "$ALLOW"
fi

# ---- 内容指纹：stdin 的 sha256，印 64 位十六进制 ----
# 为什么必须是 sha256 而不是 cksum：指纹要在【第二个实现】里算出同一个值 ——
# tests/shell/test_repo_hygiene.sh 的 T25 自己算一遍，两边对不上就报红。cksum 只有
# 32 位 CRC 且各家实现细节不一，拿它当锚等于把「两边一致」押在运气上。
# 三个候选按可用性取第一个，并且【当场验一次输出是不是 64 位十六进制】：工具在但
# 用法不对（例如 BusyBox 的 shasum 参数不同）时，验不过就换下一个，而不是拿一段
# 垃圾去和清单比对（那样每条豁免都匹配不上，门恒红，人会以为清单写错了）。
# 一个都没有时【退出 1】：指纹算不出来的时候放行，等于把整份清单变成空门。
SHA_TOOL=""
_sha256_pick() {
  local c d
  for c in "sha256sum" "shasum -a 256" "openssl dgst -sha256"; do
    # shellcheck disable=SC2086
    d=$($c </dev/null 2>/dev/null | tr -d '\n' | sed 's/.*[^0-9a-fA-F]//')
    case "$d" in
      ""|*[!0-9a-fA-F]*) continue ;;
    esac
    [ "${#d}" -eq 64 ] || continue
    SHA_TOOL="$c"
    return 0
  done
  echo "  [FAIL] 找不到可用的 sha256（sha256sum / shasum -a 256 / openssl dgst 都试过了）" >&2
  echo "         内容锚定的豁免在这里无法判定，门【退出】而不是放行：指纹算不出来时" >&2
  echo "         「一条都豁免不掉」与「全部放行」只有一步之差，必须往红的一边倒。" >&2
  exit 1
}
_sha256() { # stdin -> 64 位十六进制（去掉工具各自的输出包装）
  # shellcheck disable=SC2086
  $SHA_TOOL | tr -d '\n' | sed 's/.*[^0-9a-fA-F]//'
}
[ "${#ALLOW_PATTERNS[@]}" -gt 0 ] && _sha256_pick

# ---- 判定：这一处命中（<文件> <行号>）是否被某条豁免盖住 ----
# 三条同时成立才算豁免，缺一条就照报：
#   1. 路径正则命中该文件（字段 1）
#   2. 那一行内容的指纹在字段 2 的列表里（字段 2，整条相等，不是子串）
#   3. 同一份内容在该文件里【只出现一次】—— 见下面 _dup 的解释
# 这个判据【只有这一份实现】。主扫描（_exempt_by）、--allow-list 的归因视图
# （_covering_entry）与它的反向统计都只是这里的调用方 —— 谓词复制成三份时，
# 任何一处先过期，「清单说豁免了」与「门真的豁免了」就会各说各话，而那正是
# 这道门存在的意义要拦的那类失败。
# 输出：盖住这一处的豁免条目序号（每行一个；条目对照 --allow-list 里的 [N]）。
# 无输出且返回 1 = 不放行；重复内容命中指纹时报 [WARN]（stderr）后同样不放行。
_covering_entries() { # _covering_entries <文件> <行号> <该行全文>
  local f=$1 ln=$2 txt=$3
  [ -n "$txt" ] || return 1   # 空行不可能是命中；真为空说明上游出了意外，不放行
  [ -n "$SHA_TOOL" ] || return 1  # 清单不在（没有东西要豁免）：不匹配，也不放行
  local h a k=0 af rest hashes one _hl hit=""
  h=$(_sha256 <<<"$txt")
  for a in "${ALLOW_PATTERNS[@]}"; do
    k=$((k + 1))
    af=${a%%$'\t'*}
    # [[ =~ ]] 是 bash 内建：对这里这种锚死的简单路径正则与 grep -qE 逐字节等价，
    # 但不起子进程。此前每条豁免都要 fork 一个 grep，占了门的大半墙钟
    # （实测 11.6s -> 2.7s；R-14 的账在 ledger 里）。
    [[ "$f" =~ $af ]] || continue
    rest=${a#*$'\t'}
    hashes=${rest%%$'\t'*}
    IFS=',' read -ra _hl <<<"$hashes"
    for one in "${_hl[@]}"; do
      [ "$one" = "$h" ] || continue
      hit="$hit $k"
      break
    done
  done
  [ -n "$hit" ] || return 1   # 没有任何条目同时命中路径与指纹：照报
  # ⚠ 同一份内容在同一个文件里出现两次以上时【不放行】。指纹钉的是「这一行」，
  #   而「这一行」是有位置的：有人把同一行复制到同文件别处，那一处是新出现
  #   的暴露，必须由人裁决，不能因为内容一样就顺带放行。现状是 0 例（豁免清单
  #   覆盖的每一行在其文件内都唯一），这条只是把「顺带放过」这条路堵死。
  #   判失败方向是红的：重复出现时门会报红，需要人来看一眼。
  #   grep -c 匹配数为 0 时退出码是 1，别写成 `|| echo 0` —— 那会在已经有 0 的
  #   输出后面再追加一行 0（与 ci.sh 里记过的那次同款陷阱）。
  _dup=$(grep -cFx -e "$txt" -- "$f" 2>/dev/null) || _dup=0
  if [ "${_dup:-0}" != 1 ]; then
    printf '  [WARN] %s:%s 同一份内容在本文件出现 %s 次 —— 豁免按内容锚定，拒绝放行，请人工裁决这份重复\n' \
      "$f" "$ln" "${_dup:-?}" >&2
    return 1
  fi
  for k in $hit; do printf '%s\n' "$k"; done
  return 0
}

# 主扫描的判定入口：语义就是 _covering_entries 无命中即红（WARN 由它照常打到
# stderr）。保留这个名字是因为主扫描、sanitize.allow 与测试的注释都用它指代
# 「那道判定」——它现在只是上面那份唯一实现的调用方，自己不再含任何谓词。
_exempt_by() { # _exempt_by <文件> <行号> <该行全文>；命中则返回 0
  _covering_entries "$1" "$2" "$3" >/dev/null
}

# ---- 只扫会被发布的文件 ----
FILES=$(git ls-files 2>/dev/null | grep -vE '^(LICENSE|NOTICE)$')
[ -n "$FILES" ] || { echo "[FAIL] git ls-files 为空（不是 git 仓库？）" >&2; exit 1; }

TMPF=$(mktemp "${TMPDIR:-/tmp}/pfansanitize.XXXXXX") || exit 1
HITSF=$(mktemp "${TMPDIR:-/tmp}/pfansanitize.hits.XXXXXX") || exit 1
trap 'rm -f "$TMPF" "$HITSF"' EXIT

# ---- 枚举【原始】命中（还没套豁免）：<文件><TAB><行号><TAB><规则说明><TAB><整行原文> ----
# 主路径与 --allow-list 共用这一个枚举：豁免的判定只有 _covering_entries 一处，两边各扫一遍
# 的话早晚有一边先过期，而「清单说豁免了」与「门真的豁免了」对不上，正是这道门
# 存在的意义要拦的那类失败。
# ⚠ 结果落文件、由 `while read ... done < "$HITSF"` 读回，【不】用管道喂 while：
#   管道里的 while 跑在子 shell 里，hits=$((hits+1)) 就累加在子 shell 上丢了，
#   末尾的 [ "$hits" -gt 0 ] 于是恒假 —— 门永远报 ok，fail-open 到看不出来。
_raw_hits() {
  local re why f ln
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
      printf '%s\t%s\t%s\t%s\n' "$f" "$ln" "$why" \
        "$(awk -v n="$ln" 'NR==n {print; exit}' "$f" 2>/dev/null)"
    done < "$TMPF"
  done <<EOF
${RULES}
EOF
}

if [ "${1:-}" = "--allow-list" ]; then
  echo "== 脱敏门豁免：下面这份就是判定时用的那份，逐条对应，无散文 =="
  # 同一行被两条规则命中时 _raw_hits 会印两遍（每条规则一遍）。反向视图按
  # 文件:行号去重之后再统计，否则「被几条豁免盖住」会把规则条数算成豁免条数。
  _raw_hits | awk -F'\t' '!seen[$1 SUBSEP $2]++' > "$HITSF"
  # 归因：这一处命中是被哪一条盖住的。判定本身仍然只认 _covering_entries（那三条），
  # 这里只取它输出的第一条（多条同时盖住时，死重量由下面反向视图报）。
  _covering_entry() { # _covering_entry <文件> <该行全文> -> 印条目序号，无则不印
    local _all
    _all=$(_covering_entries "$1" "" "$2" 2>/dev/null) || return 1
    [ -n "$_all" ] || return 1
    printf '%s' "${_all%%$'\n'*}"
  }
  # 先把「条目 -> 当前放行的 file:line」攒出来（bash 3 没有关联数组，用一张
  # "条目号:文件:行号" 的文本表）。
  _declare_at=""
  while IFS=$'\t' read -r _f _ln _rw _txt; do
    [ -n "$_f" ] && [ -n "$_ln" ] || continue
    _k=$(_covering_entry "$_f" "$_txt") || _k=""
    _declare_at="$_declare_at$_k:$_f:$_ln
"
  done < "$HITSF"
  _i=0
  for a in "${ALLOW_PATTERNS[@]}"; do
    _i=$((_i + 1))
    _af=${a%%$'\t'*}; _rest=${a#*$'\t'}; _hashes=${_rest%%$'\t'*}; _why=${_rest#*$'\t'}
    _at=""
    printf '%s' "$_declare_at" | while IFS=: read -r _k _f _ln; do
      [ "$_k" = "$_i" ] && printf ' %s:%s' "$_f" "$_ln"
    done > "$TMPF"
    _at=$(cat "$TMPF")
    if [ -z "$_at" ]; then
      printf '  [%d] %s\n      指纹 %s\n      └ 当前放行 0 处 —— 指纹对不上当前树（内容变了 / 行被删 / 该内容在文件里重复出现 / 规则不再命中）：这条现在什么也不豁免\n      └ %s\n' \
        "$_i" "$_af" "$_hashes" "$_why"
    else
      printf '  [%d] %s\n      指纹 %s\n      └ 当前放行%s\n      └ %s\n' \
        "$_i" "$_af" "$_hashes" "$_at" "$_why"
    fi
  done
  # 反向视图：原始命中里哪些没被任何豁免盖住（门会报红的）、哪些被多条同时盖住
  # （纪律 3 说那是死重量）。两段都不是判定，只是把"清单与门对不对得上"摆出来。
  # ⚠ 这里的"被几条盖住"就是数 _covering_entries 的输出行数 —— 与门同一份实现，
  #   视图不可能与门对不上：指纹对得上但内容重复时，它和门一样拒绝放行（无输出）。
  _n_raw=0; _n_exempt=0; _n_bare=""; _n_over=""
  while IFS=$'\t' read -r _f _ln _rw _txt; do
    [ -n "$_f" ] && [ -n "$_ln" ] || continue
    _n_raw=$((_n_raw + 1))
    _c=0
    while IFS= read -r _one; do
      [ -n "$_one" ] && _c=$((_c + 1))
    done < <(_covering_entries "$_f" "$_ln" "$_txt" 2>/dev/null)
    if [ "$_c" -gt 0 ]; then _n_exempt=$((_n_exempt + 1)); fi
    [ "$_c" -eq 0 ] && _n_bare="$_n_bare ${_f}:${_ln}"
    [ "$_c" -gt 1 ] && _n_over="$_n_over ${_f}:${_ln}"
  done < "$HITSF"
  echo "  共 ${#ALLOW_PATTERNS[@]} 条；原始命中 $_n_raw 处，被豁免 $_n_exempt 处"
  [ -n "$_n_bare" ] && printf '  [WARN] 这些命中没有任何豁免盖住（门会报红）：%s\n' "$_n_bare"
  [ -n "$_n_over" ] && printf '  [WARN] 这些命中被多条豁免同时盖住（后面几条是死重量）：%s\n' "$_n_over"
  exit 0
fi

hits=0
report() { # report <file> <line> <说明> <命中文本>
  hits=$((hits + 1))
  printf '  %s:%s  [%s]\n      %s\n' "$1" "$2" "$3" "$4"
}

echo "=== 脱敏检查 ==="
# 用 %s\n 而不是 %s：后者把整块规则当成【一个参数】，下面的 while read 只会读到
# 第一行，剩下的规则连同其中的 | 一起塞进 $re，于是既数不对也匹配不到（实测）。
# 计数用 TAB 而不是 |：正则自身含 |（id_ 与 .pem 两支），grep -c '|' 数出来的是
# 正则里的竖线，不是规则条数（实测数出 1，实际 3 条）。
echo "  规则 $(printf '%s\n' "$RULES" | grep -c "$(printf '\t')") 条；豁免 ${#ALLOW_PATTERNS[@]} 条"

_raw_hits > "$HITSF"
while IFS=$'\t' read -r f ln why txt; do
  [ -n "$f" ] && [ -n "$ln" ] || continue
  _exempt_by "$f" "$ln" "$txt" && continue
  report "$f" "$ln" "$why" "$(printf '%s' "$txt" | cut -c1-90)"
done < "$HITSF"

echo
if [ "$hits" -gt 0 ]; then
  cat >&2 <<EOF
[FAIL] 发现 $hits 处环境绑定字符串 —— 公开前必须逐处处理。

  三条路，缺一不可：
    a) 改掉它（推荐：代码默认值改成环境变量必填、文档改成占位符）
    b) 写进 $ALLOW（已提交，逐条豁免），每行三段 TAB 分隔：
       "<文件正则><TAB><那一行内容的 sha256 指纹><TAB><为什么可以留>"
       指纹按本脚本报出的 file:line 去取那一行的 sha256（下面这条命令，<文件> 与
       <行号> 换成实际值）：
         awk 'NR==<行号>' <文件> | sha256sum
       反过来看：bash scripts/sanitize.sh --allow-list 会把每条豁免当前放行的
       文件:行号逐条印出来
    c) 确认它【不】敏感 —— 例如 PRIVATE LAN 网段本身不含信息，
       但作为默认值出现在公开代码里会让 fork 者困惑，仍建议改。

  特别提醒：自有域名是【活跃的公网入口】，公开仓库里等于把服务地址
  送出去。自有主机名应当整体改成 <your-host> 之类的占位符。
EOF
  exit 1
fi
echo "  [ok] 未发现环境绑定字符串"