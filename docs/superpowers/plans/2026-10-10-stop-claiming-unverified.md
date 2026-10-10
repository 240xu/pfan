# 停止宣称假话 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> (recommended) or superpowers:executing-plans to implement this plan task-by-task.
> Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让仓库停止声称它没有验证过的东西 —— 修好一条自称有变异验证而实际没有的安全守卫、
一条永不触发的死护栏、一处名为"单一事实源"实为两个文件的分歧、一个名不副实的脱敏门，
以及 `SECURITY.md` 里七处与实现不符的安全声明。

**Architecture:** 六个任务，互不依赖，可任意顺序执行。除 Task 1 会新增一个行为测试外，
**没有生产代码改动** —— 本计划只动测试、工具与文档，零硬件后果，不需要部署。

**Tech Stack:** bash、Python 3（stdlib）、`tests/fake/` 假设备、pytest、shell 守卫套件。

**Spec:** `docs/superpowers/specs/2026-10-10-fan-safety-and-honesty-design.md`

## Global Constraints

- 验收标准是「**变异后测试必须变红**」。**"测试通过"不构成证据。**
- **不得写死计数**（如"19 处"）—— 从脚本输出取。上一轮的计数已经漂移过一次。
- 断言模式里避免含 `|`（被 shell 当管道）；避免依赖固定 `sleep` 时长。
- 全仓库**不得含 U+FFFD**（`tests/shell/test_repo_hygiene.sh` T18 会扫）。
- 改 `panel/app.js` 后必须做浏览器复验 —— 那里有两个只能靠像素发现的历史缺陷。
- 本计划**不部署**。只有需要实机验证的任务才例外，任务里会写明。
- 计划里出现的每个 `file:line` 都应在实施时重新核对 —— 本计划撰写时它们全部核对过，
  但前面的任务会移动行号。

## Review Focus

1. **文档里删掉一个"已知缺陷"警告，但那个缺陷还在** —— 本计划大量删除"状态：未完成"
   之类的注释。删之前必须确认被描述的东西**确实**已完成，否则就是把待办变成了谎言。
2. **`sanitize.sh` 补规则后，作者自己的推送被门拦住** —— 上一版就是这么"静默杀掉每次推送"
   的（`895d9ad` 修的就是它）。任何新规则在合并前必须先让仓库能变绿。
3. **`--list` 的输出被当成契约** —— 有别的脚本或文档读它吗？先 grep 再改。
4. **`test_panel_split` T4 收窄到函数体后，误伤了别的合法写法** —— 收窄判据容易同时收窄过头。

---

### Task 1: 给档位下界守卫补行为测试（补上上一轮虚假的"变异验证"）

**Files:**
- Modify: `tests/shell/test_control_paths.sh`（替换现有的 grep 式 T12）
- Test: 同一文件（行为测试自带断言）

**Interfaces:**
- Consumes: `tests/fake/bin/dmesg`、`config/pfand.conf.example`、`PFAN_*` 接缝
- Produces: 无新接口。行为契约：`E`/`CAP`/`L0..L5` 任一 `< 25` 时，真实守护记
  "档位下界非法"、写 `_FSL 1 100`、退出。

- [ ] **Step 1: 确认现状（先复现缺陷本身）**

```bash
cd ~/pfan && cp core/pfand "$HOME/.cache/pfand.t1.bak"
python3 -c "
p='core/pfand'; s=open(p,encoding='utf-8').read()
s=s.replace('if [ \"\$E\" -lt 25 ] || [ \"\$CAP\" -lt 25 ] || [ \"\$L0\" -lt 25 ]; then',
            'if [ \"\$E\" -lt 0 ] || [ \"\$CAP\" -lt 0 ] || [ \"\$L0\" -lt 0 ]; then',1)
open(p,'w',encoding='utf-8').write(s)"
bash tests/shell/test_control_paths.sh 2>&1 | grep -E 'fails='
cp "$HOME/.cache/pfand.t1.bak" core/pfand
```

Expected: 现状 **`fails=0`** —— 这就是缺陷本身：把检查整个关掉，测试照样绿。
把它记下来，Step 3 之后这个命令必须让 `fails` 变成非 0。

- [ ] **Step 2: 写会失败的行为测试**

替换 `tests/shell/test_repo_hygiene.sh`… 不，替换 `tests/shell/test_control_paths.sh` 里
现有的 T12 整段（它现在是 `grep -qE 'L0.*< *25|_cfg_bad.*L0|\[ "\$E" -lt ' core/pfand` 这类文本断言），
改为：

