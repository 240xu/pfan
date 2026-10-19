#!/usr/bin/env python3
"""pfanel - 松下 CFQV8 风扇监控与控制服务
从 ACPI 读取温度/风扇状态，写入 _FSL 控制档位，历史存 SQLite。
被 pfanpanel(前端)调用；也提供 HTTP JSON 接口。
"""

import fcntl
import http.server
import json
import os
import re
import socketserver
import sqlite3
import stat
import subprocess
import sys as _sys
import threading
import time

# 平台路径全部来自 platform.conf（与 core/platform.sh 同一份文件）。
# 硬编码本机路径会让别的机型完全读不到温度 —— 见 docs/specs 的 §2。
from pfan_core import (  # noqa: F401 (FPS/LEVELS 供 API 用)
    FPS,
    L0_MIN,
    LEVELS,
    est_rpm,
    nearest_fps,
    validate_params,
)
from pfan_platform import load as _plat_load

try:
    _PLAT = _plat_load()
except OSError as _e:
    # 不做 example 回退：example 的热区/ACPI 路径未必属于本机，
    # 拿它跑起来会【按错误的温度源驱动风扇】—— 比起不来更糟。
    # 快速失败 + 可操作的提示（不打 traceback），systemd 会按 Restart=always 重试。
    print(
        f"pfanel: 读不到平台配置 ({_e}) —— 请执行: pfan detect --write /etc/pfan/platform.conf",
        file=_sys.stderr,
        flush=True,
    )
    raise SystemExit(1) from None

EC = _PLAT["EC_ROOT"]  # EC 根，形如 _SB.<bus>.LPCB.EC0
FAN = _PLAT["FAN_DEVICE"]  # 风扇设备；可能与 EC 不同子树（见候选清单）
FST = FAN + "._FST"
FSL = FAN + "._FSL"
EC88 = EC + ".EC88"
TZ = _PLAT["THERMAL_ZONE"]
DEV = os.environ.get("PFAN_DEV", "") or _PLAT.get("DEV", "/dev/pfanctl")
# 与 pfand/pfan 同名接缝：设置后优先于平台配置（测试用假设备）
DB = os.environ.get("PFAN_DB", "/var/lib/pfanel/pfanel.db")
# LEVELS 已迁至 pfan_core（表只有一份）

# --- 风扇曲线（EC 0x79）: 只在 _FSL=0（交回曲线）时生效 ---
CURVES = {
    "auto": None,  # 不动 0x79，交给固件/守护
    "cool": 0x00,  # 固件性能曲线
    "s0i3": 0x02,  # 中间档
    "quiet": 0x05,  # 固件静音曲线（社区实测 ~74°C 且震荡）
    "free": None,  # 自由模式：停守护，档位完全由用户定（仍需 s0i3 才生效）
}
# 静态面板目录（部署路径，非硬件平台路径）。可用 PFAN_PANEL_DIR 覆盖以便测试/迁移。
PANEL_DIR = os.environ.get(
    "PFAN_PANEL_DIR", _PLAT.get("PANEL_DIR", "/opt/beszel/beszel_data")
)
# 随仓库一起部署的第三方资产（uPlot ESM + CSS）。
# 面板过去从 cdn.jsdelivr.net 拉图表库：目标机是 LAN 设备，可能根本没有出口，
# 那时 charts 会静默缺席而页面其余部分照常工作 —— 极难归因的"半坏"状态。
VENDOR_DIR = os.environ.get("PFAN_VENDOR_DIR", os.path.join(PANEL_DIR, "vendor"))
CURVE_FILE = os.environ.get("PFAN_CURVE_FILE", "/var/lib/pfanel/curve.state")
GUARD_TEMP = 82  # 看门狗阈值：quiet 下超过此温度自动回退（TjMax=100）
# 交回控制权（_FSL 1 0）之后、读 EC 0x76 之前必须等的稳态时间。
# 固件接管曲线不是瞬时的，读太快会拿到【切换前】的转速。
# auto 分支与 _daemon_ready 必须同一口径 —— 两处各写一个 1.6 就是两份事实源，
# 而它们判的是同一件事（交回有没有生效），所以取常量。
HANDOVER_SETTLE_S = 1.6
# 回落下限：直接取 pfan_core.L0_MIN（即 _FPS 表最低档，min(FPS)，表只有一份，
# 定义在 pfan_core.py:13 附近），【不】在本文件再抄一份字面量。
# 它是 set_curve("auto") 交回失败、set_curve 的 quiet/cool 回滚交回失败、
# 以及 apply_persisted_state 还原出不可用档位时，三处共用的兜底档位。
# 0 在 ACPI 里的含义是停转，不是"最低档"。
MIN_SAFE_LEVEL = L0_MIN


def get_state():
    """持久化状态 {curve, level}，重启后据此还原"""
    try:
        import json as _j

        d = _j.loads(open(CURVE_FILE).read())
        return {"curve": d.get("curve", "auto"), "level": d.get("level", 0)}
    except Exception:
        return {"curve": "auto", "level": 0}


def save_state(curve=None, level=None):
    d = get_state()
    if curve is not None:
        d["curve"] = curve
    if level is not None:
        d["level"] = level
    os.makedirs(os.path.dirname(CURVE_FILE), exist_ok=True)
    import json as _j

    open(CURVE_FILE, "w").write(_j.dumps(d))
    return d


def get_curve():
    return get_state()["curve"]


