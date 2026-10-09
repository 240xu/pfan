import os, re, sys
from pathlib import Path
_REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(_REPO, "server"))
import pfan_core
from pfan_core import validate_params, nearest_fps, FPS

CFG = os.path.join(_REPO, "config")

def _load(name):
    d = {}
    with open(os.path.join(CFG, name), encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                d[k.strip()] = int(v.strip())
    return d

def want(p, t):
    if t >= p["EMERG"]: return p["E"]
    if t <= p["IDLE"]: return p["L0"]
    for i in (1, 2, 3, 4, 5):
        if t <= p["T%d" % i]: return p["L%d" % i]
    return p["L5"]

BASE = _load("pfand.conf.example")
QUIET = _load("pfand.conf.cool-quiet")
PERF = _load("pfand.conf.performance")
# 85h 实测温度分布（p50=50 p90=58 p99=67 max=73）的粗略近似
DIST = [(48,.35),(52,.20),(56,.20),(60,.12),(64,.08),(68,.04),(72,.01)]

def test_presets_exist_and_parse():
    for n in ("pfand.conf.cool-quiet", "pfand.conf.performance"):
        assert os.path.isfile(os.path.join(CFG, n)), f"缺预设 {n}"

def test_presets_pass_validate_params():
    """预设必须能被写入 —— validate_params 不通过的话面板会 400。"""
    for n, p in (("cool-quiet", QUIET), ("performance", PERF)):
        errs = validate_params(p)
        assert errs == [], f"{n} 校验不过: {errs}"

def test_presets_have_all_required_keys():
    for n, p in (("cool-quiet", QUIET), ("performance", PERF)):
        miss = [k for k in pfan_core.NEED if k not in p]
        assert not miss, f"{n} 缺键: {miss}"

def test_quiet_is_quieter_than_baseline_in_the_real_range():
    """A 必须在真实工作温区（48~68°C）比现状更慢，否则'安静'是假的。"""
    for t in (48, 52, 56, 60, 64, 68):
        assert want(QUIET, t) <= want(BASE, t), f"{t}°C: A({want(QUIET,t)}) 不该高于现状({want(BASE,t)})"
    avg_q = sum(w * want(QUIET, t) for t, w in DIST)
    avg_b = sum(w * want(BASE, t) for t, w in DIST)
    assert avg_q < avg_b - 3, f"A 加权平均 {avg_q:.1f}% 未明显低于现状 {avg_b:.1f}%"

def test_performance_is_more_aggressive_than_baseline():
    """B 必须在中段更积极，且不能低于现状（否则'凉快'是假的）。"""
    for t in (52, 56, 60, 64, 68):
        assert want(PERF, t) >= want(BASE, t), f"{t}°C: B({want(PERF,t)}) 不该低于现状({want(BASE,t)})"
    avg_p = sum(w * want(PERF, t) for t, w in DIST)
    avg_b = sum(w * want(BASE, t) for t, w in DIST)
    assert avg_p > avg_b + 5, f"B 加权平均 {avg_p:.1f}% 未明显高于现状 {avg_b:.1f}%"

def test_presets_never_relax_the_safety_envelope():
    """两套都不能放松安全边界：禁 0、不超 CAP、应急自洽、E 够高。"""
    for n, p in (("cool-quiet", QUIET), ("performance", PERF)):
        assert p["L0"] >= pfan_core.L0_MIN, f"{n}: L0={p['L0']} 低于风扇可运行下限"
        for k in ("L0","L1","L2","L3","L4","L5"):
            assert 0 < p[k] <= p["CAP"], f"{n}: {k}={p[k]} 越界（0=停转，上限 CAP={p['CAP']}）"
        assert p["EMERG_REL"] < p["EMERG"], f"{n}: 滞回不自洽"
        assert p["E"] >= p["CAP"], f"{n}: 应急档低于 CAP"
        assert p["DWELL"] >= p["IV"], f"{n}: DWELL 小于 IV 会震荡"

def test_emergency_still_reachable_under_load():
    """再怎么调，高温下都必须能打到应急满速 —— 曲线不能把热保护调没了。"""
    for n, p in (("cool-quiet", QUIET), ("performance", PERF)):
        assert want(p, p["EMERG"]) == p["E"], f"{n}: 到 EMERG 却不满速"
        assert want(p, 95) == p["E"], f"{n}: 95°C 仍不满速"

def test_out_of_table_levels_still_resolve_via_nearest_fps():
    """两套都引入了表外档位（28/34/44/54/62），面板 RPM/噪音必须仍能算出。"""
    for p in (QUIET, PERF):
        for t in (50, 58, 66, 74):
            lv = want(p, t)
            ent = nearest_fps(lv)
            assert ent is not None, f"档位 {lv} 在权威表里取不到（面板会显示 null）"


# ---------- floor_of / center_of 不得依赖某一条字面梯子 ----------
# 专家审计（safety 域，实测）：core/pfand 的 floor_of/center_of 是按字面档位
# {25,30,40,50,60,70} 写的 case，与 config/pfand.conf.example 完全一致，而两套预设用的
# 是别的梯子（cool-quiet 25/28/34/44/56/66、performance 28/34/44/54/62/70）。
# 落进 `*)` 分支就返回 $EMERG，于是：
#   center_of -> 85（或 80），高于任何工作温度 -> w=(T-85)*GAIN 恒为大负数
#                -> trim 永久钉在 -TRIM，配置里的 TRIM/GAIN 形同虚设
#   floor_of  -> $EMERG，降档门 `T <= EMERG-HYST` 恒真 -> 配置的滞回【完全失效】
# 实测后果：performance 声明 68°C→62% 实际交付 54%，比现役曲线的 60% 更弱 ——
# 与它的名字相反。两套预设的加权平均值也从声称的 27.2%/42.1% 变成 25.6%/34.2%。
def _pfand_functions():
    """从 core/pfand 里抽出 floor_of/center_of 的 case 表，看它覆盖了哪些档位。"""
    src = (Path(__file__).resolve().parents[2] / "core" / "pfand").read_text(
        encoding="utf-8")
    out = {}
    for fn in ("floor_of", "center_of"):
        m = re.search(fn + r"\(\)\{(.*?)\n\}", src, re.S)
        assert m, f"core/pfand 里找不到 {fn}"
        # 一行里可能有多个 case 分支（`30) echo .. ;; 40) echo .. ;;`），
        # 所以逐 token 找 `<数字>)` 而不是按行首匹配 —— 按行首只抽到一半，
        # 守卫就会假绿（这正是本文件第一条测试最初的状态）。
        out[fn] = set(re.findall(r"(?m)(?:^|\s|;)(\d+)\)", m.group(1)))
    return out


def test_skeleton_helpers_must_not_pin_one_literal_ladder():
    """守卫：floor_of/center_of 不能用只认 {25,30,40,50,60,70} 的 case。"""
    fns = _pfand_functions()
    for name, seen in fns.items():
        # 判据：这两个函数【不应】含任何字面档位 case —— 它们必须按实际 L0..L5 推导。
        # （例配置碰巧也是 25/30/40/50/60/70，所以"当前行为正确"不能作为判据：
        #  换个梯子就整体落进 `*)` 返回 $EMERG，trim 被永久钉在 -TRIM、降档滞回恒真。）
        assert not seen, (
            f"{name} 里有字面档位 case {sorted(seen, key=int)} —— 必须改成按实际 "
            "L0..L5 推导。换一套梯子就会整体落进 `*)` 分支返回 $EMERG："
            "trim 被永久钉在 -TRIM、降档滞回恒真。"
        )


def test_every_preset_level_is_handled():
    """两套预设里出现的每一个档位都必须被 floor_of/center_of 正确处理。

    修好之后这两个函数按实际 L0..L5 推导，不再有 case 表，所以这里改成【真的把
    core/pfand 抽出来跑一遍】，断言每个档位都映射到合理值（不是 EMERG）。
    """
    cases = _run_pfand_helpers()
    for name, (levels, res) in cases.items():
        assert res["unhandled"] == [], (
            f"{name} 的档位 {res['unhandled']} 没有被 floor_of/center_of 处理 —— "
            "会落进兜底返回 EMERG"
        )
        # L0 对应的触发下界必须是 -999（最低档永远可降），否则降档门形同虚设
        assert res["floor_of_L0"] == -999, (
            f"{name}: floor_of(L0)={res['floor_of_L0']}，应为 -999"
        )
        # 每个带���心的值必须落在该带的 [下界, 上界] 内，且【低于 EMERG】——
        # 等于或高于 EMERG 就意味着 trim 恒为负、永久钉在 -TRIM
        for lv, c in res["centers"].items():
            assert c < res["emerg"], (
                f"{name}: center_of({lv})={c} >= EMERG={res['emerg']} -> "
                "w=(T-c)*GAIN 恒为负 -> trim 被永久钉在 -TRIM"
            )


def _run_pfand_helpers():
    """真的把 core/pfand 的 floor_of/center_of 抽出来，配上每套预设的参数跑一遍。

    取函数体 + 一行形参赋值（IDLE/T1../L0../EMERG），source 进子 shell，逐档调用。
    这样测的是【现役代码】，而不是测试自己重写一份算法 —— 原版的
    test_curve_presets.want() 就是重写了一份，所以改 core/pfand 它照样全绿。
    """
    import subprocess
    repo = Path(__file__).resolve().parents[2]
    src = (repo / "core" / "pfand").read_text(encoding="utf-8")
    out = {}
    for name in ("cool-quiet", "performance"):
        conf = {}
        for line in (repo / "config" / f"pfand.conf.{name}").read_text(
                encoding="utf-8").splitlines():
            m = re.match(r"^([A-Z0-9_]+)=(\d+)", line)
            if m:
                conf[m.group(1)] = m.group(2)
        body = ""
        for fn in ("floor_of", "center_of"):
            m = re.search(r"\n" + fn + r"\(\)\{(.*?)\n\}", src, re.S)
            assert m, f"core/pfand 里找不到 {fn}"
            body += f"{fn}(){{{m.group(1)}\n}}\n"
        setup = "".join(f"{k}={v}\n" for k, v in conf.items()
                        if re.match(r"^(IDLE|T[1-5]|L[0-5]|EMERG)$", k))
        script = (
            setup + body
            + 'for l in "$L0" "$L1" "$L2" "$L3" "$L4" "$L5"; do\n'
            + '  printf "F %s %s\\n" "$l" "$(floor_of "$l")"\n'
            + '  printf "C %s %s\\n" "$l" "$(center_of "$l")"\n'
            + 'done\n'
        )
        r = subprocess.run(["bash", "-c", script], capture_output=True, text=True)
        assert r.returncode == 0, f"{name}: core/pfand 片段跑不起来: {r.stderr}"
        floors, centers = {}, {}
        for line in r.stdout.splitlines():
            p = line.split()
            if len(p) == 3 and p[0] == "F":
                floors[p[1]] = int(p[2])
            elif len(p) == 3 and p[0] == "C":
                centers[p[1]] = int(p[2])
        assert floors, f"{name}: 没抓到任何 floor_of 输出"
        out[name] = (list(floors.keys()), {
            "floors": floors,
            "centers": centers,
            "emerg": int(conf["EMERG"]),
            "floor_of_L0": floors.get(conf["L0"]),
            "unhandled": [lv for lv, f in floors.items()
                          if f == int(conf["EMERG"]) and lv != conf["L5"]],
        })
    return out


def test_delivered_ordering_matches_names():
    """名字与实际交付必须一致：cool-quiet < example < performance。

    这条断言捕捉的是"配置文件改了名字之外的任何东西"都没人发现的风险。修复前：
    performance 在 68°C 交付 54%，比现役的 60% 更弱 —— 一个叫 performance 的曲线
    比什么都不换更凉快，与它的名字相反（专家审计实测）。加权均值修复后是
    29.7% / 38.9% / 49.9%，严格有序。
    """
    import subprocess
    repo = Path(__file__).resolve().parents[2]
    DIST = [45, 48, 50, 50, 50, 52, 53, 54, 55, 56, 56, 57, 58, 58, 60, 62,
            64, 66, 67, 68, 70, 73]          # 85h 实测分布（p50=50 p90=58 p99=67 max=73）
    got = {}
    for name, conf in (("example", "config/pfand.conf.example"),
                       ("cool-quiet", "config/pfand.conf.cool-quiet"),
                       ("performance", "config/pfand.conf.performance")):
        r = subprocess.run(
            ["python3", str(repo / "tests" / "fixtures" / "eval_curve_delivery.py")],
            capture_output=True, text=True, cwd=str(repo))
        assert r.returncode == 0, r.stderr
        # 只取该曲线那一行
        for line in r.stdout.splitlines():
            # 精确匹配 `name<空格>: <数字序列>` 那一行；startswith 会误抓
            # "  温度(°C): ..." 和 "56C: example=..." 这类同前缀行
            m = re.match(rf"^\s*{re.escape(name)}\s*:\s+([\d\s]+)$", line)
            if m:
                got[name] = [int(x) for x in m.group(1).split()]
        assert name in got, f"评估器没输出 {name} 那一行（stdout:\n{r.stdout}）"
    # 【不加余量】：cool-quiet 必须逐点 <= example，performance 必须逐点 >= example。
    # 试过留 5 个百分点的余量，把 performance 的 L1..L3 各降 8 点后测试仍全绿 ——
    # 余量会把"名字与行为脱钩"这个真正的缺陷重新放过去。
    for i, T in enumerate(DIST):
        assert got["cool-quiet"][i] <= got["example"][i], (
            f"{T}°C: cool-quiet 交付 {got['cool-quiet'][i]} > example "
            f"{got['example'][i]} —— 比现役更激进，名字反了")
        assert got["performance"][i] >= got["example"][i], (
            f"{T}°C: performance 交付 {got['performance'][i]} < example "
            f"{got['example'][i]} —— 比现役更弱，名字反了（修复前 68°C 就是这样）")
    # 中段（T2~T4 之间，即真正会长时间停留的区间）必须【严格】更激进，
    # 否则两条曲线的区别只在两端，整体等价于什么都没换
    mid = [i for i, T in enumerate(DIST) if 56 <= T <= 70]
    assert all(got["performance"][i] > got["example"][i] for i in mid), (
        "performance 在中段（56~70°C）没有逐点严格高于 example —— "
        "两条曲线只在端点有别，日常使用区间没有区别")
    assert all(got["cool-quiet"][i] < got["example"][i] for i in mid), (
        "cool-quiet 在中段没有逐点严格低于 example —— 同上")