```bash
echo "== T12: 档位下界必须真的挡住停转（跑真实守护，不 grep 源码）=="
# 为什么不用 grep：2026-10-09 的实测显示，把 [ "$E" -lt 25 ] 改成 [ "$E" -lt 0 ]
# （等于关掉整个检查）之后，这条 grep 型守卫【照样】报 fails=0。
# 而那正是它被加进来要防的东西：E=0 会让守护在最热温度写 _FSL 1 0（风扇停转）。
# 断言必须落在【设备收到了什么】上。
_bound_case(){
  local tag="$1" sedexpr="$2"
  _T=$(mktemp -d "${TMPDIR:-/tmp}/bound.XXXXXX"); : > "$_T/dev"; : > "$_T/dl"; : > "$_T/out"
  printf '{"curve":"s0i3"}\n' > "$_T/curve"; echo 85000 > "$_T/temp"
  cat > "$_T/plat.conf" <<PEOF
EC_ROOT=\_SB.PCI0.LPCB.EC0
FAN_DEVICE=\_SB.PCI0.LPCB.EC0.TFN1
THERMAL_ZONE=$_T/temp
DEV=$_T/dev
PEOF
  sed "$sedexpr" config/pfand.conf.example > "$_T/conf"
  timeout 25 env PFAN_PLATFORM_CONF="$_T/plat.conf" PFAN_DEV="$_T/dev" \
    PFAN_DMESG=fake/bin/dmesg PFAN_DMESG_STATE="$_T/st" PFAN_DMESG_LOG="$_T/dl" \
    PFAN_LOCK="$_T/lock" PFAN_CONF="$_T/conf" PFAN_CURVE_FILE="$_T/curve" \
    PFAN_EMERG_FILE="$_T/emerg" PFAN_LOG="$_T/pfand.log" \
    bash core/pfand >"$_T/out" 2>&1
  if grep -q '档位下界非法' "$_T/pfand.log" 2>/dev/null; then _v=REJECTED; else _v=ACCEPTED; fi
  _w=$(grep -o '_FSL 1 [0-9]*' "$_T/dl" 2>/dev/null | tail -1)
  printf '%s %s %s' "$tag" "$_v" "${_w:-none}"
  rm -rf "$_T"
}
_r=$(_bound_case E0 's/^E=100$/E=0/')
case "$_r" in *"REJECTED"*) ok "E=0 被自检拒绝" ;; *) ng "E=0 被放行 —— $_r" ;; esac
case "$_r" in *"_FSL 1 100"*) ok "E=0 时 fail-safe 写满速 100" ;; *) ng "E=0 时没写 100 —— $_r" ;; esac
_r=$(_bound_case CAP0 's/^CAP=70$/CAP=0/')
case "$_r" in *"REJECTED"*) ok "CAP=0 被自检拒绝（否则 apply 钳到 0 且 d=0<DEAD 变成静默不写）" ;; *) ng "CAP=0 被放行 —— $_r" ;; esac
_r=$(_bound_case L0_24 's/^L0=25$/L0=24/')
case "$_r" in *"REJECTED"*) ok "L0=24（低于 _FPS 最低档 25）被拒绝" ;; *) ng "L0=24 被放行 —— $_r" ;; esac
_r=$(_bound_case L5_24 's/^L5=70$/L5=24/')
case "$_r" in *"REJECTED"*) ok "L5=24 被拒绝" ;; *) ng "L5=24 被放行 —— $_r" ;; esac
echo
```

- [ ] **Step 3: 运行，确认通过**

```bash
cd ~/pfan && bash tests/shell/test_control_paths.sh 2>&1 | sed -n '/T12/,$p'
```

Expected: 四条 `ok`，`fails=0`

- [ ] **Step 4: 变异验证（这一步现在是关键）**

重跑 Step 1 那条把 `-lt 25` 改成 `-lt 0` 的命令。

Expected: **`fails` 非 0**，且失败信息点名 `E=0 被放行`。

- [ ] **Step 5: 提交**

```bash
cd ~/pfan && git add tests/shell/test_control_paths.sh && git commit -m "test: replace the lower-bound guard's grep with a behavioural test

The guard added on 2026-10-09 to stop the fan being commanded off at high temperature was a
grep for a string in core/pfand. Changing [ \"\$E\" -lt 25 ] to [ \"\$E\" -lt 0 ] — which turns
the whole check off and restores the fan-stop bug — left it reporting fails=0. The commit
message claimed 'mutations that survive: none'; that was false.

The replacement runs the real daemon against fake/ at 85 °C and asserts on what the device
received: E=0, CAP=0, L0=24 and L5=24 must each be rejected by the self-check and produce
_FSL 1 100. CAP=0 is the quieter of the two failure modes — apply() clamps to 0 and then
d = |0 - written| is below DEAD, so the daemon neither writes nor logs, leaving the fan on
the level the handshake left behind."
```

---

### Task 2: 修好那条永不触发的护栏，并收窄它保护的那条守卫

