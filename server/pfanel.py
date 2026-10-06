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
import subprocess
import threading
import time

DEV = "/dev/pfanctl"
EC = r"\_SB.PCI0.LPCB.EC0"
FST = EC + ".TFN1._FST"
FSL = EC + ".TFN1._FSL"
EC88 = EC + ".EC88"
TZ  = "/sys/class/thermal/thermal_zone9/temp"
DB  = "/var/lib/pfanel/pfanel.db"
LEVELS = [0, 25, 30, 40, 50, 60, 70, 80, 85, 90, 95, 100]

# --- 风扇曲线（EC 0x79）: 只在 _FSL=0（交回曲线）时生效 ---
CURVES = {
    "auto":  None,   # 不动 0x79，交给固件/守护
    "cool":  0x00,   # 固件性能曲线
    "s0i3":  0x02,   # 中间档
    "quiet": 0x05,   # 固件静音曲线（社区实测 ~74°C 且震荡）
    "free":  None,   # 自由模式：停守护，档位完全由用户定（仍需 s0i3 才生效）
}
CURVE_FILE = "/var/lib/pfanel/curve.state"
GUARD_TEMP = 82    # 看门狗阈值：quiet 下超过此温度自动回退（TjMax=100）

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
    if curve is not None: d["curve"] = curve
    if level  is not None: d["level"]  = level
    os.makedirs(os.path.dirname(CURVE_FILE), exist_ok=True)
    import json as _j
    open(CURVE_FILE, "w").write(_j.dumps(d))
    return d

def get_curve():
    return get_state()["curve"]

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
        time.sleep(1.6)
        ec = get_ec76()
        if not ec:                      # 交回没生效 → 绝不留停转
            acpi(FSL, "1 25")
            ec = 25
            with open("/var/log/pfanel.log", "a") as f:
                f.write("%s auto: _FSL 0 未交回成功(EC=%s)，已兜底 25%%\n"
                        % (time.strftime("%Y-%m-%d %H:%M:%S"), ec))
        subprocess.run(["systemctl","stop","pfand"], capture_output=True)
    elif name == "free":
        # 自由模式：s0i3（让 EC 跟随设定值）+ 停守护，档位由用户面板直接控制
        subprocess.run(["systemctl","stop","pfand"], capture_output=True)
        acpi(FSL, "1 0")
        acpi(EC88, "4 181 0x79 0x%02X 0" % CURVES["s0i3"])
    elif name == "s0i3":
        # s0i3 = 曲线本体模式：释放设定值让 EC 完全跟随，然后由 pfand 施加自定义曲线。
        # 必须【启动】守护 —— pfand 自己会 ensure_s0i3() 并按温度调档。
        acpi(FSL, "1 0")
        acpi(EC88, "4 181 0x79 0x%02X 0" % val)
        subprocess.run(["systemctl","restart","pfand"], capture_output=True)
    else:
        # quiet / cool：固件自己的曲线接管，必须停守护
        #（守护写 _FSL 会让 EC 忽略 0x79，曲线就失效了）
        subprocess.run(["systemctl","stop","pfand"], capture_output=True)
        acpi(FSL, "1 0")
        acpi(EC88, "4 181 0x79 0x%02X 0" % val)
    save_state(curve=name)
    return name

# 需要看门狗的曲线：quiet 会让温度飙高；s0i3 更危险——固件热保护直接失效，
# EC 完全听设定值，无任何下限。两者都必须由我们兜底。
# quiet 让温度飙高；s0i3/free 让固件退出热保护 —— free 最危险
#（s0i3 的 EC 地板 + 一个自己的守护），原来刻意排除 free 是错的，一并纳入。
GUARDED = ("quiet", "s0i3", "free")

def guard():
    """看门狗：受管曲线下温度失控 → 自动回退到安全自动模式。
    free 模式不看门狗（用户明确接管，风险自担）"""
    cv = get_curve()
    if cv not in GUARDED:
        return None
    t = get_temp()
    if t is None or t < GUARD_TEMP:
        return None
    set_curve("auto")
    try:
        log_event("guard", "看门狗触发：%.1fC >= %dC，自动回退" % (t, GUARD_TEMP))
        with open("/var/log/pfanel.log","a") as f:
            f.write("%s GUARD 温度 %.1fC >= %dC，quiet 曲线已自动回退\n"
                    % (time.strftime("%Y-%m-%d %H:%M:%S"), t, GUARD_TEMP))
    except Exception:
        pass
    return t
