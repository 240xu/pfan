# 风扇安全热修 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> (recommended) or superpowers:executing-plans to implement this plan task-by-task.
> Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 关闭三条可达的风扇停转/欠冷却路径，并为每一条建立会以变异验证的守卫。

**Architecture:** 三处生产代码修改，跨两个文件（Python 后端 `server/pfanel.py`、bash 守护
`core/pfand`）。每处修改先有一个会失败的测试，再改代码，再证明测试会因变异而失败。
全部落地后做一次真实部署，用 `scripts/smoke.sh` 与浏览器验证。

**Tech Stack:** Python 3（stdlib only）、bash、systemd、`tests/fake/` 假设备、
pytest、shell 守卫套件。

**Spec:** `docs/superpowers/specs/2026-10-10-fan-safety-and-honesty-design.md`

## Global Constraints

- 每条修复的验收标准是「**变异后测试必须变红**」。**"测试通过"不构成证据。**
- 绝不写 `_FSL 1 0` 作为收尾状态；ACPI `_FSL 0` = 风扇停转，不是"交回控制权"。
- 合法档位区间 `1..120`；`_FPS` 表最低档为 **25**（不是 1）。
- `pfand` 是 bash，不 fork Python 做校验（`validate_params` 是面板那份，本轮只补有硬件后果的检查）。
- 部署恢复点机制已验证为 10/10 完整；本轮**不动** `deploy.sh` 的备份逻辑。
- 本轮**不做**：`pfand` 的 `trap`、`set_curve` 之外的鉴权改动、`PANEL_DIR` 默认值迁移。
- 脚本一律用 `bash scripts/<name>.sh` 调用（本机无 `/usr/bin/env`）。
- 写测试时避免在断言模式里含 `|`（会被 shell 当管道）；避免依赖固定 sleep 时长。

## Review Focus

以下输入/条件 spec 没有逐条覆盖，但最可能真的伤到人。每一条都在某个任务的步骤里有对应测试：

1. **`level` 为 `None`（state 文件有 curve 但无 level 键）** —— 与 `level=0` 同类，但走的是
   `.get()` 的 `None` 分支。预期：与 0 同等处理，回落下限。
2. **`_FSL` 写入成功但守护随即崩溃** —— 写与"守护活着"是两件事。预期：判据要求两者同时成立。
3. **配置里 `E` 与 `CAP` 相等**（`E=70 CAP=70`）—— `>=` 与 `>` 的边界。预期：判为非法。
4. **`set_curve` 切换到 `quiet`/`cool`**（守护应当退出）—— 新判据不能把这些误判为失败而回滚。
5. **`apply_persisted_state` 在 `s0i3` 下运行** —— 档位由守护写，后端**不该**自己写档位。

---

### Task 1: `level=0` 必须回落而不是留下停转

**Files:**
- Modify: `server/pfanel.py:413-414`
- Test: `tests/python/test_http.py`（追加）

**Interfaces:**
- Consumes: `acpi(FSL, arg)`（模块级函数，测试用假设备拦截其写入）
- Produces: 无新接口。行为契约：`apply_persisted_state()` 在非 `s0i3` 曲线下，
  `level` 为 `0`/`None`/缺失时，必须写出 `_FSL 1 25`（而非什么都不写）。

- [ ] **Step 1: 写会失败的测试**

追加到 `tests/python/test_http.py`：