**Files:**
- Modify: `panel/app.js`（`fitChart` 里的比较）
- Modify: `tests/shell/test_panel_split.sh`（T4 限定到 `sizeOf` 函数体）

**Interfaces:**
- Consumes: `panel/core.js` 无接口变化
- Produces: 无新接口。行为契约：`fitChart` 的护栏在测量结果与上次请求**相同**时不再调用
  `setSize`，从而在任何反馈回环复发时收敛。

- [ ] **Step 1: 确认死代码（复现缺陷）**

```bash
cd ~/pfan && grep -n 'last\.' panel/app.js | sed 's/^/  /'
```

Expected: 出现 `last.w` / `last.h`，而 `sizeOf` 返回的是 `{width, height}`
（用 `grep -n 'return {' -A2 panel/app.js` 确认键名）。两者永不相等，护栏从不触发。

- [ ] **Step 2: 修好护栏**

把 `panel/app.js` 中 `fitChart` 里的

```js
      if (last.w === t.width && last.h === t.height) return;
```

改为

```js
      // ⚠ 键名必须与 sizeOf() 的返回值一致（{width,height}）。之前这里写的是
      // last.w / last.h，与返回对象的键永不匹配 —— undefined === number 恒假，
      // 于是这条"反馈回环 fail closed"的护栏从不触发，而 commit b06a191 把它
      // 描述成一道已经就位的第二道防线（2026-10-09 自审发现）。
      if (last.width === t.width && last.height === t.height) return;
```

并确认同一函数内的 `let last = s;` 把 `{width, height}` 赋给了 `last`（若不是，改成
`let last = { width: s.width, height: s.height };`。

- [ ] **Step 3: 收窄 T4 到函数体**

`tests/shell/test_panel_split.sh` 里现有 T4 是
`grep -qE 'parentElement' panel/app.js`。该字符串在 `sizeOf` 与 `fitChart` 各出现一次，
所以把 `sizeOf` 改回量自身、`fitChart` 保留时守卫仍然绿。改为只查 `sizeOf` 的函数体：

```bash
grep -qE 'parentElement' panel/app.js && ok "app.js 用了 parentElement" || ng "app.js 未使用 parentElement"
# 关键：必须在【sizeOf 函数体内】而不是全文 —— 该表达式在 fitChart 里也出现一次，
# 只改 sizeOf 的话全文 grep 仍然命中，守卫对"图表无界增高"这个缺陷失明。
if sed -n '/^function sizeOf/,/^}/p' panel/app.js | grep -qE 'parentElement'; then
  ok "sizeOf 测量的是父元素（图表高度不会无界增长）"
else
  ng "sizeOf 没有测量父元素 —— 图表会 h = h + legend 无界增高"
fi
```

- [ ] **Step 4: 变异验证**

```bash
cd ~/pfan && cp panel/app.js "$HOME/.cache/app.t2.bak"
python3 -c "
p='panel/app.js'; s=open(p,encoding='utf-8').read()
s=s.replace('const box = el.parentElement || el;','const box = el;',1)
open(p,'w',encoding='utf-8').write(s)"
bash tests/shell/test_panel_split.sh 2>&1 | grep -E 'sizeOf|fails='
cp "$HOME/.cache/app.t2.bak" panel/app.js
bash tests/shell/test_panel_split.sh 2>&1 | tail -1
```

Expected: 变异后**收窄的那条** FAIL，`fitChart` 里的那一条仍 ok —— 这正说明收窄生效了。

- [ ] **Step 5: 浏览器复验（必须 —— 这两个缺陷历史上都只有像素能发现）**

部署这一轮（其它任务不需要部署时，可与其他任务的部署合并）后导航到面板并求值：

```js
() => ({
  chartH: [...document.querySelectorAll('.chartbox')].map(d => Math.round(d.getBoundingClientRect().height)),
  gauge: document.querySelectorAll('svg.g-arc').length,
  sweep: [...document.querySelectorAll('svg.g-arc path')].map(p => (p.getAttribute('d').match(/A [\d.]+ [\d.]+ 0 \d (\d)/) || [])[1])
})
```

等 20 秒再采一次：`chartH` 必须**完全不变**；`gauge` 为 2；`sweep` 全为 `"0"`。

- [ ] **Step 6: 提交**

```bash
cd ~/pfan && git add panel/app.js tests/shell/test_panel_split.sh && git commit -m "fix(panel): the feedback-loop guard compared keys that do not exist

b06a191 added a last-requested-size guard so any future sizing feedback loop would fail
closed, and described it as a second line of defence. It compared last.w and last.h against
a sizeOf() return of {width, height}, so the comparison was always false and the guard could
never fire. A self-review found it by reading the two sides rather than trusting the commit
message.

Fixed the keys, and narrowed the guard that protects the fix itself: test_panel_split T4
grepped panel/app.js for 'parentElement', which appears in both sizeOf and fitChart, so
reverting sizeOf to measure the element outright — restoring the unbounded chart growth that
cost the most to find — left the guard green. It now checks the sizeOf body specifically.
Mutation-verified: reverting sizeOf fails the narrowed assertion while the fitChart one
still passes."
```

