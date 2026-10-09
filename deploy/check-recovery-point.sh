#!/bin/sh
# 核对恢复点真的覆盖了 deploy.sh 第 3 步要覆盖的每一个路径。
#
# 为什么需要它（专家审计 I-1，实测确认）：deploy.sh 的备份循环里每条 cp 都跟 `|| true`，
# 磁盘满 / ACL 拒绝 / 读错误全被吞掉，部署照常覆盖 7 个二进制 + 面板 + logrotate +
# platform.sh 并在末尾打印「回滚点: <path>」—— 看着有回滚点，实际可能缺一大半。
# 实测真的发生过：面板目录是 drwx------ root:root，非 sudo 的 [ -e ] 一律 false，
# 7 个面板文件被静默跳过，而没有任何一行输出提示。
#
# 判据：文件【本来就存在于机器上】、但恢复点里没有 -> 备份失败。
# 两条命令分开跑是为了让调用方能分别拿到「应备的」与「真备到的」计数，
# 只数差值会在文件本来就不存在时误报（首台机器上面板可能还没装）。
#
# ⚠ 必须以能读 /opt/beszel/beszel_data 的身份运行（root 或带 sudo -n）——
#   否则它会因为读不到面板目录而「通过」，正是本脚本要防的那类假通过。
#
# 用法：sudo -n sh deploy/check-recovery-point.sh <恢复点目录>
# 输出：第一行是缺的文件列表（可能为空），第二行是 "EXPECTED N" / "PRESENT M"
set -u
B="${1:?用法: check-recovery-point.sh <恢复点目录>}"

PATHS="/etc/logrotate.d/pfan
/usr/local/lib/pfan/platform.sh
/etc/pfan/fan-candidates.txt
/opt/beszel/beszel_data/index.html
/opt/beszel/beszel_data/styles.css
/opt/beszel/beszel_data/app.js
/opt/beszel/beszel_data/core.js
/opt/beszel/beszel_data/vendor/uPlot.esm.js
/opt/beszel/beszel_data/vendor/uPlot.min.css
/opt/beszel/beszel_data/vendor/uPlot.LICENSE"

expected=0
present=0
miss=""
# ⚠ 每条 [ -e ] 都必须带 sudo：面板目录 /opt/beszel/beszel_data 是 drwx------ root:root，
# 非 sudo 的 test 一律 false，于是 7 个面板文件既不算 expected 也不算 present ——
# 检查会「通过」而实际上一个面板文件都没备份。deploy.sh 里同一个坑也踩过一次
# （那次的 [ -e ] 在备份循环里，被 || true 吞掉了）。
if [ "$(id -u)" = 0 ]; then SUDO=""; else SUDO="sudo -n"; fi
for f in $PATHS; do
    $SUDO test -e "$f" || continue           # 机器上本来就没有 -> 不该备份
    expected=$((expected + 1))
    if $SUDO test -e "$B$f"; then
        present=$((present + 1))
    else
        miss="$miss $f"
    fi
done

for f in $miss; do echo "MISS $f"; done
echo "EXPECTED $expected"
echo "PRESENT $present"