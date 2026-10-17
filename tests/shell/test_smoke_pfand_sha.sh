#!/usr/bin/env bash
# R-01 验收：smoke.sh §4b 的 pfand 部署件比对必须真的能报红。
# 做法与 test_guards.sh T6 相同：把 smoke.sh 里 §4b 那段【逐字抽出来】跑真实代码，
# 只给 remote() 与 sha256sum 喂脚本化数据 —— 不复述、不重写比对逻辑，否则本测试
# 会跟着"另一份实现"走，而 smoke.sh 那段本身可能早已失效（本分支反复出现的坑：
# 注释/断言说的与代码做的各是一回事）。三个方向：同 sha 通过 / 分叉报红 /
# 读不到报红（fail-closed，不许把"读不到"当成"没分叉"）。
set -uo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
cd "$repo" || exit 1
fails=0; ok(){ echo "  [ok]   $1"; }; ng(){ echo "  [FAIL] $1"; fails=$((fails+1)); }

T=$(mktemp -d "${TMPDIR:-$HOME/.cache}/pfan-smoke-sha.XXXXXX")
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"

# 假 sha256sum：只把 ${STUB_REPO_SHA} 打出来，不看参数 —— 仓库侧的值由驱动注入
cat > "$T/bin/sha256sum" <<'STUB'
#!/bin/sh
printf '%s  %s\n' "${STUB_REPO_SHA}" "$1"
STUB
chmod +x "$T/bin/sha256sum"

# 逐字抽取 §4b：从它的 printf 头到 §5 的 printf 头（不含）为止
awk '/^printf .+=== 4b\./ {f=1} /^printf .+=== 5\./ {f=0} f' scripts/smoke.sh > "$T/block.sh"
if [ "$(wc -l < "$T/block.sh")" -lt 10 ]; then
  ng "抽不出 smoke.sh 的 §4b pfand 比对（抽到 $(wc -l < "$T/block.sh") 行）—— 抽取锚点失效，先修这个"
  echo "test_smoke_pfand_sha: fails=$fails"; exit "$fails"
fi
ok "从 smoke.sh 逐字抽到 §4b 比对块（$(wc -l < "$T/block.sh") 行）"

# 驱动：定义 ok/bad/remote，source 抽出来的真实代码。block 自己的 stdout 丢弃，
# 只用驱动自己的 "<rc>|<累计输出>" 判定。
cat > "$T/run.sh" <<'RUN'
#!/usr/bin/env bash
set -uo pipefail
rc=0; out=""
ok(){ out="${out}[ok] $1
"; }
bad(){ out="${out}[FAIL] $1
"; rc=1; }
remote(){
  # 读不到 = 无输出（真 remote 的 ssh 失败形态）；有值才回一条 sha256sum 行
  [ -n "$STUB_LIVE_SHA" ] || return 0
  printf '%s  /usr/local/bin/pfand\n' "$STUB_LIVE_SHA"
}
. "$1" >/dev/null 2>&1
printf '%s|%s' "$rc" "$out"
RUN
chmod +x "$T/run.sh"
run_block(){ STUB_REPO_SHA="$1" STUB_LIVE_SHA="$2" PATH="$T/bin:$PATH" bash "$T/run.sh" "$T/block.sh"; }

sha_a=1111111111111111111111111111111111111111111111111111111111111111
sha_b=2222222222222222222222222222222222222222222222222222222222222222

r=$(run_block "$sha_a" "$sha_a"); rc=${r%%|*}; out=${r#*|}
if [ "$rc" = 0 ] && printf '%s' "$out" | grep -q '一致'; then
  ok "两侧同 sha -> PASS（rc=0，且报「一致」）"
else
  ng "两侧同 sha 却未 PASS: rc=$rc out=$out"
fi

r=$(run_block "$sha_a" "$sha_b"); rc=${r%%|*}; out=${r#*|}
if [ "$rc" != 0 ] && printf '%s' "$out" | grep -q '分叉'; then
  ok "模拟分叉部署（repo=$sha_a live=$sha_b）-> FAIL 且点名分叉（两个 sha 都在消息里）"
else
  ng "模拟分叉部署却未报红: rc=$rc out=$out"
fi

r=$(run_block "$sha_a" ""); rc=${r%%|*}; out=${r#*|}
if [ "$rc" != 0 ] && printf '%s' "$out" | grep -q '读不到'; then
  ok "设备件读不到 -> FAIL（fail-closed，不把读不到当没分叉）"
else
  ng "设备件读不到却未报红: rc=$rc out=$out"
fi

echo "test_smoke_pfand_sha: fails=$fails"; exit "$fails"
