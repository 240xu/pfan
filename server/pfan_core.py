"""纯函数与常量：曲线参数校验、RPM 估算、档位/转速表。

抽出的目的：这些逻辑没有 IO（不碰 ACPI、不碰数据库、不碰 DOM），
可以被 pytest 直接导入验证，而不用起服务或插硬件。
pfanel.py 从这里导入 —— 表只有一份，避免两边漂移。
"""

# 档位白名单（表内步进）。注意：固件实际支持 1..120 任意整数，
# 这里只是 _FPS 表的键集合，用于把 EC 字节对齐到最近的已知档。
LEVELS = [0, 25, 30, 40, 50, 60, 70, 80, 85, 90, 95, 100]

# INT3404 state* 表: 档位% -> (rpm, noise_mdB, power_mW)
FPS = {25: (3200, 12500, 1250), 30: (3800, 15000, 1500), 40: (5100, 20000, 2000),
       50: (6300, 25000, 2500), 60: (7400, 30000, 3000), 70: (9300, 35000, 3500),
       80: (9800, 40000, 4000), 85: (10500, 42500, 4250), 90: (11200, 45000, 4500),
       95: (11600, 47500, 4750), 100: (12000, 50000, 5000)}

RPM_MAX = max(v[0] for v in FPS.values())   # 12000 —— backlog ⑪ 的上限
L0_MIN = 25                                  # _FPS 表最低档 —— backlog ⑩ 的下限

# 校验必需的全部键（缺一个就返回 400 而不是 500，见 2026-10-05 审计）
NEED = ("IDLE", "L0", "T1", "L1", "T2", "L2", "T3", "L3", "T4", "L4", "T5", "L5",
        "EMERG", "E", "EMERG_REL", "CAP", "TRIM", "GAIN", "HYST", "DWELL", "DEAD", "IV")


def validate_params(d):
    """严格校验：温度严格递增、档位在 [L0, CAP]、应急阈值自洽、边界参数在范围内。

    返回错误列表；空列表表示通过。纯函数，不做任何 IO。
    """
    errs = []
    miss = [k for k in NEED if k not in d]
    if miss:
        return ["缺少参数: " + ",".join(miss)]

    temps = [d["IDLE"], d["T1"], d["T2"], d["T3"], d["T4"], d["T5"], d["EMERG"]]
    for a, b in zip(temps, temps[1:]):
        if b <= a:
            errs.append("温度必须严格递增: %s" % temps)
            break

    if d["EMERG_REL"] >= d["EMERG"]:
        errs.append("EMERG_REL(%d) 必须小于 EMERG(%d)" % (d["EMERG_REL"], d["EMERG"]))

    lv = [d["L0"], d["L1"], d["L2"], d["L3"], d["L4"], d["L5"]]
    # backlog ⑩：L0 是曲线最低档。之前只查 x<0，于是 L0=0 能通过校验，
    # 但面板 set_level 已经把 0 钳到 1、且实测 _FSL 0 = 风扇停转 —— 两者互相矛盾。
    if d["L0"] < L0_MIN:
        errs.append("L0(%d) 必须 >= %d（_FPS 表最低档；0 = 风扇停转）" % (d["L0"], L0_MIN))
    for x in lv:
        if x < 0 or x > d["CAP"]:
            errs.append("档位 %d 超出 [0,%d]" % (x, d["CAP"]))
            break

    # 应急档 E 必须【高于】日常硬上限 CAP，相等也不行 —— 「应急」与日常上限无差别
    # 等于没有应急。这条必须与 core/pfand 的自检逐字一致：两边不一致时最糟的形态
    # 不是面板报错，而是面板接受并持久化、守护随后拒绝启动（core/pfand 记不自洽、
    # 写 _FSL 1 100 并退出）—— 操作员看到面板说 OK，风扇却满速且没有控制环。
    if d["E"] <= d["CAP"]:
        errs.append("应急档 E(%d) 必须大于 CAP(%d)（相等也不行：应急等于日常上限就不是应急）"
                    % (d["E"], d["CAP"]))
    if d["IV"] < 2:
        errs.append("IV 采样间隔至少 2s")
    if d["DWELL"] < d["IV"]:
        errs.append("DWELL 驻留不应小于 IV")
    if d["TRIM"] < 0 or d["TRIM"] > 30:
        errs.append("TRIM 需在 0~30")
    if d["GAIN"] < 0 or d["GAIN"] > 10:
        errs.append("GAIN 需在 0~10")
    return errs


def nearest_fps(level):
    """档位 -> (rpm, noise_mdB, power_mW)，表外档位吸附到最近的键。

    ②⑥ 修的就是这里：旧实现是 `FPS.get(lvl)`，档位 42/85/95 这种不在表里的值
    直接返回 None，面板的 RPM/噪音列就变空；而 _FSL 允许 1..120 任意整数，
    所以"表外"才是常态而不是异常。
    """
    if level is None or not FPS:
        return None
    key = min(FPS, key=lambda k: abs(k - level))
    return FPS[key]


def est_rpm(byte1):
    """把 EC 状态字节换算成近似 RPM（对齐 _FPS 表），结果封顶在表最大值。

    byte1 为 EC 0x76 的实际百分比；越界输入（>100）不得放大成虚假的高转速。
    """
    if byte1 is None or byte1 < 1:
        return None
    p = min(LEVELS, key=lambda l: abs(l - byte1))
    rpm = FPS.get(p, (3200,))[0]
    return min(int(rpm * byte1 / max(p, 1)), RPM_MAX)