---

### Task 3: 让 `PANEL_DIR` 的"单一事实源"真的成立

**Files:**
- Modify: `core/pfan`（`detect --write` 的输出加 `PANEL_DIR`）
- Modify: `scripts/deploy.sh`（已存在的 `/etc/pfan/platform.conf` 缺该键时幂等补上）
- Test: `tests/shell/test_detect.sh`

**Interfaces:**
- Consumes: `platform/platform.conf.example` 的 `PANEL_DIR` 行（`9eb0043` 加入）
- Produces: `pfan detect --write` 写出的配置含 `PANEL_DIR=<该例的值>`。

- [ ] **Step 1: 确认分歧存在**

```bash
cd ~/pfan && timeout 60 ssh -o ConnectTimeout=15 -o IdentitiesOnly=yes pfan@192.168.1.10 \
  'sudo -n grep -c "^PANEL_DIR=" /etc/pfan/platform.conf || echo 0'
```

Expected: `0` —— 目标机上的配置**没有**这一行，所以 `pfanel.py` 现在落回硬编码兜底，
而 deploy/smoke 读的是仓库的 example。两个源，只是今天恰好相同。

- [ ] **Step 2: 写会失败的测试**

追加到 `tests/shell/test_detect.sh`：

```bash
echo "== detect --write 必须写出 PANEL_DIR，否则 pfanel 会落回硬编码兜底 =="
# 2026-10-09：9eb0043 把面板目录改成从 platform.conf 派生，并声称成了单一事实源。
# 但 `pfan detect --write` 只输出 5 个键，不含 PANEL_DIR，而 deploy 只在文件【缺失】时
# 写 platform.conf —— 于是任何已经跑过 detect 的机器（包括这台）上，pfanel.py 读不到
# 该键，静默落回硬编码，而 deploy/smoke 用的是仓库 example 的值。两个源。
T=$(mktemp -d "${TMPDIR:-/tmp}/detect.XXXXXX")
_fakeplat="$T/platform.conf"
sed "s|^THERMAL_ZONE=.*|THERMAL_ZONE=$T/zone|" \
    <(sed -n '1,/^THERMAL_ZONE=/p' platform/platform.conf.example) > "$_fakeplat"
echo 42000 > "$T/zone"
: > "$T/dev"
PFAN_PLATFORM_CONF="$_fakeplat" PFAN_DEV="$T/dev" PFAN_DMESG=fake/bin/dmesg \
  PFAN_DMESG_STATE="$T/st" PFAN_DMESG_LOG="$T/dl" PFAN_LOCK="$T/lock" \
  bash core/pfan detect --write "$T/out.conf" >/dev/null 2>&1 || true
if [ -f "$T/out.conf" ] && grep -q '^PANEL_DIR=' "$T/out.conf"; then
  ok "detect --write 输出了 PANEL_DIR=$(sed -n 's/^PANEL_DIR=//p' "$T/out.conf")"
else
  ng "detect --write 没有输出 PANEL_DIR —— pfanel 会落回硬编码兜底，与 deploy/smoke 分歧"
fi
rm -rf "$T"
echo
```

> 实现者注意：`pfan detect --write <file>` 的参数顺序请先读 `core/pfan` 的 `detect`
> 函数确认，若不同则调整调用，但**断言不变**：`out.conf` 里必须有 `PANEL_DIR=`。

- [ ] **Step 3: 运行，确认失败**

```bash
cd ~/pfan && bash tests/shell/test_detect.sh 2>&1 | grep -E 'PANEL_DIR|fails='
```

Expected: `[FAIL] detect --write 没有输出 PANEL_DIR`

- [ ] **Step 4: 实现**

`core/pfan` 的 `detect` 函数里，找到写 `EC_CMD` 的那行（当前写 5 个键，
约在 `core/pfan:135`），在其后加一行：

```bash
  # 面板目录也要写出来：pfanel.py 从 platform.conf 取 PANEL_DIR（见 9eb0043），
  # 不写就落回代码里的硬编码兜底，而 deploy/smoke 读的是仓库 example —— 两个源。
  printf 'PANEL_DIR=%s\n' "$(sed -n 's/^PANEL_DIR=//p' "$PLAT" 2>/dev/null | head -1)" >> "$OUT"
```

（`$PLAT`/`$OUT` 按 `detect` 里的实际变量名替换。）