# INT3404 state* 表: 档位% -> (rpm_min, noise_mdB, power_mW)
FPS = {25:(3200,12500,1250),30:(3800,15000,1500),40:(5100,20000,2000),
       50:(6300,25000,2500),60:(7400,30000,3000),70:(9300,35000,3500),
       80:(9800,40000,4000),85:(10500,42500,4250),90:(11200,45000,4500),
       95:(11600,47500,4750),100:(12000,50000,5000)}

def _result_state():
    """返回 (最后一行 RESULT 的值, 该行的内核时间戳)。

    用时间戳而非行数判定「新结果」：dmesg 是环形缓冲，行被不断淘汰，
    绝对行数会在 2064→2063 这样下降，导致永远等不到"增长"（2026-10-05 实测）。
    内核时间戳严格单调，且三方共锁后不会被别人的结果污染。"""
    out = subprocess.run(["dmesg"], capture_output=True, text=True).stdout
    last, ts = None, -1.0
    for line in out.splitlines():
        if "pfanctl: RESULT" in line:
            try:
                ts = float(line[1:line.index("]")])   # [45623.012609] ...
            except Exception:
                ts = -1.0
            last = line.split("RESULT", 1)[1].strip()
    return last, ts

def acpi(path, args=""):
    """调 pfanctl，返回**本次调用自己的** RESULT 行。
    ① 文件锁：/dev/pfanctl 是单槽设备，pfand/pfan 也用同一把锁（见 pfand 的 flock）。
    ② 行数增长判定：只有 RESULT 总数超过写入前的数量才算拿到新结果；
       超时返回 None（而不是旧值），避免把 10 秒前的读数当成本次结果。"""
    cmd = f"{path} {args}".strip()
    lockf = "/run/pfanel.lock"
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
    if not s: return None
    try:
        return [int(x) for x in s.strip("[] ").split(",")]
    except Exception:
        return None

def get_temp():
    try:
        return round(int(open(TZ).read().strip())/1000.0, 1)
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
    if v < 1: v = 1
    if v > 120: v = 120
    acpi(FSL, f"1 {v}")
    return v

def get_ec76():
    """EC 0x76 实时风扇状态字节（byte1）= 当前实际转速百分比"""
    r = acpi(EC88, "4 181 118 0 0")
    if not r: return None
    try:
        v = int(r.split()[0])
        if v >= 0xFFFFFFFF: return None
        return (v >> 8) & 0xFF
    except Exception:
        return None

def est_rpm(byte1):
    """把 EC 状态字节换算成近似 RPM（对齐 _FPS 表）"""
    if byte1 is None or byte1 < 1: return None
    p = min(LEVELS, key=lambda l: abs(l - byte1))
    rpm = FPS.get(p, (3200,))[0]
    return int(rpm * byte1 / max(p, 1))

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
        r = subprocess.run(["systemctl","is-active","pfand"],
                           capture_output=True, text=True, timeout=5)
        _cache["daemon"] = (r.stdout.strip() == "active")
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
            return dict(c, cached=True,
                        age=round(time.time() - _cache["at"], 1))
    lvl = get_level()
    ec = get_ec76()
    snap = {"ts": int(time.time()), "temp": get_temp(), "level": lvl,
            "ec76": ec, "rpm": est_rpm(ec),
            "mode": "daemon" if daemon_alive() else "manual",
            "curve": get_curve(),
            "gov": ("curve" if (get_curve() == "s0i3" and daemon_alive()) else
                    get_curve() if get_curve() != "auto" else
                    "daemon" if daemon_alive() else "manual"),
            "fps": FPS.get(lvl) if lvl else None}
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
        acpi(FSL, "1 0")
        acpi(EC88, "4 181 0x79 0x%02X 0" % CURVES[st["curve"]])
        if st["curve"] == "s0i3":
            # s0i3 由 pfand 施加自定义温度曲线，拉起守护（它会自己 ensure_s0i3）
            subprocess.run(["systemctl","restart","pfand"], capture_output=True)
        else:
            subprocess.run(["systemctl","stop","pfand"], capture_output=True)
            if st.get("level"):
                acpi(FSL, "1 %d" % int(st["level"]))
        with open("/var/log/pfanel.log","a") as f:
            f.write("%s 还原持久化状态 curve=%s level=%s\n"
                    % (time.strftime("%Y-%m-%d %H:%M:%S"), st["curve"], st.get("level")))
    except Exception as e:
        with open("/var/log/pfanel.log","a") as f:
            f.write("%s 还原失败 %s\n" % (time.strftime("%Y-%m-%d %H:%M:%S"), e))