def _daemon_ready(timeout_s=5, interval=1, settle=HANDOVER_SETTLE_S):
    """守护是不是真的接管了（s0i3 分支的判据）。

    两个条件必须【同时】成立：
      ① systemctl is-active pfand == active
      ② get_ec76() 在设备上读到非零档位

    只查 ① 不够。守护可能活着却正卡在 ensure_s0i3() 的握手窗口里
    （core/pfand: ensure_s0i3 先写 _FSL 1 0 再写 EC88），而那个窗口内 _FSL 就是 0
    —— 本项目反复踩到的就是它。那种情况下 ① 为真、风扇却转不起来，
    判成"就绪"等于没检查。

    ② 用 get_ec76() 而不是 get_level()：get_ec76 读 EC 0x76 = 实际转速百分比，
    与 set_curve("auto") 分支判定"交回是否生效"用的是同一个判据（该分支的
    `if not ec: acpi(FSL, "1 %d" % MIN_SAFE_LEVEL)` 兜底），两处保持同一套读法；
    get_level() 读的是 _FST 里的存档档位，守护没起来时
    旧值照样非零，根本测不出这次切换有没有生效。
    正常守护的档位下限就是 MIN_SAFE_LEVEL（L0/E/CAP 全部 >= L0_MIN），
    所以 ② 不会因为"风扇本来就该慢"而误判。

    ③ 第一读之前必须先等稳（settle）。这个函数是在 `acpi(FSL,"1 0") +
    acpi(EC88, s0i3)` 之后约 0.5s 就被调用的，此刻 EC 0x76 报的仍是切换前的转速。
    守护真在跑（① active）而 _FSL 还是 0 时，立刻读到非零就判成"就绪"——
    读数比判据早了，风扇比判据慢。auto 分支早就为同一件事等过 1.6s（同一个常量）；
    这条判据当时没等。落地证据：pfanel.db 的 39570 个采样里有 3200 个 ec76 != level，
    且全部偏向"风扇还在动"（命令 25 / 实测 44）—— 读早了就读到这个偏差。

    预算口径（延迟不许换来更宽松的判据）：
      · settle 睡在 deadline【之内】：deadline 在 sleep 之前就算好，所以 settle
        确实从轮询窗口里扣 —— 轮询次数从 ~5 降到 ~4，判据只会更严。
      · 循环写成 do-while 而不是 `while now < deadline`：若 settle >= timeout_s，
        后者会【一次都不试】就返回 False。那不是"未就绪"，那是"没检查"，
        而调用方会把两者当成同一件事。现在任何 timeout_s 下都至少做一次真实尝试。
      · 剩余时间留不下一整次轮询就不睡（now + interval >= deadline 直接返回），
        免得再睡一轮才发现预算早就用完。
      · ⚠ 上限是 timeout_s 【加一次尝试】，不是 timeout_s。这两句别混：
        deadline 拦得住"什么时候开始下一次尝试"，拦不住"已经发出去的那一次
        要多久才回来"。一次尝试的上界 = systemctl 的 timeout=5，加上 get_ec76()
        里 acpi() 的 20×0.12s 轮询（约 2.4s，外加 21 次 dmesg 子进程），而且两者
        是【顺序】的（systemctl 说 active 才读 EC）。默认参数下整次调用的最坏
        上界约 1.6 + 5 + 2.4 ≈ 9s，对着一个名义上的 5s 预算。
        超支只会发生【一次】：拖过 deadline 的那次尝试自己就把循环送出去了，
        所以这是有界超支，不是无界增长。
        典型值远低于上界（systemctl ~6ms + acpi 0.12~0.24s 一轮 → 约 4.1s 返回）。
        调用方需要知道这个上界：set_curve("s0i3") 最坏 ≈9s，叠加回滚用的
        set_curve("cool") 与写接口自己的 time.sleep(2)，一次曲线切换请求最坏
        约 13s。方向是安全的（超了只会多等，不会更早判就绪）。

    刻意不调 daemon_alive()：它有 5s 缓存，而守护状态恰好刚被 restart 改动，
    拿缓存当判据会把"没起来"读成"起来了"。
    """
    deadline = time.time() + timeout_s
    time.sleep(settle)
    while True:
        try:
            st = subprocess.run(
                ["systemctl", "is-active", "pfand"],
                capture_output=True,
                text=True,
                timeout=5,
            )
            if (st.stdout or "").strip() == "active":
                if get_ec76():
                    return True
        except Exception:
            pass
        now = time.time()
        if now >= deadline or now + interval >= deadline:
            return False
        time.sleep(interval)


def _force_min_safe_level(note):
    """把 _FSL 直接写成不会停转的下限，并尽力如实记录。

    这个函数【不许抛】。它是最后一道：设备锁坏了、日志目录不可写，都只是少一条线索；
    反过来一旦抛出去，风扇就留在 _FSL 0 上，而且没有任何记录说明发生过什么 ——
    那正是这个仓库反复吃过亏的形态。

    返回写入是否被设备确认（acpi() 拿到本次调用自己的 RESULT 行才算数）。
    日志里如实写"已确认/未确认"，不把没确认的写入记成已完成。
    """
    confirmed = False
    try:
        confirmed = acpi(FSL, "1 %d" % MIN_SAFE_LEVEL) is not None
    except Exception:
        confirmed = False
    try:
        with open("/var/log/pfanel.log", "a") as f:
            f.write(
                "%s %s -> 直接写 _FSL 1 %d（设备%s）\n"
                % (
                    time.strftime("%Y-%m-%d %H:%M:%S"),
                    note,
                    MIN_SAFE_LEVEL,
                    "已确认" if confirmed else "未确认",
                )
            )
    except Exception:
        pass
    return confirmed