`scripts/deploy.sh`：找到写 `/etc/pfan/platform.conf` 的那段（当前是"仅在缺失时写入"），
在**已存在但缺 `PANEL_DIR`** 时补一行。用 `grep -q '^PANEL_DIR='` 判断，幂等。

- [ ] **Step 5: 运行，确认通过**

```bash
cd ~/pfan && bash tests/shell/test_detect.sh 2>&1 | tail -2
bash tests/shell/test_repo_hygiene.sh 2>&1 | tail -2
```

Expected: 两者 `fails=0`

- [ ] **Step 6: 变异验证**

```bash
cd ~/pfan && cp core/pfan "$HOME/.cache/pfan.t3.bak"
python3 -c "
p='core/pfan'; s=open(p,encoding='utf-8').read()
s=s.replace(\"printf 'PANEL_DIR=%s\\\\n'\",\"printf 'PANEL_DI=%s\\\\n'\",1)
open(p,'w',encoding='utf-8').write(s)"
bash tests/shell/test_detect.sh 2>&1 | grep -E 'PANEL_DIR'
cp "$HOME/.cache/pfan.t3.bak" core/pfan
```

Expected: 变异后 FAIL

- [ ] **Step 7: 提交**

```bash
cd ~/pfan && git add core/pfan scripts/deploy.sh tests/shell/test_detect.sh && git commit -m "fix: make the panel directory actually single-sourced

9eb0043 moved the panel path into platform.conf and called it a single source of truth. It
was two: deploy.sh and smoke.sh read the repo's platform.conf.example, while pfanel.py reads
the machine's /etc/pfan/platform.conf — and pfan detect --write, which is what creates that
file, never emitted PANEL_DIR. So on this machine, and any machine where detect has run,
pfanel silently fell back to the hardcoded literal while the deploy tooling used a
different value. It happened to coincide today.

detect --write now emits PANEL_DIR, and deploy backfills it into an existing
platform.conf. The migration itself — moving the default off Beszel's private directory —
is deliberately still not done; that is a separate change and this only makes the claim true
so it can be made honestly."
```

---

### Task 4: 让脱敏门名副其实

**Files:**
- Modify: `scripts/sanitize.sh`（`--list` 输出实际规则；补两条规则；排除自身规则文本）
- Modify: `hooks/pre-push`（删掉重复的第二次调用）
- Test: `tests/shell/test_repo_hygiene.sh`（新增 T24）

**Interfaces:**
- Consumes: `scripts/sanitize.local`、`scripts/sanitize.allow`（均 gitignored）
- Produces: `bash scripts/sanitize.sh --list` 的输出与编译进 `RULES` 的规则**逐条对应**。

- [ ] **Step 1: 量化现状（复现缺陷）**

```bash
cd ~/pfan && echo "  --list 宣称 $(bash scripts/sanitize.sh --list 2>/dev/null | grep -cE '^[[:space:]]+\S') 类"
echo "  实际规则 $(grep -c $'\t' scripts/sanitize.sh) 条"
echo "  pfan@ 命中 $(bash scripts/sanitize.sh 2>/dev/null | grep -c 'pfan@') 处（应 >0）"
```

Expected: `5` / `3` / `0`。**最后那个 0 就是缺陷**：SSH 用户名正是这个门宣称要拦的，
而它在 9 行可执行文件里。

- [ ] **Step 2: 先定策略，再改代码**

`scripts/sanitize.allow` 是 gitignored 的 → **fork 永远无法让这个门变绿**。
在动手补规则之前，选一个并写进注释：

- **策略 A（推荐）**：门按类别报告，豁免用**行内注释** `# sanitize-allow: <理由>`，
  随代码提交。fork 可以逐条豁免并看到理由。
- 策略 B：保留 `sanitize.allow`，但 `--list` 明确说明"本门对 fork 不可满足"，
  并在 README 写明。

选 A 则实现见 Step 3；选 B 则跳过 Step 3 的行内注释部分，只做 `--list` 与计数修正。
**在提交信息里写明选了哪个。**

- [ ] **Step 3: `--list` 输出实际规则**

把 `scripts/sanitize.sh` 的 `--list` 分支从输出散文改为遍历 `$RULES` 打印
`<正则>  <说明>`。这样"宣称"与"实现"不可能不一致 —— 这是本任务的核心。

- [ ] **Step 4: 补两条缺失规则**

在 `RULES` heredoc 里追加（用 TAB 分隔，与现有格式一致）：

```
\<用户名\>@[\w.-]+	带用户名的 SSH 目标：公开仓库里暴露 ssh 别名与账号
\b(10|192\.168|172\.(1[6-9]|2\d|3[01]))\.[\d.]+\b	私网地址：暴露别人的网络拓扑
```