def log_event(kind, msg):
    """把关键事件（曲线切换/应急/守护启动）写进 DB，供面板展示"""
    try:
        c = db(); c.execute("INSERT INTO events(ts,kind,msg) VALUES(?,?,?)",
                            (int(time.time()), kind, str(msg)[:200]))
        c.commit()
        c.execute("DELETE FROM events WHERE ts < ?", (int(time.time())-7*86400,))
        c.commit()
    except Exception:
        pass

def events(limit=60):
    try:
        c = db()
        rows = c.execute("SELECT ts,kind,msg FROM events ORDER BY ts DESC LIMIT ?",
                         (limit,)).fetchall()
        return [{"ts": r[0], "kind": r[1], "msg": r[2]} for r in rows]
    except Exception:
        return []

TOKEN_FILE = "/var/lib/pfanel/token"
_tok = None

def get_token():
    """写操作的 Token。首次启动生成 0600 文件；同源页面经 HTML 注入拿到，
    跨站页面受同源策略限制读不到 → 阻断 CSRF。"""
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
        os.write(fd, _tok.encode()); os.close(fd)
        try:
            os.chmod(TOKEN_FILE, 0o600)
        except Exception:
            pass
    return _tok

CONF = "/etc/pfand.conf"
PARAM_KEYS = ("IDLE","L0","T1","L1","T2","L2","T3","L3","T4","L4","T5","L5",
              "EMERG","E","EMERG_REL","CAP","TRIM","GAIN","HYST","DWELL","DEAD","IV")

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

def validate_params(d):
    """严格校验：温度必须严格递增、档位在 [L0, CAP]、EMERG 高于最后一档"""
    errs = []
    # 注意：E（应急档位）必须在里面 —— 否则 :306 的 d["E"] 会 KeyError，
    # 前端漏传时返回 500 而不是 400（2026-10-05 审计实测）。
    need = ("IDLE","L0","T1","L1","T2","L2","T3","L3","T4","L4","T5","L5",
            "EMERG","E","EMERG_REL","CAP","TRIM","GAIN","HYST","DWELL","DEAD","IV")
    miss = [k for k in need if k not in d]
    if miss:
        errs.append("缺少参数: " + ",".join(miss)); return errs
    temps = [d["IDLE"],d["T1"],d["T2"],d["T3"],d["T4"],d["T5"],d["EMERG"]]
    for a,b in zip(temps, temps[1:]):
        if b <= a: errs.append("温度必须严格递增: %s" % temps); break
    if d["EMERG_REL"] >= d["EMERG"]:
        errs.append("EMERG_REL(%d) 必须小于 EMERG(%d)" % (d["EMERG_REL"], d["EMERG"]))
    lv = [d["L0"],d["L1"],d["L2"],d["L3"],d["L4"],d["L5"]]
    for x in lv:
        if x < 0 or x > d["CAP"]:
            errs.append("档位 %d 超出 [0,%d]" % (x, d["CAP"])); break
    if d["E"] < d["CAP"]:
        errs.append("应急档 E(%d) 不应小于 CAP(%d)" % (d["E"], d["CAP"]))
    if d["IV"] < 2: errs.append("IV 采样间隔至少 2s")
    if d["DWELL"] < d["IV"]: errs.append("DWELL 驻留不应小于 IV")
    if d["TRIM"] < 0 or d["TRIM"] > 30: errs.append("TRIM 需在 0~30")
    if d["GAIN"] < 0 or d["GAIN"] > 10: errs.append("GAIN 需在 0~10")
    return errs