def set_curve(name):
    """切曲线。quiet/s0i3/cool 都需要先 _FSL=0 交回控制权。"""
    if name not in CURVES:
        raise ValueError("unknown curve: %s" % name)
    val = CURVES[name]
    if name == "auto":
        # 交回固件曲线。顺序很关键（2026-10-06 实测）：
        #   s0i3 + _FSL 0 → EC=0%（**停转**）
        #   cool  + _FSL 0 → EC=58%（固件接管，安全）
        # 所以必须【先切 cool 再交回】，且交回后校验 EC 非零，不足则兜底。
        acpi(EC88, "4 181 0x79 0x00 0")
        acpi(FSL, "1 0")
        time.sleep(HANDOVER_SETTLE_S)
        ec = get_ec76()
        if not ec:  # 交回没生效 → 绝不留停转
            # 兜底档位取 MIN_SAFE_LEVEL（= pfan_core.L0_MIN），不写死 25：
            # 同一个数、同一个意图，抄一份就多一处会漂移的副本。
            acpi(FSL, "1 %d" % MIN_SAFE_LEVEL)
            ec = MIN_SAFE_LEVEL
            with open("/var/log/pfanel.log", "a") as f:
                f.write(
                    "%s auto: _FSL 0 未交回成功(EC=%s)，已兜底 %d%%\n"
                    % (time.strftime("%Y-%m-%d %H:%M:%S"), ec, MIN_SAFE_LEVEL)
                )
        subprocess.run(["systemctl", "stop", "pfand"], capture_output=True)
    elif name == "free":
        # 自由模式：s0i3（让 EC 跟随设定值）+ 停守护，档位由用户面板直接控制。
        # 【2026-10-17 修】起点写【当前档位】而不是 _FSL 1 0：_FSL 0 在 s0i3 下
        # 就是停转，而本分支一停守护就没人再把档位拉回来（F2 的活体孪生）。
        # 与 core/pfand 的 ensure_s0i3 同一手法：读不到/低于下限一律退到
        # MIN_SAFE_LEVEL —— 两处必须一致，否则就是同一个数出现两份事实源。
        keep = get_level()
        if keep is None or keep < MIN_SAFE_LEVEL:
            keep = MIN_SAFE_LEVEL
        subprocess.run(["systemctl", "stop", "pfand"], capture_output=True)
        acpi(FSL, "1 %d" % keep)
        acpi(EC88, "4 181 0x79 0x%02X 0" % CURVES["s0i3"])
        # 交回后置条件，与 quiet/cool 同一口径（等稳 → 读 EC 0x76 → 为 0 或
        # 读不到就兜底 MIN_SAFE_LEVEL）。free 的 EC 语义就是 s0i3：EC 跟随
        # _FSL，上面那次写没落进 EC 时风扇同样会停，而 free 在 GUARDED 里
        # 只能靠 82°C 兜底 —— 不能把"已经停下"留给看门狗去发现。
        time.sleep(HANDOVER_SETTLE_S)
        ec = get_ec76()
        if not ec:
            _force_min_safe_level("free: 档位未落到设备(EC=%s)" % (ec,))
    elif name == "s0i3":
        # s0i3 = 曲线本体模式：释放设定值让 EC 完全跟随，然后由 pfand 施加自定义曲线。
        # 必须【启动】守护 —— pfand 自己会 ensure_s0i3() 并按温度调档。
        acpi(FSL, "1 0")
        acpi(EC88, "4 181 0x79 0x%02X 0" % val)
        # 旧实现丢弃 systemctl 的退出码就往下走，于是守护没起来（模块没加载、
        # 节点缺失、配置自检 fail-safe 直接 exit）时照样返回 ok 并持久化 s0i3 ——
        # 之后每次 pfanel 重启（含每次 deploy.sh）都重放同一个坏状态。
        # 这两步刚把 _FSL 留在 0 上，守护不来就等于把风扇停在 0，所以必须验。
        # 预持久化必须在 restart 【之前】（2026-10-17）：pfand 启动时读
        # curve.state，读到的不是 s0i3 就直接 exit 0 —— 旧顺序（先重启后
        # save_state）让守护读到旧曲线，新门禁把它当成"没起来"回滚到 cool，
        # 而回滚又把 cool 持久化，s0i3 从此永久不可达（每次尝试还伴随
        # 5-9s 命令性停转）。失败路径由回滚的 set_curve("cool") 自己改回 cool。
        save_state(curve=name)
        subprocess.run(["systemctl", "restart", "pfand"], capture_output=True)
        if not _daemon_ready():
            # ① 救风扇优先：回滚本身【不许】成为那条会失败的路径。
            # 旧实现是裸的 `rolled = set_curve("cool")`，而 acpi() 在设备锁/权限故障下
            # 会抛 —— 异常穿过 set_curve("cool") 出去，回滚半途而废、_FSL 还停在 0 上，
            # 而且一条日志都没有（下面那个 except OSError 防的正是"日志失败顶掉回滚"，
            # 它保护了日志，却没保护回滚本身）。
            try:
                rolled = set_curve("cool")  # cool 下固件接管，_FSL 0 不会停转
            except Exception as e:
                # 回滚抛了也不能就这么走：直接把 _FSL 写成不会停转的下限。
                # 返回值标成未完成而不是谎称已回滚 —— 事后没人能核对的谎比异常更难查。
                _force_min_safe_level("cool 回滚未完成(%s)" % (e,))
                rolled = "cool(回滚未完成)"
            try:
                with open("/var/log/pfanel.log", "a") as f:
                    f.write(
                        "%s s0i3 拉起 pfand 失败（守护未就绪或设备读回档位 0），回滚结果：%s\n"
                        % (time.strftime("%Y-%m-%d %H:%M:%S"), rolled)
                    )
            except OSError:
                pass
            # 提前 return：上面预持久化过 s0i3，而回滚已经把 curve.state 写回
            # cool —— 不许再落到下面那行 save_state(curve=name)，否则 cool 又
            # 被覆盖成 s0i3，"s0i3 不可达"的回归就原样复活。
            return rolled
    else:
        # quiet / cool：固件自己的曲线接管，必须停守护
        # （守护写 _FSL 会让 EC 忽略 0x79，曲线就失效了）
        subprocess.run(["systemctl", "stop", "pfand"], capture_output=True)
        acpi(FSL, "1 0")
        acpi(EC88, "4 181 0x79 0x%02X 0" % val)
        # 交回后置条件：上面这两行只把 _FSL 留在 0 上就返回了，全程没有验证
        # EC 有没有真的接管。cool/quiet 是【固件】曲线，_FSL 0 在固件手里【相信】是
        # 安全的 —— 但这一分支同时是 s0i3 拉起守护失败后的自动安全网，那条路上
        # "固件接管"从未被验证过。于是一次没验证的操作成了承重结构：
        # EC 写不进去（楔住的 EC，与守护起不来同一故障类）时，EC 仍停在 s0i3、
        # _FSL 停在 0、风扇停转，而 cool 不在 GUARDED 里，没有任何东西在看它。
        # 判据与 auto 分支完全一致：读回非零才算交回成功；读不出来（None）
        # 与读到 0 同类 —— 读不出来时无法排除停转，必须按最坏情况兜底。
        #
        # 【2026-10-11 更正】这一段原本写着"刻意不抄 auto 分支那 1.6s：quiet/cool
        # 是用户主动切的健康路径，写接口本来就已经 sleep 2s，再加 1.6s 是纯延迟"。
        # 那条理由是假的：写接口的 time.sleep(2) 在 do_POST 里 set_curve()【返回
        # 之后】才执行，而上面这句读发生在完全没等稳的条件下 —— 正是终审
        # Important 2 针对的那一种。而"用户主动切"也不等于"读得早就无害"：
        # 从 s0i3 直接切 cool/quiet 时，楔住的 EC 会让 0x79 曲线写不进去，
        # EC 仍停在 s0i3、_FSL 停在 0（= 停转），而过早的一次读拿到的是
        # 【切换前】的非零转速，判据于是判成"交回成功"、兜底不写 ——
        # 恰好是这个分支存在要拦的那种停转。auto 分支那 1.6s 就是为它等的。
        # 所以修的是【延迟】而不是只改注释：等稳与 auto 分支共用同一个
        # HANDOVER_SETTLE_S，两处读法与等待重新变成同一口径。
        # 代价：quiet/cool 的 set_curve 多 1.6s。写接口本来就有那 2s，所以一次
        # 曲线切换请求从 ~2.3s 变成 ~3.9s；s0i3 回滚那条路也多 1.6s，那是安全
        # 路径，延迟无所谓。方向是严的：读得越晚，越不容易把"还没接管"误判成
        # "已接管"；代价最多是一次多余的安全写入（降成 MIN_SAFE_LEVEL）。
        time.sleep(HANDOVER_SETTLE_S)
        ec = get_ec76()
        if not ec:
            _force_min_safe_level("%s: _FSL 0 未交回成功(EC=%s)" % (name, ec))
    save_state(curve=name)
    return name