```python
def test_persisted_state_with_zero_level_falls_back_not_stops():
    """level=0 不是"有意的 0"，而是"从没按过档位按钮"的默认状态（pfanel.py:79）。

    set_level 把档位钳在 >=1，所以 0 永远不是一次有意的选择。旧实现
    `if st.get("level"):` 把 0 当成"无可恢复"，于是 free 曲线在每次 pfanel
    启动（含每次 deploy.sh）之后都把风扇留在 _FSL 1 0 —— 而 s0i3 下 0 就是停转。
    """
    pfanel._APPLIED = False
    curve_file = os.environ["PFAN_CURVE_FILE"]
    dev = os.environ["PFAN_DEV"]
    with open(curve_file, "w", encoding="utf-8") as fh:
        json.dump({"curve": "free", "level": 0}, fh)
    open(dev, "w").close()
    import builtins as _b
    import subprocess as _sp
    _real_run, _real_open = _sp.run, _b.open
    _sp.run = lambda *a, **k: _real_run(["true"], capture_output=True)
    pfanel.open = lambda p, *a, **k: (
        _real_open(os.path.join(os.path.dirname(dev), "pfanel.log"), "a")
        if str(p) == "/var/log/pfanel.log" else _real_open(p, *a, **k))
    try:
        pfanel.apply_persisted_state()
    finally:
        _sp.run = _real_run
        pfanel.open = _real_open
        pfanel._APPLIED = False
    writes = [l for l in _real_open(dev, encoding="utf-8").read().splitlines()
              if "_FSL" in l]
    assert writes, "free 曲线一个 _FSL 都没写 —— 设备停在先前状态"
    import re as _re
    last = _re.findall(r"_FSL 1 (\d+)", writes[-1])
    assert last and int(last[-1]) >= 25, (
        "level=0 时最终档位是 %r，必须回落到 >=25 的安全下限而不是 0" % (last[-1] if last else None,)
    )


def test_persisted_state_with_missing_level_falls_back_too():
    """state 里根本没有 level 键 —— 走 .get() 的 None 分支，与 0 同类。"""
    pfanel._APPLIED = False
    curve_file = os.environ["PFAN_CURVE_FILE"]
    dev = os.environ["PFAN_DEV"]
    with open(curve_file, "w", encoding="utf-8") as fh:
        json.dump({"curve": "free"}, fh)          # 故意没有 level
    open(dev, "w").close()
    import builtins as _b
    import subprocess as _sp
    import re as _re
    _real_run, _real_open = _sp.run, _b.open
    _sp.run = lambda *a, **k: _real_run(["true"], capture_output=True)
    pfanel.open = lambda p, *a, **k: (
        _real_open(os.path.join(os.path.dirname(dev), "pfanel.log"), "a")
        if str(p) == "/var/log/pfanel.log" else _real_open(p, *a, **k))
    try:
        pfanel.apply_persisted_state()
    finally:
        _sp.run = _real_run
        pfanel.open = _real_open
        pfanel._APPLIED = False
    writes = [l for l in _real_open(dev, encoding="utf-8").read().splitlines()
              if "_FSL" in l]
    last = _re.findall(r"_FSL 1 (\d+)", writes[-1]) if writes else []
    assert last and int(last[-1]) >= 25, "缺 level 键时也必须回落，而不是留下停转"
```

- [ ] **Step 2: 运行，确认失败**

```bash
cd ~/pfan && python3 -m pytest -q tests/python/test_http.py -k "zero_level or missing_level"
```

Expected: **FAILED** — `level=0 时最终档位是 '0'，必须回落到 >=25 的安全下限`
（若 PASS 说明测试没走到目标分支，检查 `pfanel._APPLIED` 与 `PFAN_CURVE_FILE` 接缝）

- [ ] **Step 3: 最小实现**

修改 `server/pfanel.py:413-414`，把

```python
            if st.get("level"):
                acpi(FSL, "1 %d" % int(st["level"]))
```

替换为

```python
            # level=0 与 level 缺失都不是"有意的 0"：set_level() 把档位钳在 >=1，
            # 所以 0 永远只意味着"从没按过档位按钮"（缺省值见 :79）。把它当成
            # "无可恢复"会让 free 曲线在每次 pfanel 启动（含每次 deploy.sh）之后
            # 把风扇留在 _FSL 1 0 —— 而 s0i3 下 0 就是停转（实测，spec F2）。
            # 回落值取 25：_FPS 表的最低档，也是 apply()/want_for 的下限。
            _lv = st.get("level")
            if not _lv or int(_lv) < 1:
                _lv = MIN_SAFE_LEVEL
                log_note = "level 缺失或为 0 -> 回落下限 %d" % MIN_SAFE_LEVEL
            else:
                log_note = None
            acpi(FSL, "1 %d" % int(_lv))
```

