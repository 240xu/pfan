#!/usr/bin/env bash
# scripts/deploy.sh — 把仓库版本部署到目标机并验证。
# 顺序纪律：先 ci → 再备份 → 再装文件 → 【最后】才重启服务。
# 特别注意：/etc/pfan/platform.conf 是机器自己的配置，只在【不存在】时用 example 填充，
#           绝不覆盖已有文件（用户可能跑过 pfan detect 得到不同路径）。
set -euo pipefail
trap 'echo "[FAIL] deploy 中止于第 $LINENO 行" >&2' ERR
cd "$(dirname "$0")/.."

HOST="${PFAN_HOST:-192.168.1.10}"
KEY="$HOME/.ssh/pfan_deploy_key"
SSHOPT=(-i "$KEY" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=15)
R="ssh ${SSHOPT[@]} pfan@$HOST"
S="scp ${SSHOPT[@]}"
TS=$(date +%Y%m%d-%H%M%S)
B="/root/backups/pfan-deploy-$TS"
STAGE="/tmp/pfan-deploy-$$"

echo "== 0/5 本地 CI =="
bash scripts/ci.sh

echo "== 1/5 目标机建恢复点 + 暂存新文件 =="
# 备份目录在 /root 下 → 必须 sudo；暂存目录必须由 pfan 拥有，否则 scp 写不进去
$R "mkdir -p '$STAGE' && sudo -n mkdir -p '$B' /etc/pfan /usr/local/lib/pfan /opt/beszel/beszel_data/vendor && \
    for f in /usr/local/bin/pfand /usr/local/bin/pfan /usr/local/bin/pfanel.py \
             /usr/local/bin/pfan_platform.py /usr/local/bin/pfan_core.py; do \
      [ -e \"\$f\" ] && sudo -n cp -a \"\$f\" '$B/'; done; \
    [ -d /opt/beszel/beszel_data ] && sudo -n cp -a /opt/beszel/beszel_data/pfan.html '$B/' 2>/dev/null || true; \
    echo '  备份: $B'; ls -la '$B' | tail -n +2 | sed 's/^/    /'"

echo "== 2/5 传输 =="
# 不加 || true：任何一次传输失败都必须中止，否则会拿残缺的暂存目录去安装
$S core/pfand core/pfan core/platform.sh               "pfan@$HOST:$STAGE/"
$S server/pfanel.py server/pfan_platform.py server/pfan_core.py "pfan@$HOST:$STAGE/"
$S panel/index.html panel/styles.css panel/app.js panel/core.js "pfan@$HOST:$STAGE/"
$S platform/platform.conf.example platform/fan-candidates.txt    "pfan@$HOST:$STAGE/"
# ⚠ 必须用独立暂存名：core/pfan 也叫 $STAGE/pfan，两份 scp 到同一路径会互相覆盖，
# 结果是【把 logrotate 配置装成 /usr/local/bin/pfan】、把 CLI 装成 logrotate 规则。
#（暂存后盲 `ls` 看不出这个碰撞 —— 两份内容都"在"，只是名字被抢了。）
$S deploy/logrotate.d/pfan                       "pfan@$HOST:$STAGE/logrotate-pfan"
# vendor：app.js 以 ESM import 本地 /pfan-vendor-uplot.js。漏装会让【整个 app.js】
# 不执行（连 boot() 都不跑），而现有冒烟只比对 4 个非 vendor 文件 → 三道闸门全照绿
# （2026-10-08 专家审计 C1：这是比没有闸门更危险的静默失败）。
$S panel/vendor/uPlot.esm.js panel/vendor/uPlot.min.css panel/vendor/uPlot.LICENSE \
    "pfan@$HOST:$STAGE/"
$R "ls -la '$STAGE' | tail -n +2"