第二条应带豁免机制（策略 A 下即行内注释），否则 deploy.sh / smoke.sh / hooks 里的
`192.168.1.10` 会让门变红 —— **这正是上一版"静默杀掉每次推送"的成因，必须先能变绿**。

- [ ] **Step 5: 排除自身与已声明的例外**

- `scripts/sanitize.sh` 的规则文本行本身会被自己的规则命中 → 从扫描范围里排除该文件。
- `--list` 若被别的脚本或文档读取，先 `grep -rn 'sanitize.sh --list'` 确认再改。

- [ ] **Step 6: 删掉 hooks/pre-push 里的重复调用**

`hooks/pre-push` 目前连续两次跑 `sanitize.sh` 并丢弃第一次的结果（`895d9ad` 遗留）。
删掉多余的那一次，保留带 `|| true` 兜住的那一次（`set -e` 会因非零退出杀掉整个 hook）。

- [ ] **Step 7: 写守卫并变异验证**

在 `tests/shell/test_repo_hygiene.sh` 追加：

```bash
sec "T24: 脱敏门的宣称必须与实现一致，且能拦住 SSH 用户名"
_n_list=$(bash scripts/sanitize.sh --list 2>/dev/null | grep -cE '^[[:space:]]+\S')
_n_real=$(grep -c $'\t' scripts/sanitize.sh)
[ "$_n_list" -ge "$_n_real" ] \
  && ok "--list 列出 $_n_list 条，实际编译 $_n_real 条（宣称 ⊇ 实现）" \
  || ng "--list 只列 $_n_list 条而编译了 $_n_real 条 —— 宣称与实现不一致"
# 关键：SSH 用户名必须真的被拦（这是 --list 宣称、而旧实现漏掉的一类）
_probe=$(mktemp -d "${TMPDIR:-/tmp}/san.XXXXXX")
printf 'host %s\n' "someone@example.com" > "$_probe/x.md"
if bash scripts/sanitize.sh 2>/dev/null | grep -q 'example.com'; then
  ok "sanitize.sh 能拦住带用户名的 SSH 目标"
else
  ng "sanitize.sh 拦不住 <user>@<host> —— --list 宣称拦它，实际没有规则"
fi
rm -rf "$_probe"
echo
```

变异验证：临时把新规则改成 `\<用户名\>@[\w.-]+` → 无意义的模式，跑 T24，
第二条必须 FAIL。

- [ ] **Step 8: 提交**

```bash
cd ~/pfan && git add scripts/sanitize.sh hooks/pre-push tests/shell/test_repo_hygiene.sh && git commit -m "fix(sanitize): make --list report the rules it actually compiles

8013ff0 shipped the gate with --list advertising five categories and three compiled rules.
The two it did not compile were 'user@host SSH targets' and 'private LAN subnets' — and
'pfan@' sits in nine lines across executable files while 192.168.1.10 sits in twenty. The
gate the audit flagged as the blocker before going public passed both of them.

--list now walks the compiled rules instead of printing prose, so the claim and the
implementation cannot disagree. Two rules added, with the exemption mechanism settled first:
the previous version's allow-file is gitignored, which means a fork can never make the gate
green — a gate a fork cannot satisfy is decoration for a fork.

Also removed a duplicated sanitize.sh invocation in pre-push that discarded its first result
(vestigial from 895d9ad), keeping the one wrapped in '|| true' because the hook runs under
set -e."
```

---

### Task 5: `SECURITY.md` 改成与实现一致

**Files:**
- Modify: `SECURITY.md`
- Test: `tests/shell/test_security_docs.sh`（现有 T5 系列依赖具体措辞，需同步）

**Interfaces:**
- Consumes: 无
- Produces: 无新接口。文档契约：读者读完 `SECURITY.md` 后对边界的理解与代码一致。

- [ ] **Step 1: 逐条核对要改的声称**

先用代码核对下表（每一行的"实际"列都必须是你**自己**在代码里确认的，不是抄本文档）：

| 位置 | 现声称 | 实际 |
|---|---|---|
| `:16` | 写接口是 `POST /api/level`、`/api/curve` | 无这些路由。`do_POST` 从不读 `self.path`，写操作由 **JSON body 的键**决定（`level`/`profile`/`hold`/`auto`/`params`），任意路径皆可 |
| `:16-19` | 写接口靠 `X-Pfan-Token` 无条件保护 | 代码为真，但 token 由 `/pfan.js` 无鉴权下发 → 对**非浏览器客户端等同无鉴权** |
| `:20` | 令牌 30 字节随机数 | `secrets.token_urlsafe(32)` = **32 随机字节、43 个 base64url 字符** |
| `:22` | 免鉴权读接口是三个 | 不完整：`/api/history`、`/api/params`（返回 `/etc/pfan.conf` 绝对路径）、`/api/profile`（泄漏 `guard_temp`）、`/api/mode`、`/api/levels` |
| `:45` | "唯一的秘密是 token（600）" | 模式是 600，但它被送到互联网上 |
| `:54` | 静态 bearer 对单机可接受 | 该结论以 token 保密为前提 |
| `:71-73` | `/dev/pfanctl` 等价于 root | 对设备为真；**对面板 API 不真** |

