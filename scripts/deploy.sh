#!/usr/bin/env bash
# scripts/deploy.sh — 把仓库版本部署到目标机并验证。
# 顺序纪律：先 ci → 再备份 → 再装文件 → 【最后】才重启服务。
# 特别注意：/etc/pfan/platform.conf 是机器自己的配置，只在【不存在】时用 example 填充，
#           绝不覆盖已有文件（用户可能跑过 pfan detect 得到不同路径）。
set -euo pipefail
trap 'echo "[FAIL] deploy 中止于第 $LINENO 行" >&2' ERR
cd "$(dirname "$0")/.."

HOST="${PFAN_HOST:-192.168.1.10}"
# 就绪检查用的 API 根：默认直连 LAN 的 $HOST:8789；目标机只能经隧道/公网到达时，
# 用 PFAN_API_BASE 覆盖（例：https://pfan.example.com）。两者都不可达时该步会失败，
# 这比"悄悄跳过就绪检查"安全 —— 服务没起来就不该继续。
# 两个变量名并存的坑：smoke.sh 读 PFAN_API，deploy.sh 读 PFAN_API_BASE。
# 传错一个不会报错，只是那个变量静默取默认值 —— 2026-10-09 因为这个，
# 4b 步一直拿默认的 http://<host>:8789 去 curl 而误判「控制回路未接管」。
# 现在两个都认，以 PFAN_API 为准。
API_BASE="${PFAN_API:-${PFAN_API_BASE:-http://$HOST:8789}}"
KEY="$HOME/.ssh/pfan_deploy_key"
SSHOPT=(-i "$KEY" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=15)
# 目标机只能经 Cloudflare SSH 隧道到达时，cloudflared access 会出现 banner 超时抖动
# （实测同一分钟内单条探测也可能超时）。一次抖动不该让整次部署失败，也不能靠"重跑
# 整个 deploy"——那会在传输中途反复重来。所以给每条 ssh/scp 加有界重试。
SSH_RETRY="${PFAN_SSH_RETRY:-4}"
_retry(){ # _retry <描述> <命令...>
  local what="$1"; shift
  local n=1
  while :; do
    if "$@" >/dev/null 2>&1; then return 0; fi
    # 需要输出的调用（scp/带 tee 的）单独处理：这里只用于探测连通性
    if [ "$n" -ge "$SSH_RETRY" ]; then
      echo "[FAIL] $what 连续 $n 次失败（最后一条在下方）" >&2
      return 1
    fi
    echo "  …$what 第 $n 次失败，重试（隧道抖动？）" >&2
    n=$((n+1)); sleep $((n*3))
  done
}
# R/S：每次调用先探一次连通性，隧道抖动就重试（有界）。探活用 -o ConnectTimeout=8。
R(){ _retry "ssh $HOST" ssh "${SSHOPT[@]}" -o ConnectTimeout=8 pfan@"$HOST" true \
      && ssh "${SSHOPT[@]}" pfan@"$HOST" "$@"; }