并在文件顶部常量区（`_FSL = ...` 附近）加一行：

```python
# 回落下限：_FPS 表最低档。0 在 ACPI 里的含义是停转，不是"最低档"。
MIN_SAFE_LEVEL = 25
```

- [ ] **Step 4: 运行，确认通过**

```bash
cd ~/pfan && python3 -m pytest -q tests/python/test_http.py
```

Expected: `passed`（全部，含既有 19 个）

- [ ] **Step 5: 变异验证（这一步是验收标准，不是可选）**

```bash
cd ~/pfan && cp server/pfanel.py "$HOME/.cache/pfanel.task1.bak"
# 变异：还原成旧的 falsy 判断
python3 - <<'EOF'
p='server/pfanel.py'; s=open(p,encoding='utf-8').read()
s=s.replace('            if not _lv or int(_lv) < 1:', '            if _lv:',1)
open(p,'w',encoding='utf-8').write(s)
EOF
python3 -m pytest -q tests/python/test_http.py -k "zero_level or missing_level"
cp "$HOME/.cache/pfanel.task1.bak" server/pfanel.py
```

Expected: **FAILED**（变异后测试必须红）。若仍绿，说明测试没咬住 —— 停下重写测试。

- [ ] **Step 6: 提交**

```bash
cd ~/pfan && git add server/pfanel.py tests/python/test_http.py && git commit -m "fix(pfanel): a persisted level of 0 must fall back, not stop the fan

level's default is 0 (pfanel.py:79) and set_level() clamps to >=1, so 0 can only ever mean
'no level button has ever been pressed'. The restore path treated it as 'nothing to
restore', so selecting the free curve and restarting pfanel — which every deploy.sh run
does — left _FSL at 0, and under s0i3 that is a stopped fan. Reproduced against the fake
device: device tail _FSL 1 0. This hits the default state of every operator who has not
pressed a level button.

Both 0 and a missing level key now fall back to 25, the lowest entry in the _FPS table.
Two tests, one per branch, because .get() returns None for a missing key and 0 for an
explicit zero and they take different paths. Mutation-verified: restoring the falsy
condition turns both red."
```

---

### Task 2: 配置自检必须拒绝 `E < CAP`

**Files:**
- Modify: `core/pfand:193-196`
- Test: `tests/shell/test_control_paths.sh`（在 T12 段之后追加行为测试）

**Interfaces:**
- Consumes: `tests/fake/bin/dmesg`（假设备层）、`PFAN_*` 环境接缝（`test_pfand_loop` 已在用）
- Produces: 无新接口。行为契约：`E < CAP` 或 `E == CAP` 时，守护记"配置不自洽"、
  写 `_FSL 1 100`、退出，不进入主循环。

- [ ] **Step 1: 写会失败的测试**

在 `tests/shell/test_control_paths.sh` 的 T12 段之后追加（注意：该文件顶部已有
`ok()`/`ng()`/`fails` 与 `$T` 临时目录接缝，沿用）：