echo "== 3/5 安装（顺序：平台配置 -> 代码 -> 面板）=="
$R "set -e
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
    sudo -n install -m 755 '$STAGE/pfan'         /usr/local/bin/pfan
    sudo -n install -m 755 '$STAGE/pfanel.py'    /usr/local/bin/pfanel.py
    sudo -n install -m 644 '$STAGE/pfan_platform.py' /usr/local/bin/pfan_platform.py
    sudo -n install -m 644 '$STAGE/pfan_core.py'     /usr/local/bin/pfan_core.py
    # 3d. ⑭ 日志轮转：不装的话 /var/log/pfand.log 会无限长
    sudo -n install -m 644 '$STAGE/logrotate-pfan' /etc/logrotate.d/pfan
    # 先做一次语法演练 —— 配置写错了要等一个月才爆，而且那时日志已经不可控
    sudo -n logrotate -d /etc/logrotate.d/pfan >/dev/null
    echo '  /etc/logrotate.d/pfan 已安装并通过 logrotate -d 自检'
    echo '  运行单元与加载器安装完成'" || { echo "安装失败"; $R "ls -la $STAGE"; exit 1; }

# 面板静态文件（独立一段，路径写死，便于失败时定位）
$R "set -e
    sudo -n install -m 644 $STAGE/index.html /opt/beszel/beszel_data/index.html
    sudo -n install -m 644 $STAGE/styles.css /opt/beszel/beszel_data/styles.css
    sudo -n install -m 755 $STAGE/app.js     /opt/beszel/beszel_data/app.js
    sudo -n install -m 644 $STAGE/core.js    /opt/beszel/beszel_data/core.js
    sudo -n mkdir -p /opt/beszel/beszel_data/vendor
    sudo -n install -m 644 $STAGE/uPlot.esm.js   /opt/beszel/beszel_data/vendor/uPlot.esm.js
    sudo -n install -m 644 $STAGE/uPlot.min.css  /opt/beszel/beszel_data/vendor/uPlot.min.css
    sudo -n install -m 644 $STAGE/uPlot.LICENSE  /opt/beszel/beszel_data/vendor/uPlot.LICENSE
    rm -rf $STAGE
    echo '  面板 4 文件 + vendor 3 文件已安装'"

echo "== 4/5 重启服务 =="
$R "sudo -n systemctl restart pfanel && sleep 2 && sudo -n systemctl restart pfand"

# 等待控制回路真正接管，而不是拍脑袋 sleep：
#   - pfand 启动时 ensure_s0i3() 会短暂写 _FSL 1 0，第一轮才设真实档位
#   - pfanel 的 snapshot 有缓存，重启瞬间会拿到重启前的读数
# 两个都会让紧接着的 smoke 读到 level=0 而误判。等 API 报出 level>=1 且 pfand active。
echo "== 4b/5 等待控制回路接管（最多 30s）=="
ready=0
for i in $(seq 1 30); do
  st=$($R "systemctl is-active pfand" 2>/dev/null || echo "?")
  # 用 jq 而不是 sed：原始 JSON 是 `"level": 40`（冒号后有空格），
  # sed 贪婪匹配会因为这个空格永远失配（2026-10-06 实测 30s 全程误判为未接管）。
  lvl=$(timeout 12 curl -fsS --max-time 8 "http://$HOST:8789/api/now" 2>/dev/null \
        | jq -r '.level // empty' 2>/dev/null)
  if [ "$st" = active ] && [ -n "${lvl:-}" ] && [ "$lvl" -ge 1 ] 2>/dev/null; then
    echo "  第 ${i}s: pfand=$st level=$lvl → 已接管"
    ready=1; break
  fi
  echo "  第 ${i}s: pfand=$st level=${lvl:-<无>} …"
  sleep 1
done
[ "$ready" = 1 ] || { echo "[FAIL] 30s 内控制回路未接管"; exit 1; }

$R "systemctl is-active pfanel pfand"

echo "== 4c/5 复核日志轮转已生效 =="
$R "sudo -n logrotate -d /etc/logrotate.d/pfan 2>&1 | grep -E 'considering log file|error' | head -3 | sed 's/^/    /'"

echo "== 5/5 实机冒烟 =="
bash scripts/smoke.sh

echo
echo "deploy OK"
echo "  回滚点: $HOST:$B"