# 传输走 tar-over-ssh 而不是 scp：实测本机 scp 对该目标静默失败（连续 4 次、无输出、
# rc≠0），而 tar|ssh 一次连接传全部文件更快也更稳。目标机只需有 tar（Ubuntu 默认有）。
# 用法：S <本地相对路径...> —— 打进 $STAGE/ 的【扁平】文件名（tar 里剥掉目录前缀），
# 因为安装段按 $STAGE/<name> 取。用一次连接传完，比逐个 scp 更快也更抗抖动。
S(){ _retry "tar|ssh $HOST" ssh "${SSHOPT[@]}" pfan@"$HOST" true \
      && { local t; t=$(mktemp -d "${TMPDIR:-/tmp}/pfansend.XXXXXX") || return 1
           # 必须显式改名落盘：cp "src" "$t/" 遇到同名会【拒绝覆盖】（实测
           # "will not overwrite just-created"），于是 core/pfan 与
           # deploy/logrotate.d/pfan 只能进去一个，另一个静默丢失。
           local f; for f in "$@"; do
             case "$f" in
               # deploy/logrotate.d/pfan 保留子目录（靠它与 core/pfan 区分），
                # 其它一律扁平到 $STAGE/<basename>，因为安装段按 $STAGE/<name> 取
                # ⚠ 目录必须由【文件名】推出来，不能写死 deploy/logrotate.d：
                # 写死时 S deploy/check-recovery-point.sh 会 cp 失败（目标目录不存在），
                # 而 deploy/ 下现在不止 logrotate 一个文件。教训同 C3：暂存区布局一旦写死，
                # 新增文件就会静默丢失。
                deploy/*) mkdir -p "$t/$(dirname "$f")"
                          cp "$f" "$t/$f" || { rm -rf "$t"; return 1; } ;;
               *)      cp "$f" "$t/$(basename "$f")" || { rm -rf "$t"; return 1; } ;;
             esac
           done
             # set -o pipefail：tar 管道【必须】两端都成功。此前 tar 流被截断时
             # 退出码仍是 0（ssh 侧成功），于是一个空的 deploy/ 目录被当成传输成功，
             # 直到 install 报 "cannot stat" 才暴露，而且看不出是哪一步丢的。
             local rc=0
             set -o pipefail 2>/dev/null || true
             tar -cf - -C "$t" . | ssh "${SSHOPT[@]}" pfan@"$HOST" "mkdir -p '$STAGE' && tar -xf - -C '$STAGE'" || rc=$?
             set +o pipefail 2>/dev/null || true
             rm -rf "$t"; return $rc; }; }
TS=$(date +%Y%m%d-%H%M%S)
B="/root/backups/pfan-deploy-$TS"
STAGE="/tmp/pfan-deploy-$$"

# 面板部署目录从【平台配置】派生，而不是在本文件里再硬编码一次。
# 理由：pfanel.py 已经从 platform.conf 读 PANEL_DIR，本脚本与 smoke.sh 也必须读同一个
# 值 —— 三处各自硬编码正是"改了一处、另两处静默指错目录"的来源（audit m-7 的核心问题）。
# 覆盖顺序：环境变量 > 仓库的 platform.conf.example（目标机上同一份由 deploy 安装，
# pfanel.py 从 /etc/pfan/platform.conf 读）。
# ⚠ 每一层都必须 || true 或用 if 包住：set -e 下 sed 读不到文件返回非0，
#   $(...) 赋值语句非0 会【直接杀掉整个脚本】—— 2026-10-10 实测踩到，症状是
#   deploy 在第 81 行静默消失、屏幕上只留下一句 [FAIL]。
PANEL_DIR="${PFAN_PANEL_DIR:-}"
if [ -z "$PANEL_DIR" ]; then
  PANEL_DIR=$(sed -n 's/^PANEL_DIR=//p' platform/platform.conf.example 2>/dev/null | head -1) || true
fi
PANEL_DIR="${PANEL_DIR:-/opt/beszel/beszel_data}"
echo "  面板目录: $PANEL_DIR"
PDIR="$PANEL_DIR"

echo "== 0/5 本地 CI =="
# ⚠ 不用裸调用：set -e 下 ci 返回非0 会让 deploy 静默死在这里，终端只看到脚本停了，
#   看不到"是哪一步、为什么"。显式判断并给出消息（T22 守的就是这个形状）。
bash scripts/ci.sh || { echo "[FAIL] 本地 CI 未通过 —— 部署中止（不碰目标机）" >&2; exit 1; }

echo "== 1/5 目标机建恢复点 + 暂存新文件 =="
# 备份目录在 /root 下 → 必须 sudo；暂存目录必须由 pfan 拥有，否则 scp 写不进去
R "mkdir -p '$STAGE' && sudo -n mkdir -p '$B' /etc/pfan /usr/local/lib/pfan $PDIR/vendor && \
    for f in /usr/local/bin/pfand /usr/local/bin/pfan /usr/local/bin/pfanel.py \
             /usr/local/bin/pfan_platform.py /usr/local/bin/pfan_core.py; do \
      [ -e \"\$f\" ] && sudo -n cp -a \"\$f\" '$B/'; done; \
        # 第 3 步覆盖的每一个路径都必须在这里备份 —— 否则中途失败会留下「新二进制 +
        # 旧面板」的混合态，而重跑 deploy 会把混合态再备一次，原始好状态永远丢失
        # （专家审计 C2）。platform.conf 例外：它只在【缺失时】写入，不覆盖。
        for f in /etc/logrotate.d/pfan /usr/local/lib/pfan/platform.sh \
                 /etc/pfan/fan-candidates.txt \
                 $PDIR/index.html $PDIR/styles.css \
                 $PDIR/app.js $PDIR/core.js \
                 $PDIR/vendor/uPlot.esm.js \
                 $PDIR/vendor/uPlot.min.css \
                 $PDIR/vendor/uPlot.LICENSE \
                 /opt/pfanctl/presets/pfan.conf.cool-quiet \
                 /opt/pfanctl/presets/pfan.conf.performance; do
           # ⚠ [ -e ] 必须带 sudo：面板目录 $PDIR 是 drwx------ root:root，
           # pfan 无权穿越，于是非 sudo 的 [ -e ] 一律 false，7 个面板文件的备份被【静默跳过】，
           # 而 || true 让它看不出错 —— 恢复点少了第 3 步要覆盖的全部面板文件（实测确认）。
           # 这就是「把面板装在别的应用私有目录」（专家审计 m-7）的真实代价。
           sudo -n test -e "\$f" && sudo -n cp -a --parents "\$f" '$B/' || true; done; \
    [ -d $PDIR ] && sudo -n cp -a $PDIR/pfan.html '$B/' 2>/dev/null || true; \
    echo '  备份: $B'; ls -la '$B' | tail -n +2 | sed 's/^/    /'"

echo "== 2/5 传输 =="
# 不加 || true：任何一次传输失败都必须中止，否则会拿残缺的暂存目录去安装
S core/pfand core/pfan core/platform.sh
# deploy/ 开头的路径在暂存区保留子目录（$STAGE/deploy/logrotate.d/pfan），与 $STAGE/pfan
# 区分开 —— 否则两者同名互相覆盖，就是 C3 那个「logrotate 装成 CLI」的缺陷
S deploy/logrotate.d/pfan
# 恢复点核对脚本随部署传过去（deploy/ 开头的会保留子目录，见 S 的 case 分支）
S deploy/check-recovery-point.sh
S server/pfanel.py server/pfan_platform.py server/pfan_core.py
S panel/index.html panel/styles.css panel/app.js panel/core.js
S platform/platform.conf.example platform/fan-candidates.txt
# 曲线预设必须随部署上机：`pfan preset list` 从 /opt/pfanctl/presets 读，
# 没有这条它们就只是仓库里的三个文件（审计 I-7：零消费者、无法通过任何受支持
# 的路径启用）。装到预设目录而不是 config/，与 pfan preset 的查找路径一致。
S config/pfand.conf.cool-quiet config/pfand.conf.performance
# ⚠ 必须用独立暂存名：core/pfan 也叫 $STAGE/pfan，两份 scp 到同一路径会互相覆盖，
# 结果是【把 logrotate 配置装成 /usr/local/bin/pfan】、把 CLI 装成 logrotate 规则。
#（暂存后盲 `ls` 看不出这个碰撞 —— 两份内容都"在"，只是名字被抢了。）
# core/pfan 与 deploy/logrotate.d/pfan 同名：S 落盘时用【各自目录】避开冲突
# （$STAGE/pfan 与 $STAGE/deploy/logrotate.d/pfan），这里再把 CLI 改名成 pfan-cli，
# 让 $STAGE/pfan 这个名字空出来给 logrotate 规则 —— 否则安装出来的是
# logrotate 规则装成 /usr/local/bin/pfan、CLI 装成 /etc/logrotate.d/pfan（C3 原始缺陷）。
R "mv -f '$STAGE/pfan' '$STAGE/pfan-cli'"
# vendor：app.js 以 ESM import 本地 /pfan-vendor-uplot.js。漏装会让【整个 app.js】
# 不执行（连 boot() 都不跑），而冒烟只比对 4 个非 vendor 文件 → 闸门全照绿
# （专家审计 C1：看不见失败的闸门比没有闸门更危险）。
S panel/vendor/uPlot.esm.js panel/vendor/uPlot.min.css panel/vendor/uPlot.LICENSE
# vendor：app.js 以 ESM import 本地 /pfan-vendor-uplot.js。漏装会让【整个 app.js】

# ---- 备份完整性核对（必须在传输之后：脚本本身随部署传过去）----
# 备份循环里每条 cp 都跟 || true，磁盘满 / ACL 拒绝 / 读错误全被吞掉；部署照常覆盖
# 7 个二进制 + 面板 + logrotate + platform.sh 并在末尾打印「回滚点: $B」—— 看着有
# 恢复点，实际可能缺一大半（专家审计 I-1）。实测真发生过：面板目录 drwx------
# root:root，非 sudo 的 [ -e ] 一律 false，7 个面板文件被静默跳过，无任何提示。
# 检查逻辑放在仓库脚本里传输 —— 内联进 R "..." 会被双引号提前求值（试过：报
# sudo: command not found + _w: unbound variable）。
# 必须 sudo：面板目录 drwx------ root:root，非 sudo 读不到会【少算】，
# 检查就会假通过（实测：非 sudo 报 3/3，看着齐了，其实一个面板文件都没备）。
R "sudo -n sh '$STAGE/deploy/check-recovery-point.sh' '$B' '$PANEL_DIR' > /tmp/pfan-rp.txt"
R "cat /tmp/pfan-rp.txt" > "$HOME/.cache/pfan-rp.txt"
_rpexp=$(sed -n "s/^EXPECTED //p" "$HOME/.cache/pfan-rp.txt")
_rppre=$(sed -n "s/^PRESENT //p" "$HOME/.cache/pfan-rp.txt")
if [ -z "$_rpexp" ] || [ -z "$_rppre" ]; then
  echo "  [FAIL] 恢复点核对脚本没跑起来（EXPECTED/PRESENT 读不到），中止部署" >&2
  exit 1
fi
echo "  恢复点已确认落地 $_rppre/$_rpexp 个关键路径"
if [ "$_rppre" != "$_rpexp" ]; then
  grep "^MISS " "$HOME/.cache/pfan-rp.txt" | sed "s/^/    [WARN] 恢复点缺 /"
  echo "  [FAIL] 恢复点不完整 —— 中止部署（否则中途失败无法回滚到一致状态）" >&2
  exit 1
fi
# 不执行（连 boot() 都不跑），而现有冒烟只比对 4 个非 vendor 文件 → 三道闸门全照绿
# （2026-10-08 专家审计 C1：这是比没有闸门更危险的静默失败）。
# 传输后【立刻】校验关键文件在位 —— 否则问题要等到 install 才暴露，且难以定位
for _must in pfand pfan-cli pfanel.py pfan_platform.py pfan_core.py platform.sh \
             platform.conf.example fan-candidates.txt index.html styles.css app.js core.js \
             deploy/logrotate.d/pfan deploy/check-recovery-point.sh \
             pfand.conf.cool-quiet pfand.conf.performance \
             uPlot.esm.js uPlot.min.css uPlot.LICENSE; do
  # 注意：这里【不能】写成 "test -f '$STAGE/$_must'" —— R 用 "$@" 转发，
  # 双引号里的单引号会被原样送到远端 shell，于是路径里带上引号字符、test 永远失败。
  # 路径由 mktemp 生成（仅字母数字/短横/斜杠/点），不需要引号。
  # 用 ls 而不是 test -f：ssh 把整条命令交给远端 shell，test -f 在某些路径形态下
  # 会被解析成 test 的多参数形式（-f 之后只跟一个词时最稳），ls 的失败更直白。
  R "ls $STAGE/$_must >/dev/null" \
    || { echo "[FAIL] 暂存区缺少 $_must —— 传输不完整，中止（不要拿残缺暂存区去安装）" >&2; exit 1; }
done
echo "  暂存区 19 个文件齐备"
R "ls -la '$STAGE' | tail -n +2"

echo "== 3/5 安装（顺序：平台配置 -> 代码 -> 面板）=="
R "set -e
    # 3a. 平台配置：仅在缺失时写入（这是机器自己的配置，不覆盖）
    if [ ! -f /etc/pfan/platform.conf ]; then
      sudo -n install -m 644 '$STAGE/platform.conf.example' /etc/pfan/platform.conf
      echo '  /etc/pfan/platform.conf 由 example 建立'
    else
      echo '  /etc/pfan/platform.conf 已存在，保留原值'
    fi
    sudo -n install -m 644 '$STAGE/fan-candidates.txt' /etc/pfan/fan-candidates.txt
    # 3b. 加载器（pfan/pfand 的 _plat_sh 默认路径）
    sudo -n install -m 644 '$STAGE/platform.sh' /usr/local/lib/pfan/platform.sh
    # 3c. 运行单元（python 模块必须与 pfanel.py 同目录：sys.path[0] 就是脚本目录）
    sudo -n install -m 755 '$STAGE/pfand'        /usr/local/bin/pfand
    sudo -n install -m 755 '$STAGE/pfan-cli'     /usr/local/bin/pfan
    sudo -n install -m 755 '$STAGE/pfanel.py'    /usr/local/bin/pfanel.py
    sudo -n install -m 644 '$STAGE/pfan_platform.py' /usr/local/bin/pfan_platform.py
    sudo -n install -m 644 '$STAGE/pfan_core.py'     /usr/local/bin/pfan_core.py
    # 3d. ⑭ 日志轮转：不装的话 /var/log/pfand.log 会无限长
    sudo -n install -m 644 '$STAGE/deploy/logrotate.d/pfan' /etc/logrotate.d/pfan
    # 曲线预设装到 pfan preset 的查找目录
    sudo -n mkdir -p /opt/pfanctl/presets
    sudo -n install -m 644 '$STAGE/pfand.conf.cool-quiet'  /opt/pfanctl/presets/pfan.conf.cool-quiet
    sudo -n install -m 644 '$STAGE/pfand.conf.performance' /opt/pfanctl/presets/pfan.conf.performance
    echo "  预设已安装: pfan preset list"
    # 先做一次语法演练 —— 配置写错了要等一个月才爆，而且那时日志已经不可控
    sudo -n logrotate -d /etc/logrotate.d/pfan >/dev/null
    echo '  /etc/logrotate.d/pfan 已安装并通过 logrotate -d 自检'
    echo '  运行单元与加载器安装完成'" || { echo "安装失败"; R "ls -la $STAGE"; exit 1; }

# 面板静态文件（独立一段，路径写死，便于失败时定位）
R "set -e
    sudo -n install -m 644 $STAGE/index.html $PDIR/index.html
    sudo -n install -m 644 $STAGE/styles.css $PDIR/styles.css
    sudo -n install -m 755 $STAGE/app.js     $PDIR/app.js
    sudo -n install -m 644 $STAGE/core.js    $PDIR/core.js
    sudo -n mkdir -p $PDIR/vendor
    sudo -n install -m 644 $STAGE/uPlot.esm.js   $PDIR/vendor/uPlot.esm.js
    sudo -n install -m 644 $STAGE/uPlot.min.css  $PDIR/vendor/uPlot.min.css
    sudo -n install -m 644 $STAGE/uPlot.LICENSE  $PDIR/vendor/uPlot.LICENSE
    rm -rf $STAGE
    echo '  面板 4 文件 + vendor 3 文件已安装'"

echo "== 4/5 重启服务 =="
R "sudo -n systemctl restart pfanel && sleep 2 && sudo -n systemctl restart pfand"

# 等待控制回路真正接管，而不是拍脑袋 sleep：
#   - pfand 启动时 ensure_s0i3() 会短暂写 _FSL 1 0，第一轮才设真实档位
#   - pfanel 的 snapshot 有缓存，重启瞬间会拿到重启前的读数
# 两个都会让紧接着的 smoke 读到 level=0 而误判。等 API 报出 level>=1 且 pfand active。
echo "== 4b/5 等待控制回路接管（最多 30s）=="
ready=0
for i in $(seq 1 30); do
  st=$(R "systemctl is-active pfand" 2>/dev/null || echo "?")
  # 用 jq 而不是 sed：原始 JSON 是 `"level": 40`（冒号后有空格），
  # sed 贪婪匹配会因为这个空格永远失配（2026-10-06 实测 30s 全程误判为未接管）。
  # 走 pfan get 而不是 HTTP：HTTP 那条要 $API_BASE 可达，而它在本机解析成
  # http://<ssh-host>:8789 —— 目标是家用 LAN 上的机器、从 CF 隧道 SSH 进来时，
  # 这个地址的 8789 只有本机回环监听，于是 curl 永远拿不到 level，30s 全程误判
  # 「控制回路未接管」，而实际 pfand 早已 active 且 level=33（2026-10-09 实测）。
  # 变量名也不一致：deploy 读 PFAN_API_BASE，smoke 读 PFAN_API。
  lvl=$(R "sudo -n /usr/local/bin/pfan get 2>/dev/null | tail -1" 2>/dev/null \
        | sed -n 's/^\[0,[0-9]*,[0-9]*\]$/&/p' \
        | awk -F, '{gsub(/\]/,"",$2); print $2}')
  if [ "$st" = active ] && [ -n "${lvl:-}" ] && [ "$lvl" -ge 1 ] 2>/dev/null; then
    echo "  第 ${i}s: pfand=$st level=$lvl → 已接管"
    ready=1; break
  fi
  echo "  第 ${i}s: pfand=$st level=${lvl:-<无>} …"
  sleep 1
done
[ "$ready" = 1 ] || { echo "[FAIL] 30s 内控制回路未接管"; exit 1; }

R "systemctl is-active pfanel pfand"

echo "== 4c/5 复核日志轮转已生效 =="
R "sudo -n logrotate -d /etc/logrotate.d/pfan 2>&1 | grep -E 'considering log file|error' | head -3 | sed 's/^/    /'"

echo "== 5/5 实机冒烟 =="
bash scripts/smoke.sh || { echo "[FAIL] 实机冒烟未通过 —— 见上面断言。回滚点: $HOST:$B" >&2; exit 1; }

echo
echo "deploy OK"
echo "  回滚点: $HOST:$B"
echo "  就绪检查用的 API: $API_BASE"