def write_params(d):
    lines = ["# pfand 曲线参数 —— 由面板「自定义曲线」按钮写入",
             "# 分级骨架：温度上限 -> 档位", ""]
    for k in ("IDLE","L0","T1","L1","T2","L2","T3","L3","T4","L4","T5","L5"):
        lines.append("%s=%d" % (k, d[k]))
    lines += ["# 应急", "EMERG=%d" % d["EMERG"], "E=%d" % d.get("E",100),
              "EMERG_REL=%d" % d["EMERG_REL"], "# 上限与微调",
              "CAP=%d" % d["CAP"], "TRIM=%d" % d["TRIM"], "GAIN=%d" % d["GAIN"],
              "# 防抖", "HYST=%d" % d["HYST"], "DWELL=%d" % d["DWELL"],
              "DEAD=%d" % d["DEAD"], "IV=%d" % d["IV"], ""]
    tmp = CONF + ".tmp"
    open(tmp,"w").write("\n".join(lines))
    os.chmod(tmp, 0o644)
    os.replace(tmp, CONF)          # 原子替换，pfand 不会读到半截文件
    return True


def curve_view():
    """曲线视图：数据源 = /etc/pfand.conf（面板编辑的对象）"""
    cfg = read_params()
    FPS = {25:3200, 30:3800, 40:5100, 50:6300, 60:7400, 70:9300,
           80:9800, 100:12000}
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
            bands.append({"upto": up, "level": lvl,
                          "rpm": FPS.get(lvl) or int(lvl * 120),
                          "db": round(lvl * 0.5, 1),
                          "emerg": lvl == cfg.get("E", 100)})
    return {"params": cfg, "bands": bands, "curve": get_curve()}


def collector():
    c = db()
    while True:
        try:
            apply_persisted_state()
            guard()          # 温度失控自动回退（quiet/s0i3 才有风险）
            s = snapshot()
            _cache["snap"] = s
            _cache["at"] = time.time()
            _cache["daemon_at"] = 0      # 顺带刷新守护状态
            with _lock:
                c.execute("INSERT OR REPLACE INTO samples(ts,temp,level,ec76,rpm,gov)"
                          " VALUES(?,?,?,?,?,?)",
                          (s["ts"], s["temp"], s["level"], s["ec76"], s["rpm"],
                           s.get("gov")))
                c.commit()
                # 只留 7 天
                c.execute("DELETE FROM samples WHERE ts < ?", (int(time.time())-7*86400,))
                c.commit()
        except Exception:
            pass
        time.sleep(10)

def history(hours=24, limit=2000, curve_only=False):
    c = db()
    since = int(time.time()) - hours*3600
    if curve_only:
        rows = c.execute("SELECT ts,temp,level,ec76,rpm FROM samples "
                         "WHERE ts>=? AND gov='curve' AND level>0 AND level<=100 "
                         "ORDER BY ts DESC LIMIT ?", (since, limit)).fetchall()
    else:
        rows = c.execute("SELECT ts,temp,level,ec76,rpm FROM samples WHERE ts>=? "
                         "ORDER BY ts DESC LIMIT ?", (since, limit)).fetchall()
    return [{"ts":r[0],"temp":r[1],"level":r[2],"ec76":r[3],"rpm":r[4]}
            for r in reversed(rows)]

