import os, sys
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