```bash
echo "== T13: 配置里 E < CAP（或相等）必须 fail-safe 满速，而不是在最高温写更低的档 =="
# 复核自 spec F4（实测）：E=50 CAP=70 被自检放行，85°C 时写 _FSL 1 50 并记
# 「立即满速 50%」—— 应急比日常上限还弱，而日志谎报。validate_params（面板那份）
# 拒绝这个组合，所以这里也必须拒绝。
_ecfg_bad_case(){
  local name="$1" e="$2" cap="$3"
  T=$(mktemp -d "${TMPDIR:-/tmp}/ecfg.XXXXXX"); : > "$T/dev"; : > "$T/dl"; : > "$T/out"
  printf '{"curve":"s0i3"}\n' > "$T/curve"; echo 85000 > "$T/temp"
  cat > "$T/plat.conf" <<PEOF
EC_ROOT=\_SB.PCI0.LPCB.EC0
FAN_DEVICE=\_SB.PCI0.LPCB.EC0.TFN1
THERMAL_ZONE=$T/temp
DEV=$T/dev
PEOF
  sed "s/^E=100$/E=$e/; s/^CAP=70$/CAP=$cap/" config/pfand.conf.example > "$T/conf"
  timeout 25 env PFAN_PLATFORM_CONF="$T/plat.conf" PFAN_DEV="$T/dev" \
    PFAN_DMESG=fake/bin/dmesg PFAN_DMESG_STATE="$T/st" PFAN_DMESG_LOG="$T/dl" \
    PFAN_LOCK="$T/lock" PFAN_CONF="$T/conf" PFAN_CURVE_FILE="$T/curve" \
    PFAN_EMERG_FILE="$T/emerg" PFAN_LOG="$T/pfand.log" \
    bash core/pfand >"$T/out" 2>&1
  echo "$name|$e|$cap"
  if grep -q '不自洽' "$T/pfand.log" 2>/dev/null; then echo "REJECTED"; else echo "ACCEPTED"; fi
  grep '_FSL' "$T/dl" 2>/dev/null | tail -1
  rm -rf "$T"
}
_res=$(_ecfg_bad_case e_lt_cap 50 70)
if printf '%s' "$_res" | grep -q ACCEPTED; then
  ng "E=50 CAP=70 被自检放行 —— 85°C 会写 _FSL 1 50 并记『立即满速』"
  printf '%s\n' "$_res" | sed 's/^/      /'
else
  ok "E=50 CAP=70 被自检拒绝并 fail-safe"
fi
_res2=$(_ecfg_bad_case e_eq_cap 70 70)
if printf '%s' "$_res2" | grep -q ACCEPTED; then
  ng "E=70 CAP=70（相等）被放行 —— 应急档等于日常上限，等于没有应急"
else
  ok "E=70 CAP=70 被自检拒绝"
fi
echo
```

> 实现者注意：`$T` 在该文件里已被其它用例复用，这里每次调用都新建并清理；`_res` 里的
> `|` 会破坏 shell 变量引用，所以用 `printf '%s'` 原样传递而不是 `"$_res"`。

- [ ] **Step 2: 运行，确认失败**

```bash
cd ~/pfan && bash tests/shell/test_control_paths.sh 2>&1 | sed -n '/T13/,$p'
```

Expected: `[FAIL] E=50 CAP=70 被自检放行 ...`（当前代码 `:193` 只查 `L5 -gt CAP`）

- [ ] **Step 3: 最小实现**

修改 `core/pfand:193`，把

```bash
    if [ "$EMERG_REL" -ge "$EMERG" ] || [ "$T5" -ge "$EMERG" ] || [ "$L5" -gt "$CAP" ]; then
      log "配置不自洽(EMERG_REL=$EMERG_REL EMERG=$EMERG T5=$T5 L5=$L5 CAP=$CAP) -> fail-safe 满速 100% 并退出"
      _cfg_bad=1
    fi
```

替换为

```bash
    # 应急档必须【高于】日常上限 —— 相等也不行：那样"应急"与日常无差别。
    # 漏掉这条的后果是自检放行 E<CAP，然后在最高温写一个比日常上限更低的档位，
    # 同时日志仍写"立即满速"（实测 E=50 CAP=70 -> 85°C 写 _FSL 1 50）。
    # 这既是欠冷却也是谎报。validate_params 早就拒绝这个组合（pfan_core.py），
    # 守护这份自检是它的子集，子集看不见父集看得见的东西。
    if [ "$EMERG_REL" -ge "$EMERG" ] || [ "$T5" -ge "$EMERG" ] || [ "$L5" -gt "$CAP" ] \\
       || [ "$E" -le "$CAP" ]; then
      log "配置不自洽(EMERG_REL=$EMERG_REL EMERG=$EMERG T5=$T5 L5=$L5 E=$E CAP=$CAP) -> fail-safe 满速 100% 并退出"
      _cfg_bad=1
    fi
```