# 需要看门狗的曲线：quiet 会让温度飙高；s0i3 更危险——固件热保护直接失效，
# EC 完全听设定值，无任何下限。两者都必须由我们兜底。
# quiet 让温度飙高；s0i3/free 让固件退出热保护 —— free 最危险
# （s0i3 的 EC 地板 + 一个自己的守护），原来刻意排除 free 是错的，一并纳入。
GUARDED = ("quiet", "s0i3", "free")


def guard():
    """看门狗：受管曲线下温度失控 → 自动回退到安全自动模式。
    GUARDED 含 free —— 自由模式【同样】被接管（曾有文案说 free 不看门狗，
    与 GUARDED 矛盾；代码为准：free 下没人管实测会拉到 ~74°C）。"""
    cv = get_curve()
    if cv not in GUARDED:
        return None
    t = get_temp()
    if t is None or t < GUARD_TEMP:
        return None
    set_curve("auto")
    try:
        log_event("guard", "看门狗触发：%.1fC >= %dC，自动回退" % (t, GUARD_TEMP))
        with open("/var/log/pfanel.log", "a") as f:
            f.write(
                "%s GUARD 温度 %.1fC >= %dC，quiet 曲线已自动回退\n"
                % (time.strftime("%Y-%m-%d %H:%M:%S"), t, GUARD_TEMP)
            )
    except Exception:
        pass
    return t


# INT3404 state* 表: 档位% -> (rpm_min, noise_mdB, power_mW)
# FPS 已迁至 pfan_core（表只有一份）


def _result_state():
    """返回 (最后一行 RESULT 的值, 该行的内核时间戳)。

    用时间戳而非行数判定「新结果」：dmesg 是环形缓冲，行被不断淘汰，
    绝对行数会在 2064→2063 这样下降，导致永远等不到"增长"（2026-10-05 实测）。
    内核时间戳严格单调，且三方共锁后不会被别人的结果污染。"""
    # 与 pfand 同名接缝：缺省 dmesg（生产），测试可指向 fake/bin/dmesg。
    # 不这么做的话每次 acpi() 都要等满 20×0.12s 轮询，HTTP 测试会超时。
    out = subprocess.run(
        [os.environ.get("PFAN_DMESG", "dmesg")], capture_output=True, text=True
    ).stdout
    last, ts = None, -1.0
    for line in out.splitlines():
        if "pfanctl: RESULT" in line:
            try:
                ts = float(line[1 : line.index("]")])  # [45623.012609] ...
            except Exception:
                ts = -1.0
            last = line.split("RESULT", 1)[1].strip()
    return last, ts


def _dev_writable():
    """写设备前的唯一前提，语义与 core/pfand 的 dev_ok 一致：
    生产路径（PFAN_DEV 未设）必须是【字符设备】；PFAN_DEV 是测试接缝（假设备是
    普通文件），显式设置时只查存在性。
    缺节点时 `open(DEV, "w")` 会把普通文件【凭空创建】出来 —— 之后 devtmpfs/insmod
    因 EEXIST 复建不了节点，而调用方还当成写成功了（2026-10-06 事故形态，I2）。"""
    if os.environ.get("PFAN_DEV"):
        return os.path.exists(DEV)
    try:
        return stat.S_ISCHR(os.stat(DEV).st_mode)
    except OSError:
        return False


def _log_dev_hazard():
    why = "存在但不是字符设备" if os.path.exists(DEV) else "节点缺失（多为 rmmod 之后）"
    msg = (
        "CRITICAL: %s %s —— 拒绝写入：open(DEV,'w') 只会造出/写进一个普通文件，"
        "风扇档位到不了硬件，且该文件会让 devtmpfs/insmod 因 EEXIST 复建不了节点。"
        "恢复: insmod /opt/pfanctl/pfanctl.ko（或 systemctl restart pfanctl）；"
        "不要手工创建 %s\n" % (DEV, why, DEV)
    )
    try:
        with open("/var/log/pfanel.log", "a") as fh:
            fh.write("%s %s" % (time.strftime("%Y-%m-%d %H:%M:%S"), msg))
    except OSError:
        print("pfanel: %s" % msg.strip(), file=_sys.stderr, flush=True)


def acpi(path, args=""):
    """调 pfanctl，返回**本次调用自己的** RESULT 行。
    ① 设备守卫（I2）：不是字符设备（或节点缺失）就一行都不写 —— 否则
       open(DEV,'w') 自己把 I6 要防的那个假节点造出来。点名危害后返回 None。
    ② 文件锁：/dev/pfanctl 是单槽设备，pfand/pfan 也用同一把锁（见 pfand 的 flock）。
    ③ 行数增长判定：只有 RESULT 总数超过写入前的数量才算拿到新结果；
       超时返回 None（而不是旧值），避免把 10 秒前的读数当成本次结果。"""
    if not _dev_writable():
        _log_dev_hazard()
        return None
    cmd = f"{path} {args}".strip()
    lockf = os.environ.get(
        "PFAN_LOCK",
        "/run/pfanel.lock",  # 与 pfand/pfan 同一把锁、同名接缝
    )
    with open(lockf, "w") as lk:
        fcntl.flock(lk, fcntl.LOCK_EX)
        _, before = _result_state()
        with open(DEV, "w") as f:
            f.write(cmd)
        for _ in range(20):
            time.sleep(0.12)
            last, ts = _result_state()
            if ts > before and last is not None:
                return last
    return None


def read_pkg(s):
    if not s:
        return None
    try:
        return [int(x) for x in s.strip("[] ").split(",")]
    except Exception:
        return None


def get_temp():
    try:
        return round(int(open(TZ).read().strip()) / 1000.0, 1)
    except Exception:
        return None