- [ ] **Step 2: 改写那七处**

保持文档原有的中文语气与结构。每处改动写清**为什么**，而不只是改成事实。

- [ ] **Step 3: 补上仍然有效的边界（避免矫枉过正）**

必须同时写明哪些仍然成立，否则读者会以为整个安全模型是假的：

- **Origin 白名单**是真实有效的浏览器 CSRF 边界：跨源页面发起的 `fetch`/`<form>`
  一定带 `Origin`，无法伪造
- **不发 ACAO** 阻止跨源读取遥测
- **ufw** 使 8789 仅 LAN 可达
- **`guard()` 的 82°C 上限**是写路径危害的实际天花板
- 以及一句话的真实模型：**隧道的可达性就是边界；应用层不认证任何人；兜底的是 `guard()`**

- [ ] **Step 4: 同步 `test_security_docs.sh`**

该文件的 T5a/T5b 会 grep `SECURITY.md` 的具体措辞。逐条跑：

```bash
cd ~/pfan && bash tests/shell/test_security_docs.sh 2>&1 | tail -6
```

改文档后若有失败，**先判断是文档写错了还是守卫过时了**。守卫过时就更新守卫并在提交信息里
说明它守的是什么属性 —— 不要为了让测试绿而把文档改回原来的假话。

- [ ] **Step 5: 加一条守卫，钉住"不再宣称 token 保护写路径"**

追加到 `tests/shell/test_security_docs.sh`：

```bash
sec "T6: SECURITY.md 不得把 token 说成写路径的鉴权边界"
# 2026-10-09 外部审计：pfanel.py 把 __PFAN_TOKEN__ 注入 app.js 并无鉴权地提供，
# 所以「带有效 token」对任何能访问面板的人都是可得的。SECURITY.md 却把它写成
# 写接口的保护栏。这条守卫钉住"如实描述"，防止它被改回去。
if grep -qE '必须带有效 .?X-Pfan-Token.?，\*\*无条件\*\*' SECURITY.md; then
  ng "SECURITY.md 仍把 token 描述为无条件保护 —— 它是无鉴权 GET 就能拿到的值"
else
  ok "SECURITY.md 不再把 token 说成写路径的鉴权边界"
fi
grep -qE '非浏览器客户端|无鉴权客户端|等同无鉴权' SECURITY.md \
  && ok "SECURITY.md 明说了非浏览器客户端的情形" \
  || ng "SECURITY.md 没有说明非浏览器客户端等同无鉴权"
echo
```

- [ ] **Step 6: 变异验证 Step 5**

把 `:16-19` 那句改回"必须带有效 `X-Pfan-Token`，**无条件**"，跑 `test_security_docs.sh`。

Expected: 第一条 FAIL

- [ ] **Step 7: 提交**

```bash
cd ~/pfan && git add SECURITY.md tests/shell/test_security_docs.sh && git commit -m "docs(SECURITY): describe the write boundary the code actually has

pfanel.py substitutes __PFAN_TOKEN__ into app.js and serves app.js to anyone who fetches it,
so 'a valid token' is obtainable by anyone who can reach the panel — confirmed live, the
public endpoint returns a 43-character token inlined in the JavaScript. SECURITY.md
described that token as the unconditional gate on writes.

Any HTTP gate whose value the client chooses is satisfiable by curl, Origin and Host
included, so the one app-layer boundary a scripted client cannot forge is a secret that is
never transmitted. That is not what this does, and the document said it was.

The rewrite states the real model — the tunnel's reachability is the boundary, the app
authenticates nobody, and guard() at 82 °C is what bounds the consequence — and, just as
importantly, states what still works: the Origin allowlist is a genuine browser CSRF
boundary, the absent ACAO blocks cross-origin reads, and ufw keeps 8789 on the LAN. Writing
only the first half would have been its own kind of untruth.

Also corrected: the write endpoints are selected by JSON body key on any path (do_POST never
reads self.path), the token is 32 bytes / 43 characters rather than 30, the unauthenticated
read set is larger than documented, and /dev/pfanctl being equivalent to root is true of the
device and not of the panel API."
```

---

### Task 6: 删掉已过时的"未完成"状态行

**Files:**
- Modify: `docs/OPERATIONS.md`（`scripts/sanitize.sh` 的状态行、恢复点路径计数）
- Test: `tests/shell/test_repo_hygiene.sh`（T13 已有的文档守卫可扩展）