- [ ] **Step 4: 运行，确认通过**

```bash
cd ~/pfan && bash tests/shell/test_control_paths.sh 2>&1 | tail -4
bash tests/shell/test_pfand_loop.sh 2>&1 | tail -2
```

Expected: 两者 `fails=0`

> 若 `test_pfand_loop` 变红，检查它用的配置是否也满足 `E > CAP`（example 里 `E=100 CAP=70`）。

- [ ] **Step 5: 变异验证**

```bash
cd ~/pfan && cp core/pfand "$HOME/.cache/pfand.task2.bak"
python3 -c "
p='core/pfand'; s=open(p,encoding='utf-8').read()
s=s.replace('|| [ \"\$E\" -le \"\$CAP\" ]; then','; then',1)
open(p,'w',encoding='utf-8').write(s)"
bash tests/shell/test_control_paths.sh 2>&1 | grep -E 'E=50|E=70'
cp "$HOME/.cache/pfand.task2.bak" core/pfand
```

Expected: 变异后 **两条都 FAIL**。若绿，测试没咬住。

- [ ] **Step 6: 提交**

```bash
cd ~/pfan && git add core/pfand tests/shell/test_control_paths.sh && git commit -m "fix(pfand): the config self-check must reject E <= CAP

E=50 with CAP=70 passed every check in core/pfand, and at 85 °C the daemon wrote
_FSL 1 50 while logging 应急满速 — the emergency was weaker than the ordinary ceiling at
the hottest temperature, and the log said otherwise. validate_params, which the panel and
pfan preset apply both use, has always rejected that combination; the daemon's self-check
was a strict subset of it, and a subset cannot see what its parent sees.

E <= CAP is now rejected: equal is rejected too, because an emergency equal to the daily
cap is not an emergency. The failure path is the existing one — log, write _FSL 1 100, exit.

Two behavioural tests run the real daemon against fake/ at 85 °C and assert on the log and
the device, rather than grepping the source the way the older guard in this file did.
Mutation-verified: removing the new clause turns both red."
```

---

### Task 3: `set_curve` 必须检查守护是否真的起来了

**Files:**
- Modify: `server/pfanel.py`（`set_curve` 的 `s0i3`/`free` 分支 + 一个新助手函数）
- Test: `tests/python/test_http.py`（追加）

**Interfaces:**
- Consumes: `acpi(EC88, ...)`、`acpi(FSL, ...)`、`subprocess.run`、`get_ec76()`
- Produces: 新助手 `_daemon_ready(timeout_s=5, interval=1) -> bool`。
  返回 `True` 的条件是**两者同时成立**：`systemctl is-active pfand` 为 `active`，
  **且** `get_ec76()` 返回一个非零档位。

- [ ] **Step 1: 写会失败的测试**

追加到 `tests/python/test_http.py`：

```python
def test_set_curve_rolls_back_when_daemon_does_not_come_up(monkeypatch=None):
    """守护起不来时 set_curve 必须回滚到 cool，且【不持久化】。

    set_curve 丢弃 systemctl 的退出码，守护起不来时仍返回 {"ok": true}
    并把该状态写进 curve.state —— 之后每次 pfanel 重启都重放同一个坏状态
    （模块未加载就是这台机器真出过的故障）。
    """
    pfanel._APPLIED = False
    dev = os.environ["PFAN_DEV"]
    open(dev, "w").close()
    import subprocess as _sp
    _real_run = _sp.run
    calls = {"restart": 0}

    def _fake_run(cmd, *a, **k):
        if isinstance(cmd, (list, tuple)) and "systemctl" in " ".join(cmd):
            calls["restart"] += 1
            if "restart" in cmd:
                return _real_run(["false"], capture_output=True)   # 模拟失败
        return _real_run(["true"], capture_output=True)

    _sp.run = _fake_run
    pfanel._daemon_ready = lambda *a, **k: False             # 设备上也读不到档位
    try:
        pfanel.set_curve("s0i3")
    finally:
        _sp.run = _real_run
        pfanel._APPLIED = False
    # 回滚到 cool：cool 的 EC 语义下 _FSL 0 不会停转（见 set_curve 的注释）
    assert pfanel.get_state()["curve"] != "s0i3", (
        "守护起不来却把 s0i3 持久化了 —— 每次重启都会重放")
```