def get_level():
    """当前设定档位 (PEN1)"""
    p = read_pkg(acpi(FST))
    return p[1] if p and len(p) >= 2 else None


def set_level(v):
    """固件 fine_grain_control=1，实测 0~120 任意整数都精确接受（2026-10-05）。
    旧的 LEVELS 白名单是多余的，早先误以为是固件限制 —— 实际那是我自己工具的钳制。
    这里只做安全边界收敛，不再吸附到 _FPS 档位。"""
    v = int(v)
    # 2026-10-06 实测：_FSL 0 在 s0i3 下 = **风扇停转**（不是"交回曲线"），
    # 因此 API 不允许设 0。交回走 set_curve("auto")（先切 cool 再校验 EC 非零）。
    if v < 1:
        v = 1
    if v > 120:
        v = 120
    acpi(FSL, f"1 {v}")
    return v


def get_ec76():
    """EC 0x76 实时风扇状态字节（byte1）= 当前实际转速百分比"""
    r = acpi(EC88, "4 181 118 0 0")
    if not r:
        return None
    try:
        v = int(r.split()[0])
        if v >= 0xFFFFFFFF:
            return None
        return (v >> 8) & 0xFF
    except Exception:
        return None


# est_rpm 已迁至 pfan_core


def db():
    os.makedirs(os.path.dirname(DB), exist_ok=True)
    c = sqlite3.connect(DB, timeout=10)
    c.execute("""CREATE TABLE IF NOT EXISTS samples(
        ts INTEGER PRIMARY KEY, temp REAL, level INTEGER,
        ec76 INTEGER, rpm INTEGER, gov TEXT)""")
    try:
        c.execute("ALTER TABLE samples ADD COLUMN gov TEXT")
    except Exception:
        pass
    c.execute("CREATE INDEX IF NOT EXISTS i_ts ON samples(ts)")
    c.commit()
    return c


_lock = threading.Lock()
# 采集缓存：/api/now 直接返回缓存，避免每次请求都现场读 ACPI。
# 现场读每次 ~170ms（flock + 轮询 sleep），而采集器本来就每 10s 采一次。
_cache = {"snap": None, "at": 0, "daemon": False, "daemon_at": 0}