**Interfaces:**
- Consumes: 无
- Produces: 无新接口。

- [ ] **Step 1: 找出所有已过时的状态行**

```bash
cd ~/pfan && grep -rn '状态：未完成\|尚未实现\|尚未创建\|TODO\|待办' \
  README.md SECURITY.md docs/ 2>/dev/null | grep -v '未完成（' | cut -c1-110
```

逐条判断：**该东西现在真的存在吗？** 存在就删掉状态行；不存在就保留。
（Review Focus 第 1 条：删掉"已知缺陷"警告前必须确认缺陷真的没了。）

- [ ] **Step 2: 修恢复点路径计数**

`docs/OPERATIONS.md` 里"上面列出的 16 个路径"已过时（加了两个预设文件）。
**不要写死数字** —— 改成引用脚本的输出，或写"以 `deploy/check-recovery-point.sh`
的 EXPECTED/PRESENT 为准"。

- [ ] **Step 3: 扩展 T13 守卫**

`test_repo_hygiene.sh` 的 T13 已禁止某些"待修"措辞。补一条：

```bash
for f in README.md SECURITY.md docs/OPERATIONS.md docs/specs/*.md; do
  [ -f "$f" ] || continue
  if grep -qE '脚本尚不存在|尚未创建' "$f"; then
    # 逐条核对：被描述的东西现在存在吗？存在则本行过时。
    ng "$f 仍声称某脚本/文件『尚未创建』—— 先确认它现在真的不存在，否则删掉该状态行"
  fi
done
ok "已检查文档里的『尚未创建』类状态行"
```

- [ ] **Step 4: 提交**

```bash
cd ~/pfan && git add docs/ tests/shell/test_repo_hygiene.sh && git commit -m "docs: drop status lines that describe work as unfinished when it is not

OPERATIONS.md still recorded scripts/sanitize.sh as 尚未实现 on the same line whose body
said it was done, and the spec still listed LICENSE and NOTICE as 待办 — both landed days
ago. A release checklist that misstates its own state is worse than none: the author in six
months will trust it.

The recovery-point path count was hardcoded at 16 and had already drifted to 18, so it now
points at the script's own EXPECTED/PRESENT output instead. Every status line was checked
against the tree before removal — the ones describing work that genuinely has not happened
stay."
```

---

### Task 7: 最终门禁

**Files:** 无代码改动。

- [ ] **Step 1: 全量**

```bash
cd ~/pfan && bash scripts/ci.sh
```

Expected: `PASS (rc=0)`

- [ ] **Step 2: 变异总表**

本计划声称"变异后变红"的守卫，逐条重跑一遍并记录结果。任何一条存活都停下：

| 守卫 | 变异 | 应红 |
|---|---|---|
| Task 1 T12 | `[ "$E" -lt 25 ]` → `-lt 0` | ✓ |
| Task 2 收窄 T4 | `sizeOf` 的 `parentElement` → `el` | ✓ |
| Task 3 detect | `PANEL_DIR=` → `PANEL_DI=` | ✓ |
| Task 4 T24 | 去掉 `@[\w.-]+` 规则 | ✓ |
| Task 5 T6 | 把"无条件"措辞放回 `SECURITY.md` | ✓ |

- [ ] **Step 3: ledger**

```bash
cd ~/pfan && WS=$(cat "$HOME/.pfan_p2_ws") && cat >> "$WS/progress.md" <<'EOF'

HONESTY PASS LANDED
  The guard added to stop the fan being commanded off at high temperature was a grep for a
  string; changing the check it protects from "-lt 25" to "-lt 0" left it green. Its commit
  message had claimed "mutations that survive: none". It is now a behavioural test that runs
  the real daemon against fake/ and asserts on the device, and the same command that used to
  pass silently now fails.

  Also: a feedback-loop guard in panel/app.js compared last.w/last.h against a {width,height}
  return, so it could never fire — it had been described as a second line of defence; the
  guard protecting it greps a string that appears in two functions, so reverting the fix left
  it green (now scoped to the sizeOf body); PANEL_DIR was called a single source of truth
  while detect --write never emitted the key, so any machine that ran detect fell back to a
  literal; the sanitisation gate advertised five categories and compiled three, missing
  exactly the two that would have caught the author's own SSH username and LAN address;
  and SECURITY.md described a token as an unconditional write gate while the server publishes
  it to anyone who fetches the panel JavaScript.

  The trap is still deliberately absent: pfand exits 0 normally when the curve is not s0i3,
  before ensure_s0i3 runs, so a naive trap would clobber a deliberately chosen firmware curve.
EOF
git add -A && git commit -m "docs: record the honesty pass" && git push origin main
```