> 若 `set_curve` 在测试里需要写日志路径，照抄 Task 1 测试里的 `pfanel.open` 打桩方式。

- [ ] **Step 2: 运行，确认失败**

```bash
cd ~/pfan && python3 -m pytest -q tests/python/test_http.py -k "does_not_come_up"
```

Expected: **FAILED** — `守护起不来却把 s0i3 持久化了`

- [ ] **Step 3: 最小实现**

在 `server/pfanel.py` 的 `set_curve` **之前**加助手函数：

```python
def _daemon_ready(timeout_s=5, interval=1):
    """守护是否真的接管了。

    两个条件必须同时成立：
      ① systemctl is-active pfand == active
      ② get_ec76() 返回非零档位

    只查 ① 是不够的：守护可能活着却正卡在 ensure_s0i3() 的握手窗口里，
    而那个窗口内 _FSL 就是 0 —— 本项目反复踩到的就是它。那种情况下 ① 为真而
    风扇并没有档位，判成"就绪"等于没检查。
    """
    import time as _t
    deadline = _t.time() + timeout_s
    while _t.time() < deadline:
        try:
            st = subprocess.run(["systemctl", "is-active", "pfand"],
                                capture_output=True, text=True, timeout=5)
            if (st.stdout or "").strip() == "active":
                if get_ec76():
                    return True
        except Exception:
            pass
        _t.sleep(interval)
    return False
```

然后改 `set_curve` 的 `s0i3` 分支（当前 `subprocess.run([... "restart", "pfand"], capture_output=True)`
之后什么都不做）为：

```python
        acpi(FSL, "1 0")
        acpi(EC88, "4 181 0x79 0x%02X 0" % val)
        subprocess.run(["systemctl", "restart", "pfand"], capture_output=True)
        if not _daemon_ready():
            # 起不来就别把状态留成 s0i3：模块没加载 / 设备节点缺失时这会发生，
            # 而持久化会让每次 pfanel 重启重放同一个坏状态。回滚到 cool ——
            # cool 曲线下固件自己管温，_FSL 0 不会停转。
            with open("/var/log/pfanel.log", "a") as f:
                f.write("%s s0i3 拉起 pfand 失败，回滚到 cool\\n"
                        % time.strftime("%Y-%m-%d %H:%M:%S"))
            return set_curve("cool")
```

并且把 `save_state(curve=name)` 移到**判据之后**（现在是先存再回 HTTP），
使失败路径不会持久化。

- [ ] **Step 4: 运行，确认通过**

```bash
cd ~/pfan && python3 -m pytest -q tests/python/test_http.py
```

Expected: 全绿

- [ ] **Step 4a: 补两条 Review Focus 测试（自审发现：这两条列在计划的 Review Focus 里却没有测试）**

追加到 `tests/python/test_http.py`：