class H(http.server.BaseHTTPRequestHandler):
    def _send(self, obj, code=200):
        b = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type","application/json")
        self.send_header("Access-Control-Allow-Origin","*")
        self.send_header("Content-Length",str(len(b)))
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
                self._send(history(int(q.get("hours","24")),
                                   curve_only=q.get("curve")=="1"))
            elif p == "/" or p == "/pfan":
                try:
                    html=open("/opt/beszel/beszel_data/pfan.html","rb").read().decode("utf-8")
                    # 注入 Token：只有从本源拉页面的脚本才拿得到
                    html=html.replace("__PFAN_TOKEN__", get_token())
                    data=html.encode("utf-8")
                    self.send_response(200)
                    self.send_header("Content-Type","text/html; charset=utf-8")
                    self.send_header("Content-Length",str(len(data)))
                    self.end_headers(); self.wfile.write(data)
                except Exception as e:
                    self._send({"error":str(e)},500)
            elif p == "/api/params":
                self._send({"params": read_params(), "conf": CONF,
                            "keys": list(PARAM_KEYS)})
            elif p == "/api/events":
                self._send(events(int(q.get("limit", "60"))))
            elif p == "/api/profile":
                self._send({"curve": get_curve(), "available": list(CURVES),
                            "guard_temp": GUARD_TEMP,
                            "active": get_curve() != "auto"})
            elif p == "/api/mode":
                held = subprocess.run(["systemctl","is-active","pfand"],
                                      capture_output=True, text=True).stdout.strip()
                self._send({"mode": "daemon" if held == "active" else "manual"})
            elif p == "/api/levels":
                self._send({"levels":LEVELS,"fps":FPS,
                            "free_range":[0,120],
                            "note":"固件支持 0~120 任意整数；档位按钮只是常用值"})
            elif p == "/api/curve":
                # 守护曲线
                self._send(curve_view())
            else:
                self._send({"error":"not found"}, 404)
        except Exception as e:
            self._send({"error":str(e)}, 500)

    MAX_BODY = 64 * 1024          # ② 请求体上限，防大 Content-Length 打内存
    ALLOWED_HOSTS = ("pfan.example.com", "127.0.0.1", "localhost", "192.168.1.10")

    @staticmethod
    def _same_origin(origin):
        if not origin:
            return False
        try:
            from urllib.parse import urlparse
            host = (urlparse(origin).hostname or "").lower()
        except Exception:
            return False
        return host in H.ALLOWED_HOSTS

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
        # ② 写操作放行规则：Token 匹配，或 Origin 属于本机（同源页面）
        #    - Token：新页面从 HTML 注入，跨站读不到（同源策略）
        #    - Origin 宽限：浏览器旧缓存的页面没 Token，但仍带本源 Origin，
        #      放行以免刷新前把面板弄坏；curl 不带 Origin → 被拒（符合预期）
        tok = self.headers.get("X-Pfan-Token", "")
        origin = self.headers.get("Origin", "") or ""
        if tok != get_token() and not self._same_origin(origin):
            self._deny("missing or invalid X-Pfan-Token")
            return
        try:
            d = json.loads(body or "{}")
            if "params" in d:
                newp = {k:int(v) for k,v in d["params"].items()
                        if k in PARAM_KEYS}
                errs = validate_params(newp)
                if errs:
                    self._send({"ok":False,"errors":errs}, 400)
                else:
                    write_params(newp)
                    log_event("curve", "自定义曲线已更新: " +
                              " ".join("%s=%d"%(k,newp[k]) for k in
                                       ("IDLE","L0","T1","L1","T2","L2","T3","L3",
                                        "T4","L4","T5","L5","CAP","EMERG")))
                    subprocess.run(["systemctl","restart","pfand"], capture_output=True)
                    time.sleep(2)
                    self._send({"ok":True,"params":read_params(),
                                **curve_view()})
            elif "profile" in d:
                nm = set_curve(d["profile"])
                log_event("curve", "切换曲线 -> %s" % nm)
                time.sleep(2)
                _cache["snap"] = None; _cache["at"] = 0
                self._send({"ok":True,"profile":nm,**snapshot(live=True)})
            elif d.get("hold"):
                # 接管：停守护，面板独占控制权
                subprocess.run(["systemctl","stop","pfand"], capture_output=True)
                self._send({"ok":True,"mode":"manual",**snapshot(live=True)})
            elif d.get("auto"):
                # 交还 pfand 守护：重启它并返回当前状态
                subprocess.run(["systemctl","restart","pfand"],
                               capture_output=True)
                self._send({"ok":True,"auto":True,**snapshot(live=True)})
            elif "level" in d:
                v = set_level(d["level"])
                if get_curve() != "auto":
                    save_state(level=v)      # 记住档位，重启后还原
                self._send({"ok":True,"level":v,**snapshot(live=True)})
            else:
                self._send({"error":"no level"}, 400)
        except Exception as e:
            self._send({"error":str(e)}, 500)

    def log_message(self, *a): pass

if __name__ == "__main__":
    threading.Thread(target=collector, daemon=True).start()
    socketserver.TCPServer.allow_reuse_address = True
    with socketserver.ThreadingTCPServer(("0.0.0.0", 8789), H) as s:
        s.serve_forever()