def daemon_alive(max_age=5):
    """systemctl 子进程约 6ms，缓存 5s 足够（守护状态变化由 set_curve 主动刷新）"""
    if time.time() - _cache["daemon_at"] < max_age:
        return _cache["daemon"]
    try:
        r = subprocess.run(
            ["systemctl", "is-active", "pfand"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        _cache["daemon"] = r.stdout.strip() == "active"
    except Exception:
        _cache["daemon"] = False
    _cache["daemon_at"] = time.time()
    return _cache["daemon"]


def snapshot(live=True):
    """live=True 现场读 ACPI（用于设档后立即确认，约 350ms）；
    live=False 返回采集器缓存（用于 API 查询，<1ms）"""
    if not live:
        c = _cache["snap"]
        if c is not None:
            return dict(c, cached=True, age=round(time.time() - _cache["at"], 1))
    lvl = get_level()
    ec = get_ec76()
    snap = {
        "ts": int(time.time()),
        "temp": get_temp(),
        "level": lvl,
        "ec76": ec,
        "rpm": est_rpm(ec),
        "mode": "daemon" if daemon_alive() else "manual",
        "curve": get_curve(),
        "gov": (
            "curve"
            if (get_curve() == "s0i3" and daemon_alive())
            else get_curve()
            if get_curve() != "auto"
            else "daemon"
            if daemon_alive()
            else "manual"
        ),
        "fps": nearest_fps(lvl) if lvl else None,
    }
    snap["cached"] = False
    snap["age"] = 0
    return snap


_APPLIED = False


def apply_persisted_state():
    """pfanel 启动时还原上次选的曲线+档位（覆盖系统重启与 pfanel 重启）"""
    global _APPLIED
    if _APPLIED:
        return
    _APPLIED = True
    st = get_state()
    if st["curve"] == "auto":
        return
    try:
        # s0i3 分支不还原档位（守护施加曲线），但下面的日志仍要报出存档值，
        # 所以 _lv / log_note 在两条分支之前就初始化好，不在 else 里才定义。
        _lv = st.get("level")
        log_note = ""
        # free 与 auto 在 CURVES 里映射为 None（它们不靠 EC88 写值），不能直接 0x%02X 展开。
        # free 的 EC 语义等同 s0i3（见 set_curve: free 分支复用 CURVES["s0i3"]）。
        ec_val = CURVES["s0i3"] if st["curve"] == "free" else CURVES[st["curve"]]
        # 先把 EC88 写成功，再交回控制权：反过来的话，EC88 一旦抛异常（TypeError 或设备
        # 错误），_FSL 已经停在 0 而没有任何人恢复档位 —— pfanel 每次重启（含 deploy.sh）
        # 都会复现，且 pfand 在非 s0i3 模式 exit 0 救不回来（专家审计 C2，实测）。
        acpi(EC88, "4 181 0x79 0x%02X 0" % ec_val)
        acpi(FSL, "1 0")
        if st["curve"] == "s0i3":
            # s0i3 由 pfand 施加自定义温度曲线，拉起守护（它会自己 ensure_s0i3）
            subprocess.run(["systemctl", "restart", "pfand"], capture_output=True)
        else:
            # free 与 quiet/cool 一样是【守护停着、档位由面板直接控】，
            # 所以同样要恢复已存档位（专家审计 C2：原来 free 落不到这里，
            # 异常在 EC88 展开时就抛了，档位永远不恢复）。
            subprocess.run(["systemctl", "stop", "pfand"], capture_output=True)
            # level=0 与 level 缺失都不是"有意的 0"：set_level() 把档位钳在 >=1，
            # 所以 0 永远只意味着"从没按过档位按钮"（缺省值见 get_state() 的 d.get("level", 0)）。旧实现把它当成
            # "无可恢复"，于是 free 曲线在每次 pfanel 启动（含每次 deploy.sh）之后都把
            # 风扇留在 _FSL 1 0 —— 而 s0i3 下 0 就是停转（实测，spec F2）。
            # 回落值取 MIN_SAFE_LEVEL（FPS 表最低档），并且必须真的写出去。
            # 存档里的 level 未必是整数：get_state() 原样返回 JSON 的值，而
            # 曲线文件是人手可改的文本。旧的 `not _lv or int(_lv) < 1` 对 "abc" 短路失败 ——
            # not "abc" 是 False，于是求值 int("abc") 抛 ValueError，被外层 except 吞掉，
            # 风扇停在两步之前刚写下的 _FSL 1 0：同一个"留下停转"换了条触发路径又回来了。
            # 不可用一律折成 0，与 0 同类走同一条回落。三个异常类型都要接：JSON 的
            # NaN → ValueError，±Infinity → OverflowError，None/[]/{} → TypeError。
            # bool 单独排除：它是 int 的子类，int(True)==1 会写出 1 1（几乎等于停转）。
            _lv_raw = _lv
            if isinstance(_lv, bool):
                _lv = 0
            else:
                try:
                    _lv = int(_lv)
                except (TypeError, ValueError, OverflowError):
                    _lv = 0
            if _lv < 1:
                _lv = MIN_SAFE_LEVEL
                log_note = (
                    "level 存档值 %r 不可用（缺失/非整数/负数/0）-> 回落下限 %d"
                    % (
                        _lv_raw,
                        MIN_SAFE_LEVEL,
                    )
                )
            acpi(FSL, "1 %d" % _lv)
        with open("/var/log/pfanel.log", "a") as f:
            f.write(
                "%s 还原持久化状态 curve=%s level=%s%s\n"
                % (
                    time.strftime("%Y-%m-%d %H:%M:%S"),
                    st["curve"],
                    _lv,
                    ("；" + log_note) if log_note else "",
                )
            )
    except Exception as e:
        with open("/var/log/pfanel.log", "a") as f:
            f.write("%s 还原失败 %s\n" % (time.strftime("%Y-%m-%d %H:%M:%S"), e))


def log_event(kind, msg):
    """把关键事件（曲线切换/应急/守护启动）写进 DB，供面板展示"""
    try:
        c = db()
        c.execute(
            "INSERT INTO events(ts,kind,msg) VALUES(?,?,?)",
            (int(time.time()), kind, str(msg)[:200]),
        )
        c.commit()
        c.execute("DELETE FROM events WHERE ts < ?", (int(time.time()) - 7 * 86400,))
        c.commit()
    except Exception:
        pass


def events(limit=60):
    try:
        c = db()
        rows = c.execute(
            "SELECT ts,kind,msg FROM events ORDER BY ts DESC LIMIT ?", (limit,)
        ).fetchall()
        return [{"ts": r[0], "kind": r[1], "msg": r[2]} for r in rows]
    except Exception:
        return []


TOKEN_FILE = os.environ.get("PFAN_TOKEN_FILE", "/var/lib/pfanel/token")
_tok = None


def get_token():
    """写操作的 Token。首次启动生成 0600 文件；由 _panel() 注入面板脚本。

    ⚠️ 它【不是】身份认证：_panel() 把真值替换进 app.js 的 __PFAN_TOKEN__，而
    /pfan、/pfan.js 是免鉴权 GET —— 于是任何能访问面板的客户端（跨站浏览器、curl、
    任何脚本）一次 GET 就拿到了。同源策略在这里保护不了任何东西：这个 token 是
    被【故意】放进一份公开可取的脚本里的。

    仍然成立的部分：do_POST 的 token 判定是【无条件】的（_deny + return，在 Origin
    检查之前）。Origin 白名单是另一道门、性质不同：它是【浏览器 CSRF 边界】—— 跨站
    页面必须带 Origin 而脚本伪造不了；但脚本客户端自己就能写 Origin，所以它挡不住
    curl。真正的边界是网络可达性，见 SECURITY.md「写边界究竟是什么」。
    """
    global _tok
    if _tok:
        return _tok
    try:
        _tok = open(TOKEN_FILE).read().strip()
    except Exception:
        import secrets

        os.makedirs(os.path.dirname(TOKEN_FILE), exist_ok=True)
        _tok = secrets.token_urlsafe(32)
        fd = os.open(TOKEN_FILE, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        os.write(fd, _tok.encode())
        os.close(fd)
        try:
            os.chmod(TOKEN_FILE, 0o600)
        except Exception:
            pass
    return _tok


CONF = os.environ.get("PFAN_CONF", "/etc/pfand.conf")
PARAM_KEYS = (
    "IDLE",
    "L0",
    "T1",
    "L1",
    "T2",
    "L2",
    "T3",
    "L3",
    "T4",
    "L4",
    "T5",
    "L5",
    "EMERG",
    "E",
    "EMERG_REL",
    "CAP",
    "TRIM",
    "GAIN",
    "HYST",
    "DWELL",
    "DEAD",
    "IV",
)


def read_params():
    d = {}
    try:
        for line in open(CONF):
            line = line.split("#")[0].strip()
            m = re.match(r"^([A-Z0-9_]+)\s*=\s*([0-9]+)$", line)
            if m and m.group(1) in PARAM_KEYS:
                d[m.group(1)] = int(m.group(2))
    except Exception:
        pass
    return d


# validate_params 已迁至 pfan_core


def write_params(d):
    lines = [
        "# pfand 曲线参数 —— 由面板「自定义曲线」按钮写入",
        "# 分级骨架：温度上限 -> 档位",
        "",
    ]
    for k in ("IDLE", "L0", "T1", "L1", "T2", "L2", "T3", "L3", "T4", "L4", "T5", "L5"):
        lines.append("%s=%d" % (k, d[k]))
    lines += [
        "# 应急",
        "EMERG=%d" % d["EMERG"],
        "E=%d" % d.get("E", 100),
        "EMERG_REL=%d" % d["EMERG_REL"],
        "# 上限与微调",
        "CAP=%d" % d["CAP"],
        "TRIM=%d" % d["TRIM"],
        "GAIN=%d" % d["GAIN"],
        "# 防抖",
        "HYST=%d" % d["HYST"],
        "DWELL=%d" % d["DWELL"],
        "DEAD=%d" % d["DEAD"],
        "IV=%d" % d["IV"],
        "",
    ]
    tmp = CONF + ".tmp"
    open(tmp, "w").write("\n".join(lines))
    os.chmod(tmp, 0o644)
    os.replace(tmp, CONF)  # 原子替换，pfand 不会读到半截文件
    return True


def curve_view():
    """曲线视图：数据源 = /etc/pfand.conf（面板编辑的对象）"""
    cfg = read_params()
    # ②⑧ 这里曾自带一份只到 80/100、缺 85/90/95 的 rpm 表，与 pfan_core.FPS 分歧。
    # 现在统一走 nearest_fps()：表只有一份，且表外档位也有值。
    bands = []
    if cfg:
        seq = [(cfg.get("IDLE"), cfg.get("L0"))]
        for i in range(1, 6):
            seq.append((cfg.get("T%d" % i), cfg.get("L%d" % i)))
        if cfg.get("EMERG") is not None:
            seq.append((cfg["EMERG"], cfg.get("E", 100)))
        for up, lvl in seq:
            if up is None or lvl is None:
                continue
            _f = nearest_fps(lvl)
            bands.append(
                {
                    "upto": up,
                    "level": lvl,
                    "rpm": _f[0] if _f else int(lvl * 120),
                    "db": round(_f[1] / 1000.0, 1) if _f else round(lvl * 0.5, 1),
                    "emerg": lvl == cfg.get("E", 100),
                }
            )
    return {"params": cfg, "bands": bands, "curve": get_curve()}


def collector():
    c = db()
    while True:
        try:
            apply_persisted_state()
            guard()  # 温度失控自动回退（quiet/s0i3 才有风险）
            s = snapshot()
            _cache["snap"] = s
            _cache["at"] = time.time()
            _cache["daemon_at"] = 0  # 顺带刷新守护状态
            with _lock:
                c.execute(
                    "INSERT OR REPLACE INTO samples(ts,temp,level,ec76,rpm,gov)"
                    " VALUES(?,?,?,?,?,?)",
                    (s["ts"], s["temp"], s["level"], s["ec76"], s["rpm"], s.get("gov")),
                )
                c.commit()
                # 只留 7 天
                c.execute(
                    "DELETE FROM samples WHERE ts < ?", (int(time.time()) - 7 * 86400,)
                )
                c.commit()
        except Exception:
            pass
        time.sleep(10)


def history(hours=24, limit=2000, curve_only=False):
    c = db()
    since = int(time.time()) - hours * 3600
    if curve_only:
        rows = c.execute(
            "SELECT ts,temp,level,ec76,rpm FROM samples "
            "WHERE ts>=? AND gov='curve' AND level>0 AND level<=100 "
            "ORDER BY ts DESC LIMIT ?",
            (since, limit),
        ).fetchall()
    else:
        rows = c.execute(
            "SELECT ts,temp,level,ec76,rpm FROM samples WHERE ts>=? "
            "ORDER BY ts DESC LIMIT ?",
            (since, limit),
        ).fetchall()
    return [
        {"ts": r[0], "temp": r[1], "level": r[2], "ec76": r[3], "rpm": r[4]}
        for r in reversed(rows)
    ]


# ②⑤ 写接口的 CSRF 白名单 —— 可配置，不再是源码里的硬编码常量。
# 缺省值是发布用的占位值（example 域名 + RFC1918 示例地址）；
# tests/python/test_http.py 会断言缺省字面量，改配置走 PFAN_ORIGIN_ALLOW 环境变量。
DEFAULT_ORIGINS = "pfan.example.com,127.0.0.1,localhost,192.168.1.10"


def origin_allowed(origin, allow=None):
    """Origin 是否在白名单里（写接口的 CSRF 门）。

    allow 可注入，便于测试白名单本身；不传则读 PFAN_ORIGIN_ALLOW（逗号分隔）。
    """
    if not origin:
        return False
    if allow is None:
        allow = [
            x.strip()
            for x in os.environ.get("PFAN_ORIGIN_ALLOW", DEFAULT_ORIGINS).split(",")
            if x.strip()
        ]
    try:
        from urllib.parse import urlparse

        host = (urlparse(origin).hostname or "").lower()
    except Exception:
        return False
    return host in allow


class H(http.server.BaseHTTPRequestHandler):
    def _panel(self, name):
        """读面板文件并注入 Token —— 占位符可能在 HTML，也可能在 app.js（拆分后在 JS）。"""
        with open(os.path.join(PANEL_DIR, name), "rb") as fh:
            data = fh.read()
        if b"__PFAN_TOKEN__" in data:
            data = data.replace(b"__PFAN_TOKEN__", get_token().encode())
        return data

    def _vendor(self, name):
        """读随仓库部署的第三方资产（panel/vendor/）。

        与 _panel() 的分工：这里【不】注入 Token —— 第三方库没有占位符可言，
        对着 vendor 做替换只会把整份 ESM 白扫一遍。
        """
        with open(os.path.join(VENDOR_DIR, name), "rb") as fh:
            return fh.read()

    def _send_raw(self, data, ctype):
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _send(self, obj, code=200):
        b = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        # ②⑦ 这里【不发】Access-Control-Allow-Origin：面板与 API 同源，
        #     通配 CORS 只会让 LAN 内任意网页跨域读遥测。测试 test_api_has_no_wildcard_cors 守着。
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        parts = self.path.split("?", 1)
        p = parts[0]
        qs = parts[1] if len(parts) > 1 else ""
        q = dict(x.split("=", 1) for x in qs.split("&") if "=" in x)
        try:
            if p == "/api/now":
                self._send(snapshot(live=False))
            elif p == "/api/history":
                self._send(
                    history(int(q.get("hours", "24")), curve_only=q.get("curve") == "1")
                )
            elif p in ("/", "/pfan"):
                try:
                    # 注入 Token 在 _panel() 里完成：只有从本源拉页面的脚本才拿得到
                    self._send_raw(
                        self._panel("index.html"), "text/html; charset=utf-8"
                    )
                except Exception as e:
                    self._send({"error": str(e)}, 500)
            elif p == "/pfan.css":
                try:
                    self._send_raw(self._panel("styles.css"), "text/css; charset=utf-8")
                except Exception as e:
                    self._send({"error": str(e)}, 500)
            elif p in ("/pfan.js", "/pfan-core.js"):
                # core.js 是纯逻辑模块，由 app.js import；app.js 顶层有副作用，不能被测试导入
                name = "core.js" if p.endswith("-core.js") else "app.js"
                try:
                    self._send_raw(
                        self._panel(name), "application/javascript; charset=utf-8"
                    )
                except Exception as e:
                    self._send({"error": str(e)}, 500)
            elif p == "/pfan-vendor-uplot.js":
                # vendored uPlot ESM：面板过去从 cdn.jsdelivr.net 拉图库，
                # 目标机是 LAN 设备可能无出口 —— 那时图表静默缺席而页面照常显示。
                try:
                    self._send_raw(
                        self._vendor("uPlot.esm.js"),
                        "application/javascript; charset=utf-8",
                    )
                except Exception as e:
                    self._send({"error": str(e)}, 500)
            elif p == "/pfan-vendor-uplot.css":
                try:
                    self._send_raw(
                        self._vendor("uPlot.min.css"), "text/css; charset=utf-8"
                    )
                except Exception as e:
                    self._send({"error": str(e)}, 500)
            elif p == "/api/params":
                self._send(
                    {"params": read_params(), "conf": CONF, "keys": list(PARAM_KEYS)}
                )
            elif p == "/api/events":
                self._send(events(int(q.get("limit", "60"))))
            elif p == "/api/profile":
                self._send(
                    {
                        "curve": get_curve(),
                        "available": list(CURVES),
                        "guard_temp": GUARD_TEMP,
                        "active": get_curve() != "auto",
                    }
                )
            elif p == "/api/mode":
                held = subprocess.run(
                    ["systemctl", "is-active", "pfand"], capture_output=True, text=True
                ).stdout.strip()
                self._send({"mode": "daemon" if held == "active" else "manual"})
            elif p == "/api/levels":
                self._send(
                    {
                        "levels": LEVELS,
                        "fps": FPS,
                        # 固件实测接受 0~120，但 set_level 明令禁 0（_FSL 0 = 风扇停转，
                        # 不是"交回曲线"）。对外契约必须描述 API 行为，不是固件能力。
                        "free_range": [1, 120],
                        "note": "固件实测接受 0~120，但本 API 禁 0（_FSL 0 = 停转）；"
                        '交回曲线请 set_curve("auto")。档位按钮只是常用值',
                    }
                )
            elif p == "/api/curve":
                # 守护曲线
                self._send(curve_view())
            else:
                self._send({"error": "not found"}, 404)
        except Exception as e:
            self._send({"error": str(e)}, 500)

    MAX_BODY = 64 * 1024  # ② 请求体上限，防大 Content-Length 打内存
    # （Minor 7）类上那个只转发到 origin_allowed() 的静态助手已删除：零调用点，
    # 只被测试注释提及 —— 留着会被误当成"Origin 还有第二道门"。门只有一个：下面 do_POST。

    def _deny(self, msg, code=403):
        try:
            self._send({"error": msg}, code)
        except Exception:
            pass

    def do_POST(self):
        # ② Content-Length 解析 + 上限必须在 try 内，且读取有界
        try:
            n = int(str(self.headers.get("Content-Length", "0") or 0))
            if n < 0:
                n = 0
            if n > self.MAX_BODY:
                raise ValueError("body too large: %d" % n)
            body = self.rfile.read(n).decode(errors="replace") if n else "{}"
        except ValueError as e:
            self._deny("bad request: %s" % e, 413 if "too large" in str(e) else 400)
            return
        except Exception as e:
            self._deny("bad request: %s" % e, 400)
            return
        # ② 写操作放行规则：【token 必须匹配】，带了 Origin 时还必须在白名单里。
        #
        # 曾经这里是 "token 或 Origin"（OR）—— 但 origin_allowed() 只比对主机名、
        # 忽略端口与协议，于是 localhost:9999 / 192.168.1.10:8080 / pfan.example.com:<任意>
        # 这些同主机不同端口的页面全都能【免 token】写档位。SECURITY.md 承诺的是"必须带
        # token"，文档与代码不一致，而且这是本仓库的安全头条。
        # 面板始终注入 token（app.js 顶层的 TOKEN 占位符），"旧缓存页面没 token"的过渡理由早已失效。
        tok = self.headers.get("X-Pfan-Token", "")
        origin = self.headers.get("Origin", "") or ""
        if tok != get_token():
            self._deny("missing or invalid X-Pfan-Token")
            return
        if origin and not origin_allowed(origin):
            self._deny("origin not allowed")
            return
        try:
            d = json.loads(body or "{}")
            if "params" in d:
                newp = {k: int(v) for k, v in d["params"].items() if k in PARAM_KEYS}
                errs = validate_params(newp)
                if errs:
                    self._send({"ok": False, "errors": errs}, 400)
                else:
                    write_params(newp)
                    log_event(
                        "curve",
                        "自定义曲线已更新: "
                        + " ".join(
                            "%s=%d" % (k, newp[k])
                            for k in (
                                "IDLE",
                                "L0",
                                "T1",
                                "L1",
                                "T2",
                                "L2",
                                "T3",
                                "L3",
                                "T4",
                                "L4",
                                "T5",
                                "L5",
                                "CAP",
                                "EMERG",
                            )
                        ),
                    )
                    subprocess.run(
                        ["systemctl", "restart", "pfand"], capture_output=True
                    )
                    time.sleep(2)
                    self._send({"ok": True, "params": read_params(), **curve_view()})
            elif "profile" in d:
                nm = set_curve(d["profile"])
                log_event("curve", "切换曲线 -> %s" % nm)
                time.sleep(2)
                _cache["snap"] = None
                _cache["at"] = 0
                self._send({"ok": True, "profile": nm, **snapshot(live=True)})
            elif d.get("hold"):
                # 接管：停守护，面板独占控制权
                subprocess.run(["systemctl", "stop", "pfand"], capture_output=True)
                self._send({"ok": True, "mode": "manual", **snapshot(live=True)})
            elif d.get("auto"):
                # 交还 pfand 守护：重启它并返回当前状态
                subprocess.run(["systemctl", "restart", "pfand"], capture_output=True)
                self._send({"ok": True, "auto": True, **snapshot(live=True)})
            elif "level" in d:
                v = set_level(d["level"])
                if get_curve() != "auto":
                    save_state(level=v)  # 记住档位，重启后还原
                self._send({"ok": True, "level": v, **snapshot(live=True)})
            else:
                self._send({"error": "no level"}, 400)
        except Exception as e:
            self._send({"error": str(e)}, 500)

    def log_message(self, *a):
        pass


class Server(socketserver.ThreadingTCPServer):
    """⑯ daemon_threads 必须为 True：ThreadingTCPServer 默认 False，
    一个挂住的 handler 就会让 shutdown() 永远等下去（重启/部署被卡）。
    allow_reuse_address 让测试能反复绑定同端口。"""

    daemon_threads = True
    allow_reuse_address = True


if __name__ == "__main__":
    # 测试接缝：缺省 8789 与生产一致（test_pfand_loop.sh T0 断言）
    _PORT = int(os.environ.get("PFAN_PORT", "8789"))
    threading.Thread(target=collector, daemon=True).start()
    with Server(("0.0.0.0", _PORT), H) as s:
        s.serve_forever()