```python
def test_switching_to_a_firmware_curve_is_not_treated_as_failure():
    """RF4：切到 quiet/cool 时守护【应该】正常退出 —— 新判据不能把它误判成失败而回滚。

    core/pfand:174 在曲线非 s0i3 时 exit 0，这是设计。若 _daemon_ready 被套用到
    quiet/cool 分支上，这两条曲线会立刻被判成"守护没起来"然后被回滚成别的曲线 ——
    用户选了固件接管，却拿到另一种曲线。
    """
    import inspect as _insp
    src = _insp.getsource(pfanel.set_curve)
    body = src.split('name == "free"')[0] if 'name == "free"' in src else src
    assert "_daemon_ready" not in body, (
        "quiet/cool 分支里出现了 _daemon_ready —— 固件曲线本就不该有守护")


def test_s0i3_restore_must_not_write_a_level_from_the_backend():
    """RF5：s0i3 下档位由守护写，后端【不该】自己写。

    apply_persisted_state 在 curve==s0i3 时只重启守护就返回；如果这条分支也写了
    档位，后端与守护会各写一次，而两者算出的 base/trim 可能不同 —— 表现为风扇抖动。
    """
    pfanel._APPLIED = False
    dev = os.environ["PFAN_DEV"]
    open(dev, "w").close()
    with open(os.environ["PFAN_CURVE_FILE"], "w", encoding="utf-8") as fh:
        json.dump({"curve": "s0i3", "level": 40}, fh)
    import builtins as _b
    import subprocess as _sp
    _real_run, _real_open = _sp.run, _b.open
    _sp.run = lambda *a, **k: _real_run(["true"], capture_output=True)
    pfanel.open = lambda p, *a, **k: (
        _real_open(os.path.join(os.path.dirname(dev), "pfanel.log"), "a")
        if str(p) == "/var/log/pfanel.log" else _real_open(p, *a, **k))
    try:
        pfanel.apply_persisted_state()
    finally:
        _sp.run = _real_run
        pfanel.open = _real_open
        pfanel._APPLIED = False
    fsl = [l for l in _real_open(dev, encoding="utf-8").read().splitlines()
           if "_FSL" in l]
    # s0i3 分支会写 _FSL 1 0（交回控制权），但【不应】再写一个具体档位
    nonzero = [l for l in fsl if not l.rstrip().endswith("_FSL 1 0")]
    assert not nonzero, (
        "s0i3 还原时后端写了具体档位 %r —— 应由守护写，否则两个写者会打架" % nonzero
    )
```

运行：

```bash
cd ~/pfan && python3 -m pytest -q tests/python/test_http.py -k "firmware_curve or must_not_write"
```

Expected: 两条都 **PASS**（它们断言的是"不该发生的事没发生"，实现未改时即成立）。
若 RF5 红，说明当前 `s0i3` 分支已经在写档位 —— 那本身是缺陷，记下来交回 spec 讨论，不要顺手改。

- [ ] **Step 5: 变异验证**

```bash
cd ~/pfan && cp server/pfanel.py "$HOME/.cache/pfanel.task3.bak"
python3 -c "
p='server/pfanel.py'; s=open(p,encoding='utf-8').read()
s=s.replace('if not _daemon_ready():','if False:',1)
open(p,'w',encoding='utf-8').write(s)"
python3 -m pytest -q tests/python/test_http.py -k "does_not_come_up"
cp "$HOME/.cache/pfanel.task3.bak" server/pfanel.py
```

Expected: **FAILED**

- [ ] **Step 6: 提交**

```bash
cd ~/pfan && git add server/pfanel.py tests/python/test_http.py && git commit -m "fix(pfanel): set_curve must not report success when the daemon never came up

set_curve discarded systemctl's exit status, so when the kernel module is unloaded — the
fault this machine actually suffered on 2026-10-06 — the handler still answered
{ok: true} and persisted the curve. Every later pfanel restart replayed it.

It now verifies the daemon actually took over, and the criterion is two conditions rather
than one: systemctl is-active AND a non-zero level read back from the device. Checking
only is-active is not enough, because the daemon can be alive and still sitting in the
ensure_s0i3() handshake, where _FSL is 0 — the exact window this project keeps tripping
over. On failure it rolls back to cool (under cool the firmware owns the curve, so _FSL 0
does not stop the fan) and does not persist the state.

Mutation-verified."
```

---

### Task 4: 一次真实部署与端到端验证

**Files:**
- 无代码改动。验证步骤。

**Interfaces:**
- Consumes: `scripts/deploy.sh`、`scripts/smoke.sh`、目标机 `192.168.1.10`
- Produces: 部署后的实机状态、面板可用性证据

- [ ] **Step 1: 本地全量门禁**

```bash
cd ~/pfan && bash scripts/ci.sh
```

Expected: `=== ci.sh: PASS (rc=0) ===`

