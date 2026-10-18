#!/bin/sh
# deploy/check-recovery-point.sh — 核对恢复点真的覆盖了 deploy.sh 第 3 步会覆盖的
# 每一个已有文件（18 个路径：5 个二进制 + 13 个按完整路径备份的文件）。
#
# 为什么需要它（专家审计 I-1，实测确认）：deploy.sh 的备份循环里每条 cp 都跟 `|| true`，
# 磁盘满 / ACL 拒绝 / 读错误全被吞掉，部署照常覆盖二进制 + 面板 + logrotate +
# platform.sh + 预设并在末尾打印「回滚点: <path>」—— 看着有回滚点，实际可能缺一大半。
# 实测真的发生过：面板目录是 drwx------ root:root，非 sudo 的 [ -e ] 一律 false，
# 7 个面板文件被静默跳过，而没有任何一行输出提示。
#
# 核对范围（2026-10-18 由 10 个扩到 17 个、再随 R-10 补 example 副本到 18 个；
# 此前二进制与曲线预设从未被核对过，而 deploy 照样打印「已确认落地 10/10 个关键路径」）：
#   · 5 个二进制      /usr/local/bin/{pfand,pfan,pfanel.py,pfan_platform.py,pfan_core.py}
#   · logrotate 规则  /etc/logrotate.d/pfan
#   · 平台加载器      /usr/local/lib/pfan/platform.sh
#   · example 副本    /usr/local/lib/pfan/platform.conf.example（core/pfan detect 的兜底源）
#   · 候选表          /etc/pfan/fan-candidates.txt
#   · 面板 7 文件     <面板目录>/{index.html,styles.css,app.js,core.js,vendor/uPlot.*}
#   · 2 个曲线预设    /opt/pfanctl/presets/pfan.conf.{cool-quiet,performance}
# 刻意【不在】核对范围的（都不是「覆盖已有文件」——没有可回滚的对象）：
#   · /etc/pfan/platform.conf —— 只在缺失时由 example 建立，部署不覆盖、也不备份；
#   · <面板目录>/pfan.html   —— 旧版遗留的单文件面板，deploy 不再安装它；机器上若还
#     留着，备份循环会顺手拷进 $B/（所以恢复点里可能多出这一份），但缺它不算缺。
# 清单不许手抄：deploy.sh 第 3 步的 install 目标、第 1 步的备份清单与本表三方
# 由 tests/shell/test_repo_hygiene.sh T16b 逐条对钉，任何一侧漂移都会转红。
#
# 判据：文件【本来就存在于机器上】、但恢复点里没有 -> 备份失败。
# 两条命令分开跑是为了让调用方能分别拿到「应备的」与「真备到的」计数，
# 只数差值会在文件本来就不存在时误报（首台机器上面板可能还没装）。
# 布局逐路径不同（deploy.sh 分两批备份，本表用 flat/parents 标注）：
#   flat    用 `cp -a "$f" '$B/'`            -> 恢复点里是 $B/<basename>
#   parents 用 `cp -a --parents "$f" '$B/'`  -> 恢复点里是 $B<完整路径>
# 布局标错不会静默：核对会找不到文件、PRESENT<EXPECTED，部署当场中止。
#
# ⚠ 必须以能读面板目录的身份运行（root 或带 sudo -n）——
#   否则它会因为读不到面板目录而「通过」，正是本脚本要防的那类假通过。
#
# 用法：
#   sudo -n sh deploy/check-recovery-point.sh <恢复点目录> [面板目录]
#   sh deploy/check-recovery-point.sh --list [面板目录]   # 只打印核对范围，不碰文件系统
# 输出（核对模式）：每个缺失项一行 "MISS <路径>"，然后 "EXPECTED N"、"PRESENT M"。
# 这三行是 deploy.sh 的解析契约（按 "EXPECTED "/"PRESENT " 前缀读取、按 "^MISS " 报缺），
# 由 test_repo_hygiene T16b 钉住，不要改格式。
set -u
PANEL_DEFAULT=/opt/beszel/beszel_data

# ---- 唯一事实源：核对哪些路径、各自在恢复点里是什么布局 ----
# 用引号包裹定界符：$PANEL 保持字面量，由 expand() 在运行时替换。
check_list(){ cat <<'LIST'
flat /usr/local/bin/pfand
flat /usr/local/bin/pfan
flat /usr/local/bin/pfanel.py
flat /usr/local/bin/pfan_platform.py
flat /usr/local/bin/pfan_core.py
parents /etc/logrotate.d/pfan
parents /usr/local/lib/pfan/platform.sh
parents /usr/local/lib/pfan/platform.conf.example
parents /etc/pfan/fan-candidates.txt
parents $PANEL/index.html
parents $PANEL/styles.css
parents $PANEL/app.js
parents $PANEL/core.js
parents $PANEL/vendor/uPlot.esm.js
parents $PANEL/vendor/uPlot.min.css
parents $PANEL/vendor/uPlot.LICENSE
parents /opt/pfanctl/presets/pfan.conf.cool-quiet
parents /opt/pfanctl/presets/pfan.conf.performance
LIST
}

# 把 $PANEL 占位符替换成真实面板目录。只有以 $PANEL/ 开头的条目会被替换。
expand(){ case "$1" in
    *'$PANEL'/*) printf '%s/%s\n' "$PANEL" "${1#*'$PANEL'/}" ;;
    *)           printf '%s\n' "$1" ;;
  esac; }

if [ "${1:-}" = --list ]; then
    PANEL="${2:-$PANEL_DEFAULT}"
    while read -r layout p; do
        printf '%s %s\n' "$layout" "$(expand "$p")"
    done <<EOF
$(check_list)
EOF
    exit 0
fi

B="${1:?用法: check-recovery-point.sh <恢复点目录> [面板目录]}"
# 面板目录作为第二个参数传入，不再硬编码 —— deploy.sh 从 platform.conf 派生它，
# 这里若另写一份就会与 deploy/smoke/pfanel 三处不一致（audit m-7）。
PANEL="${2:-$PANEL_DEFAULT}"

expected=0
present=0
miss=""
# ⚠ 每条 test 都必须带 sudo：面板目录 $PANEL 是 drwx------ root:root，
# 非 sudo 的 test 一律 false，于是 7 个面板文件既不算 expected 也不算 present ——
# 检查会「通过」而实际上一个面板文件都没备份。deploy.sh 里同一个坑也踩过一次
# （那次的 [ -e ] 在备份循环里，被 || true 吞掉了）。
if [ "$(id -u)" = 0 ]; then SUDO=""; else SUDO="sudo -n"; fi
while read -r layout p; do
    f=$(expand "$p")
    $SUDO test -e "$f" || continue           # 机器上本来就没有 -> 不该备份
    expected=$((expected + 1))
    case "$layout" in
      flat)    b="$B/$(basename "$f")" ;;
      parents) b="$B$f" ;;
      *)       echo "内部错误: 未知布局 '$layout'（check_list 被改坏了？）" >&2; exit 2 ;;
    esac
    if $SUDO test -e "$b"; then
        present=$((present + 1))
    else
        miss="$miss $f"
    fi
done <<EOF
$(check_list)
EOF

for f in $miss; do echo "MISS $f"; done
echo "EXPECTED $expected"
echo "PRESENT $present"