- [ ] **Step 2: 部署**

```bash
cd ~/pfan && timeout 2400 bash scripts/deploy.sh
```

Expected: `deploy OK`。恢复点必须报 `10/10`，暂存区文件齐备，`smoke.sh: PASS`。
若报 `控制回路未接管`，读 ledger 里记录的握手窗口说明——Task 1–3 不会引入新等待。

- [ ] **Step 3: 实机确认三条修复都在位**

```bash
timeout 60 ssh -o ConnectTimeout=15 -o IdentitiesOnly=yes pfan@192.168.1.10 \
  'echo "  level: $(sudo -n /usr/local/bin/pfan get 2>/dev/null | tail -1)"
   for s in pfanctl pfand pfanel; do printf "    %-9s %s\n" $s "$(systemctl is-active $s)"; done
   echo "    部署件 sha 一致: $(sudo -n sha256sum /usr/local/bin/pfanel.py | cut -c1-16)"'
```

Expected: `pfanctl/pfand/pfanel` 三个 `active`；`level` 为非零。

- [ ] **Step 4: 浏览器复验面板没坏**

导航到 `http://192.168.1.10:8789/pfan`，求值：

```js
() => ({
  uplot: document.querySelectorAll('.uplot canvas').length,
  chartH: [...document.querySelectorAll('.chartbox')].map(d => Math.round(d.getBoundingClientRect().height)),
  gauge: document.querySelectorAll('svg.g-arc').length,
  sweep: [...document.querySelectorAll('svg.g-arc path')].map(p => (p.getAttribute('d').match(/A [\d.]+ [\d.]+ 0 \d (\d)/) || [])[1]),
  status: (document.querySelector('#conn-st') || {}).textContent
})
```

Expected: `uplot: 3`、`chartH` 全在 220–250、`gauge: 2`、`sweep` 全为 `"0"`、
`status` 为「实时」。等 20 秒再采一次，`chartH` 必须**完全不变**。

- [ ] **Step 5: 复核 ledger 里没有新的假声称**

```bash
cd ~/pfan && WS=$(cat "$HOME/.pfan_p2_ws") && tail -30 "$WS/progress.md"
```

确认：本轮三条修复的描述只写**实际验证过的内容**。特别地——
- 若没做过浏览器复验，就不要写"浏览器已验证"
- 若某条只有"代码逻辑正确"而没有变异证据，就不要写"变异验证"

- [ ] **Step 6: 提交并推送**

```bash
cd ~/pfan && WS=$(cat "$HOME/.pfan_p2_ws") && cat >> "$WS/progress.md" <<'EOF'

FAN-SAFETY HOTFIX LANDED
  Three reproduced fan-stop / under-cooling paths closed, each with a guard that was proven
  by mutation to have teeth (the previous round's T12 claimed that and was not).

  S1  server/pfanel.py  level 0 now falls back to 25 instead of leaving _FSL 1 0. The
      default level IS 0 and set_level clamps to >=1, so 0 only ever means "no level button
      pressed" — this is the default state of every operator. Two tests, one for the explicit
      zero and one for the missing key, because .get() returns None for the latter.
  S2  core/pfand        the self-check now rejects E <= CAP. E=50 CAP=70 previously passed
      and produced _FSL 1 50 at 85 °C while logging 应急满速 — weaker than the ordinary
      ceiling at the hottest temperature, and falsely reported. Equal is rejected too.
  S3  server/pfanel.py  set_curve verifies the daemon took over and rolls back to cool if not,
      without persisting. The criterion is "is-active AND a non-zero level read back",
      because the daemon can be alive inside the ensure_s0i3 handshake window.

  Deliberately NOT done, with reasons recorded in the spec: the pfand trap (it exits 0
  normally when the curve is not s0i3, before ensure_s0i3 runs, so a naive trap would clobber
  a deliberately chosen firmware curve on every switch; and a single crash self-heals in
  15 s via Restart=on-failure).
EOF
git add -A && git commit -m "docs: record the fan-safety hotfix" && git push origin main
```