"""HTTP 层测试：②⑤ Origin 白名单可配置、②⑦ CORS 不再全开、⑯ daemon_threads。

导入 pfanel 前必须给平台配置，否则模块级加载会按设计快速失败（P1 的 I4 修复）。
"""
import builtins
import json
import os
import threading
import time
import urllib.request
from urllib.error import HTTPError

os.environ.setdefault(
    "PFAN_PLATFORM_CONF",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..",
                 "platform", "platform.conf.example"),
)

import tempfile  # noqa: E402

_STATE = tempfile.mkdtemp(prefix="pfanel-test-")
# 假设备三件套：不给 PFAN_DMESG 的话 acpi() 会对着真 dmesg 空转 20×0.12s，HTTP 测试必超时
# 注意层级：__file__ 是 tests/python/test_http.py，向上两级才是仓库根
# （写成 dirname(dirname(abspath)) 只会得到 tests/ —— 会指向 tests/fake/bin/dmesg）
_REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
os.environ.setdefault("PFAN_DEV", os.path.join(_STATE, "dev"))
os.environ.setdefault("PFAN_DMESG", os.path.join(_REPO, "fake", "bin", "dmesg"))
os.environ.setdefault("PFAN_DMESG_STATE", os.path.join(_STATE, "dmesg.state"))
os.environ.setdefault("PFAN_DMESG_LOG", os.path.join(_STATE, "dmesg.log"))
open(os.environ["PFAN_DEV"], "w").write("")
os.environ.setdefault("PFAN_LOCK", os.path.join(_STATE, "pfanel.lock"))
os.environ.setdefault("PFAN_TOKEN_FILE", os.path.join(_STATE, "token"))
os.environ.setdefault("PFAN_DB", os.path.join(_STATE, "pfanel.db"))
os.environ.setdefault("PFAN_CURVE_FILE", os.path.join(_STATE, "curve.state"))
os.environ.setdefault("PFAN_CONF", os.path.join(_STATE, "pfand.conf"))

import pfanel  # noqa: E402  （必须在环境变量之后导入）
import pfan_platform  # noqa: E402


def test_state_seam_defaults_equal_production():
    """接缝的【缺省值】必须等于生产值 —— 否则测试跑的是另一套语义。

    注意：本文件已经把这些环境变量指向临时目录了，所以不能断言解析后的值，
    只能断言源码里写的缺省值（与 pfand 侧 T0 的做法一致）。
    """
    # 用 AST【真实解析】源码缺省值，而不是 `default in src` 的字符串包含 ——
    # 2026-10-08 实例：自动格式化把 os.environ.get("PFAN_LOCK", "/run/pfanel.lock")
    # 折成两行，字符串包含当场静默失效，而这条正是防"三个程序锁分叉"的守卫。
    # 格式化器悄悄废掉安全守卫，比没有守卫更危险。解析 AST 后折行/改引号都影响不到它。
    import ast as _ast
    import inspect
    tree = _ast.parse(inspect.getsource(pfanel))
    found = {}
    for node in _ast.walk(tree):
        if (isinstance(node, _ast.Call) and isinstance(node.func, _ast.Attribute)
                and node.func.attr == "get" and len(node.args) >= 2):
            a0, a1 = node.args[0], node.args[1]
            if (isinstance(a0, _ast.Constant) and isinstance(a1, _ast.Constant)
                    and isinstance(a0.value, str) and a0.value.startswith("PFAN_")):
                found.setdefault(a0.value, a1.value)
    expected = {
        "PFAN_DB": "/var/lib/pfanel/pfanel.db",
        "PFAN_CURVE_FILE": "/var/lib/pfanel/curve.state",
        "PFAN_TOKEN_FILE": "/var/lib/pfanel/token",
        "PFAN_CONF": "/etc/pfand.conf",
        "PFAN_LOCK": "/run/pfanel.lock",
        "PFAN_DMESG": "dmesg",
      }
    # PFAN_PANEL_DIR 的缺省不是字面量，而是 _PLAT.get("PANEL_DIR", <兜底>) ——
    # 面板部署路径改成从 platform.conf 派生（单一事实源：deploy.sh / smoke.sh /
    # pfanel.py 三处同源），所以这里不能按字面量比对，改为断言两件事：
    #   ① 源码确实从 _PLAT 取；② platform.conf 里声明了它（缺了会落回代码兜底值）。
    _src = inspect.getsource(pfanel)
    assert '_PLAT.get("PANEL_DIR"' in _src, (
        "PFAN_PANEL_DIR 的缺省不再来自 platform.conf —— 面板路径会有第二个事实源")
    assert pfan_platform.get("PANEL_DIR", default=None) is not None, (
        "platform.conf 没有声明 PANEL_DIR —— 派生会落回代码里的兜底值")
    for k, want in expected.items():
        assert k in found, f"源码里找不到 {k} 的缺省值（接缝被删了？）"
        assert found[k] == want, f"{k} 缺省值不是生产值: {found[k]!r}，期望 {want!r}"
    # PFAN_DEV 是三层回退（环境变量 -> 平台配置 -> 字面兜底），
    # 兜底值来自平台配置，所以断言平台配置里写的 DEV 才是真正的"生产值"。
    assert 'os.environ.get("PFAN_DEV", "")' in inspect.getsource(pfanel), "PFAN_DEV 接缝缺失"
    with open(os.path.join(_REPO, "platform", "platform.conf.example"), encoding="utf-8") as fh:
        assert any(line.strip() == "DEV=/dev/pfanctl" for line in fh), \
            "平台配置里的 DEV 不是 /dev/pfanctl（生产值变了？）"



def _serve(port=0):
    """在端口 0 上绑定，回传【内核分配的真实端口】。

    旧做法是先 bind 再 close 拿到一个空闲端口、随后拿它去开服务器 —— close 与重开之间
    有窗口，别人可以占走它，用例于是间歇性失败。这条 flaky 曾让 pre-push 随机拒绝推送。
    让内核直接挑端口（port=0）再从 server_address 读回，窗口就不存在了。"""
    srv = pfanel.Server(("127.0.0.1", port), pfanel.H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv, srv.server_address[1]


# ---------------- ②⑤ Origin 白名单 ----------------

def test_origin_default_allowlist_matches_production():
    """缺省白名单必须等于当前生产值（P1 里硬编码的那一组）。"""
    assert pfanel.DEFAULT_ORIGINS == "pfan.example.com,127.0.0.1,localhost,192.168.1.10"


def test_origin_accepts_panel_and_lan():
    assert pfanel.origin_allowed("https://pfan.example.com")
    assert pfanel.origin_allowed("http://192.168.1.10:8789")
    assert pfanel.origin_allowed("http://localhost:8789")


def test_origin_rejects_missing_and_foreign():
    assert not pfanel.origin_allowed(None)
    assert not pfanel.origin_allowed("")
    assert not pfanel.origin_allowed("http://evil.example")
    assert not pfanel.origin_allowed("https://pfan.example.com.evil.example")


def test_origin_allowlist_is_configurable():
    """②⑤：白名单必须能用环境变量改，而不是写死在源码里。"""
    os.environ["PFAN_ORIGIN_ALLOW"] = "a.example,b.example"
    try:
        assert pfanel.origin_allowed("https://a.example")
        assert pfanel.origin_allowed("http://b.example:8789")
        assert not pfanel.origin_allowed("http://192.168.1.10:8789"), \
            "改了白名单却仍放行旧值 —— 说明没真用环境变量"
    finally:
        del os.environ["PFAN_ORIGIN_ALLOW"]


# ---------------- ②⑦ CORS ----------------

def test_api_has_no_wildcard_cors():
    """②⑦：面板是同源的，`Access-Control-Allow-Origin: *` 只会让任意网页跨域读遥测。"""
    srv, port = _serve()
    try:
        r = urllib.request.urlopen(f"http://127.0.0.1:{port}/api/now", timeout=10)
        acao = r.headers.get("Access-Control-Allow-Origin")
        assert acao != "*", f"仍是通配 CORS: {acao}"
    finally:
        srv.shutdown()
        srv.server_close()


def test_api_still_serves_json_shape():
    srv, port = _serve()
    try:
        r = urllib.request.urlopen(f"http://127.0.0.1:{port}/api/now", timeout=10)
        assert r.headers.get("Content-Type", "").startswith("application/json")
        body = r.read().decode()
        for k in ('"ts"', '"temp"', '"level"', '"curve"', '"cached"', '"age"'):
            assert k in body, f"/api/now 缺字段 {k}: {body[:200]}"
    finally:
        srv.shutdown()
        srv.server_close()


# ---------------- ⑯ daemon_threads ----------------

def test_server_has_daemon_threads():
    """⑯：ThreadingTCPServer 默认 daemon_threads=False，shutdown 会被挂住的 handler 卡住。"""
    assert pfanel.Server.daemon_threads is True


def test_unauthorized_post_is_still_rejected():
    """收紧 CORS/白名单后，写接口的鉴权不能松。"""
    srv, port = _serve()
    try:
        req = urllib.request.Request(
            f"http://127.0.0.1:{port}/api/level",
            data=b'{"level":50}',
            headers={"Content-Type": "application/json", "Origin": "http://evil.example"},
            method="POST",
        )
        try:
            urllib.request.urlopen(req, timeout=10)
            raise AssertionError("恶意 Origin 居然通过了写接口")
        except HTTPError as e:
            assert e.code in (401, 403), f"期望 401/403，得到 {e.code}"
    finally:
        srv.shutdown()
        srv.server_close()


# ---------------- ②⑥ snapshot.fps / ②⑧ curve_view 表同源 ----------------

_CURVE_CONF = """IDLE=50
L0=25
T1=56
L1=30
T2=62
L2=40
T3=67
L3=50
T4=72
L4=60
T5=79
L5=70
EMERG=80
E=100
EMERG_REL=75
CAP=70
TRIM=6
GAIN=1
HYST=3
DWELL=30
DEAD=2
IV=10
"""


def test_snapshot_fps_not_null_for_valid_level():
    """②⑥：level=42 这种表外档位，fps 曾返回 null → 面板 RPM/噪音列变空。"""
    with open(os.environ["PFAN_CONF"], "w", encoding="utf-8") as fh:
        fh.write(_CURVE_CONF)
    # 预置假设备记住的档位为 42（表外值）。不预置的话假设备默认 0，
    # 而 level=0 是 falsy，走 `if lvl` 分支照样返回 None —— 那是另一个 case，不是 ②⑥。
    with open(os.environ["PFAN_DMESG_STATE"], "w", encoding="utf-8") as fh:
        fh.write("42")
    srv, port = _serve()
    try:
        r = urllib.request.urlopen(f"http://127.0.0.1:{port}/api/now", timeout=15)
        body = __import__("json").loads(r.read().decode())
        assert body["level"] == 42, f"档位应为预置的 42，实际: {body['level']}"
        assert body["fps"] is not None, f"②⑥: level=42 时 fps 仍为 null"
        assert isinstance(body["fps"], list) and len(body["fps"]) == 3
        import pfan_core
        assert tuple(body["fps"]) == pfan_core.FPS[40], "42 应吸附到 40 档的表项"
        # 注意 rpm 不在这里断言：它来自 EC 传感字节 est_rpm(ec76)，与档位无关，
        # 而假设备给不出有意义的 ec76（这正是 ②⑥ 的 fps 与 rpm 本就不同源的体现）。
    finally:
        srv.shutdown()
        srv.server_close()


def test_curve_view_uses_shared_fps_table():
    """②⑧：curve_view 曾自带一份缺 85/90/95 的 rpm 表，与 pfan_core.FPS 分歧。"""
    import pfan_core
    with open(os.environ["PFAN_CONF"], "w", encoding="utf-8") as fh:
        fh.write(_CURVE_CONF)
    srv, port = _serve()
    try:
        r = urllib.request.urlopen(f"http://127.0.0.1:{port}/api/curve", timeout=15)
        cv = __import__("json").loads(r.read().decode())
        bands = cv.get("bands") or []
        assert bands, f"曲线 bands 为空: {cv}"
        for b in bands:
            lvl = b.get("level", b.get("lvl")) if isinstance(b, dict) else None
            if lvl is None:
                continue
            rpm = b.get("rpm")
            assert rpm == pfan_core.nearest_fps(lvl)[0], \
                f"band level={lvl} rpm={rpm} 与 pfan_core.FPS 不一致"
        # 直接断言表本身不再局部定义
        import inspect
        assert "FPS = {25:3200" not in inspect.getsource(pfanel.curve_view), \
            "curve_view 仍在用局部 FPS 表"
    finally:
        srv.shutdown()
        srv.server_close()


# ---------------- C1: 写接口鉴权的真实规则 ----------------
# SECURITY.md 承诺「写接口必须带 X-Pfan-Token」，但代码曾是 `token 或 Origin 白名单`：
# Origin 只比对主机名、忽略端口与协议 → 同主机【任意端口】上的页面都能免 token 写。
# 面板始终注入 token（app.js:5），这条宽限没有存在理由。

def _post(port, token=None, origin=None, level=50):
    req = urllib.request.Request(
        f"http://127.0.0.1:{port}/api/level",
        data=json.dumps({"level": level}).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    if token is not None:
        req.add_unredirected_header("X-Pfan-Token", token)
    if origin is not None:
        req.add_unredirected_header("Origin", origin)
    try:
        urllib.request.urlopen(req, timeout=10)
        return 200
    except HTTPError as e:
        return e.code


def test_write_requires_token_even_from_allowed_origin():
    """C1：白名单 Origin 不能替代 token —— 主机名匹配会放过同主机任意端口的页面。"""
    srv, port = _serve()
    try:
        assert _post(port, token=None, origin="http://localhost:9999") == 403, \
            "无 token + localhost Origin 竟然放行了（主机名匹配，端口被忽略）"
        assert _post(port, token=None, origin="http://192.168.1.10:8080") == 403, \
            "无 token + 本机任意端口 Origin 竟然放行了"
        assert _post(port, token=None, origin="https://pfan.example.com") == 403, \
            "无 token + 白名单 Origin 竟然放行了"
        assert _post(port, token=None) == 403, "无 token 必须 403"
    finally:
        srv.shutdown()
        srv.server_close()


def test_tokenless_post_has_no_server_side_effect():
    """C1：deny 之后必须真的 return —— 403 已经发出去了，代码若继续往下跑，
    set_level 会把档位写进设备（urllib 收到 403 就返回，HTTP 层完全看不见）。
    状态码永远是绿的，只有设备侧流水（PFAN_DMESG_LOG）与设备文件能作证。"""
    srv, port = _serve()
    log = os.environ["PFAN_DMESG_LOG"]
    dev = os.environ["PFAN_DEV"]
    try:
        # 1) 先做一次合法写入：流水非空，才有"长没长"的基准（审计要求的前置）
        assert _post(port, token=pfanel.get_token(), level=50) == 200
        n0 = os.path.getsize(log) if os.path.exists(log) else 0
        assert n0 > 0, "合法写入后假设备流水仍为空 —— 基准不成立，本用例无意义"
        with open(dev, encoding="utf-8") as fh:
            d0 = fh.read()
        # 2) 无 token 的等价请求必须 403
        assert _post(port, token=None, level=45) == 403
        # 3) 给违规实现足够时间把副作用做完：1.5s >> 实际写入路径的几十毫秒。
        #    任何一次流水增长都说明 403 之后代码仍在执行（deny 没 return）。
        for _ in range(30):
            time.sleep(0.05)
            n1 = os.path.getsize(log)
            if n1 != n0:
                raise AssertionError(
                    "403 之后服务端仍有副作用：假设备流水 %d -> %d 字节"
                    "（token deny 缺 return，代码跑到了 set_level）" % (n0, n1)
                )
        with open(dev, encoding="utf-8") as fh:
            d1 = fh.read()
        assert d1 == d0, "403 之后设备文件被改写: %r -> %r" % (d0, d1)
    finally:
        srv.shutdown()
        srv.server_close()


def test_acpi_refuses_to_create_missing_node():
    """I2：节点缺失时 acpi() 必须一行都不写 —— open(DEV,"w") 会把普通文件
    【凭空创建】出来，之后 devtmpfs/insmod 因 EEXIST 复建不了节点，
    而调用方还当成写成功了（2026-10-06 事故形态）。"""
    target = os.path.join(_STATE, "missing-dev-node")
    if os.path.exists(target):
        os.unlink(target)
    saved_dev = pfanel.DEV
    had = os.environ.pop("PFAN_DEV", None)   # 摘掉测试接缝 → 走生产判定（必须是字符设备）
    pfanel.DEV = target
    try:
        assert pfanel.acpi("_SB.PCI0.LPCB.EC0.TFN1._FST") is None, \
            "缺节点时应拒绝并返回 None，而不是继续写"
        assert not os.path.exists(target), "acpi 凭空创建了普通文件: %s" % target
    finally:
        pfanel.DEV = saved_dev
        if had is not None:
            os.environ["PFAN_DEV"] = had


def test_write_with_valid_token_is_accepted():
    srv, port = _serve()
    try:
        tok = pfanel.get_token()
        assert tok, "拿不到 token，无法验证放行路径"
        # 带白名单 Origin（面板就是这样发的）
        assert _post(port, token=tok, origin="http://127.0.0.1:%d" % port) == 200, \
            "有效 token + 自身 Origin 应放行"
        # 不带 Origin（curl）
        assert _post(port, token=tok) == 200, "有效 token 无 Origin 应放行"
    finally:
        srv.shutdown()
        srv.server_close()


def test_write_with_valid_token_but_foreign_origin_is_rejected():
    """纵深防御：即使 token 对，陌生 Origin 也要拒（说明白名单仍在生效）。"""
    srv, port = _serve()
    try:
        tok = pfanel.get_token()
        assert _post(port, token=tok, origin="http://evil.example") == 403, \
            "有效 token 但陌生 Origin 应被白名单拒绝"
    finally:
        srv.shutdown()
        srv.server_close()


# ---------------- I2: ACAO 头必须【完全不存在】 ----------------

def test_api_must_not_send_any_acao_header():
    """C2/②⑦：只断言 != '*' 会放过反射型 ACAO（浏览器同样可跨域读）。"""
    srv, port = _serve()
    try:
        req = urllib.request.Request(
            f"http://127.0.0.1:{port}/api/now",
            headers={"Origin": "http://evil.example"},
        )
        r = urllib.request.urlopen(req, timeout=10)
        acao = r.headers.get("Access-Control-Allow-Origin")
        assert acao is None, f"不应发任何 ACAO 头，实测: {acao!r}"
        assert r.headers.get("Access-Control-Allow-Credentials") is None
    finally:
        srv.shutdown()
        srv.server_close()


# ---------------- I4: ⑯ 必须钉住 __main__ 真的用了 Server ----------------
# 只断言类属性 `Server.daemon_threads is True` 不够：把 __main__ 改回裸
# socketserver.ThreadingTCPServer(...)，缺陷原样回来而测试全绿。

def test_main_instantiates_the_daemon_server():
    import inspect
    src = inspect.getsource(pfanel)
    main = src[src.index('if __name__ == "__main__":'):]
    assert "with Server((" in main, \
        "__main__ 没有实例化 pfanel.Server —— daemon_threads 形同虚设"
    assert "socketserver.ThreadingTCPServer((" not in main, \
        "__main__ 用回了裸 ThreadingTCPServer（daemon_threads=False，shutdown 会挂住）"


# ---------------- 专家审计 C2：还原持久化状态时 free 曲线不得把风扇留在 0 ----------------
# CURVES["free"] is None  ->  "0x%02X" % None 抛 TypeError；
# 而 FSL "1 0" 在它【之前】已经写出去了，于是异常发生在恢复档位之前：
# pfanel 每次重启（包括 deploy.sh 都会重启 pfanel）都把 _FSL 留在 0，
# 且 pfand 在非 s0i3 模式 exit 0，救不回来。
def test_free_curve_must_not_break_persisted_state_restore():
    """free 曲线是 GUI 上真实存在的选项，持久化状态里出现它是正常的。

    缺陷（专家审计 C2）：apply_persisted_state 原本对 CURVES[curve] 直接 0x%02X 展开，
    而 free 在 CURVES 里是 None —— 于是一次 pfanel 重启（deploy.sh 每次都重启它）就在
    恢复档位【之前】抛异常，风扇被交回控制权却没有档位，pfand 在非 s0i3 模式 exit 0 救不回来。
    这里断言的是【行为】而不是 CURVES 的内容：修复方式可以是给 free 补一个值，
    也可以是在调用点特判，两种都该通过。
    """
    pfanel._APPLIED = False
    # 本机（Termux）没有 systemd，直接调 subprocess 会在 systemctl 上 FileNotFoundError，
    # 与被测逻辑无关。打桩掉：这里要验的是"档位有没有被恢复"，不是服务管理。
    import subprocess as _sp
    _real = _sp.run
    _sp.run = lambda *a, **k: _real(["true"], capture_output=True)
    # 同理：/var/log 在本机不存在（生产机有），日志写不出去不该算缺陷
    _pf = os.path.join(_STATE, "pfanel.log")
    _real_open = builtins.open

    def _open2(path, *a, **k):
        if str(path) == "/var/log/pfanel.log":
            path = _pf
        return _real_open(path, *a, **k)

    builtins.open = _open2
    curve_file = os.environ["PFAN_CURVE_FILE"]
    with open(curve_file, "w", encoding="utf-8") as fh:
        json.dump({"curve": "free", "level": 40}, fh)
    dev = os.environ["PFAN_DEV"]
    open(dev, "w").close()
    try:
        pfanel.apply_persisted_state()   # 抛异常本身就是缺陷
    finally:
        pfanel._APPLIED = False
        _sp.run = _real
        builtins.open = _real_open
    writes = [l for l in open(dev, encoding="utf-8").read().splitlines() if "_FSL" in l]
    assert writes, "free 曲线还原时一个 _FSL 都没写 —— 异常发生在恢复档位之前"
    import re as _re
    final = _re.search(r"_FSL 1 (\d+)", writes[-1])
    assert final and int(final.group(1)) == 40, (
        "free 曲线还原后最终档位应是已存档的 40，实际=%r（0 = 停转）" % (writes[-1],)
    )


# ---------------- 专家审计 C2 续：level=0 / level 缺失必须回落，而不是留停转 ----------------
# 上一条只覆盖 level=40（有意的非零档位）。缺省值那一支 —— level 压根是 0，
# 也就是从没按过档位按钮的【默认状态】—— 旧实现是掉进"无可恢复"的。

def test_persisted_state_with_zero_level_falls_back_not_stops():
    """level=0 不是"有意的 0"，而是"从没按过档位按钮"的默认状态（pfanel.py:82）。

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


def test_persisted_state_with_null_level_falls_back_not_stops():
    """state 里 level 显式为 null —— 这是唯一能走到 int() 的 TypeError 分支的输入。

    别把它和"缺 level 键"混为一谈：get_state() 写的是 d.get("level", 0)（pfanel.py:82），
    所以**缺键得到的是 0，不是 None**。缺键那条与 level=0 的设备输出逐字节相同，
    由上一条测试覆盖；把它当"缺键测试"写不会多覆盖任何分支，只会让 docstring 说谎。

    只有 JSON 里真的写了 null 才会变成 Python 的 None，于是 int(None) 抛 TypeError。
    这一条是 except 子句里 TypeError 三个字唯一的测试依据：把它收窄成 ValueError，
    本测试立刻转红。
    """
    pfanel._APPLIED = False
    curve_file = os.environ["PFAN_CURVE_FILE"]
    dev = os.environ["PFAN_DEV"]
    log = os.path.join(os.path.dirname(dev), "pfanel.log")
    with open(curve_file, "w", encoding="utf-8") as fh:
        json.dump({"curve": "free", "level": None}, fh)  # 必须真的写 null
    open(dev, "w").close()
    open(log, "w").close()
    import builtins as _b
    import subprocess as _sp
    import re as _re

    _real_run, _real_open = _sp.run, _b.open
    _sp.run = lambda *a, **k: _real_run(["true"], capture_output=True)
    pfanel.open = lambda p, *a, **k: (
        _real_open(log, "a") if str(p) == "/var/log/pfanel.log" else _real_open(p, *a, **k))
    try:
        pfanel.apply_persisted_state()
    finally:
        _sp.run = _real_run
        pfanel.open = _real_open
        pfanel._APPLIED = False
    writes = [l for l in _real_open(dev, encoding="utf-8").read().splitlines()
              if "_FSL" in l]
    last = _re.findall(r"_FSL 1 (\d+)", writes[-1]) if writes else []
    assert last and int(last[-1]) == 25, (
        "level=null 时最终档位是 %r，必须与 level=0 同类回落到 25 而不是 0（0 = 停转）"
        % (last[-1] if last else None,)
    )
    logtext = _real_open(log, encoding="utf-8").read()
    assert "还原失败" not in logtext, (
        "int(None) 的 TypeError 冒进了外层 except，日志=%r" % (logtext,)
    )
    assert "None" in logtext and "回落" in logtext, (
        "回落既要写进日志、也要带上坏值本身：%r" % (logtext,)
    )


# ---------------- 续：存档 level 不是整数（"abc"）同样必须回落，而不是留下停转 ----------------
# get_state() 把 JSON 里的 level 原样返回（pfanel.py:82），所以手改/写坏的曲线文件
# 能把字符串送进还原分支。旧实现 `not _lv or int(_lv) < 1` 在 "abc" 上短路失败：
# not "abc" 为 False → 求值 int("abc") 抛 ValueError → 被外层 except 吞掉 →
# 日志只写"还原失败"，而 _FSL 停在两步之前刚写下的 1 0 —— 同一个"留下停转"的终态
# 换条触发路径又回来了。


def test_persisted_state_with_non_integer_level_falls_back_not_stops():
    """存档 level="abc" 必须与 level=0 同类处理：回落到安全下限，绝不停转。

    可达性窄但真实：save_state(level=) 只有一个调用者，写进去的是 set_level() 的
    返回值（必是整数），所以 HTTP API 产生不了这种值；但曲线文件是一个【人手可改的
    文本文件】，而"有人手改配置文件"正是本项目的既定威胁模型。
    """
    pfanel._APPLIED = False
    curve_file = os.environ["PFAN_CURVE_FILE"]
    dev = os.environ["PFAN_DEV"]
    log = os.path.join(os.path.dirname(dev), "pfanel.log")
    with open(curve_file, "w", encoding="utf-8") as fh:
        json.dump({"curve": "free", "level": "abc"}, fh)
    open(dev, "w").close()
    open(log, "w").close()  # 清空：本文件其它测试也会往这里追加
    import builtins as _b
    import subprocess as _sp
    import re as _re

    _real_run, _real_open = _sp.run, _b.open
    _sp.run = lambda *a, **k: _real_run(["true"], capture_output=True)
    pfanel.open = lambda p, *a, **k: (
        _real_open(log, "a")
        if str(p) == "/var/log/pfanel.log"
        else _real_open(p, *a, **k)
    )
    try:
        pfanel.apply_persisted_state()  # 抛异常本身就是缺陷
    finally:
        _sp.run = _real_run
        pfanel.open = _real_open
        pfanel._APPLIED = False
    writes = [
        l for l in _real_open(dev, encoding="utf-8").read().splitlines() if "_FSL" in l
    ]
    last = _re.findall(r"_FSL 1 (\d+)", writes[-1]) if writes else []
    assert last and int(last[-1]) == 25, (
        "level='abc' 时最终档位是 %r，必须与 level=0 同类回落到 25 而不是 0（0 = 停转）"
        % (last[-1] if last else None,)
    )
    logtext = _real_open(log, encoding="utf-8").read()
    assert "还原失败" not in logtext, (
        "int('abc') 的 ValueError 冒进了外层 except，日志=%r" % (logtext,)
    )
    assert "abc" in logtext and "回落" in logtext, (
        "回落既要写进日志、也要带上坏值本身，否则事后分不清是存档坏了还是设备坏了：%r"
        % (logtext,)
    )


# ---------------- 续：bool 与非有限浮点 —— 分别对应 isinstance 守卫与 OverflowError ----------------
# 上一条"abc"只覆盖 except 子句里的 ValueError 一个字。子句里另外两个字此前【零覆盖】：
# TypeError（唯一能走到的输入是 JSON 的 null）和 OverflowError（NaN / ±Infinity）。
# bool 则是更靠前的一层：它在 int() 之前就被 isinstance 挡掉，走不到任何 except。


def test_persisted_state_with_bool_level_falls_back_not_stops():
    """state 里 level 是 true —— bool 是 int 的子类，int(True) == 1，能顺利通过 >=1 检查。

    不单独挡掉的话会写出 _FSL 1 1：不是 0，但 1 档离停转只差一步，而 true 显然不是档位。
    删除 isinstance(_lv, bool) 这一层，本测试立刻转红。
    """
    pfanel._APPLIED = False
    curve_file = os.environ["PFAN_CURVE_FILE"]
    dev = os.environ["PFAN_DEV"]
    log = os.path.join(os.path.dirname(dev), "pfanel.log")
    with open(curve_file, "w", encoding="utf-8") as fh:
        json.dump({"curve": "free", "level": True}, fh)
    open(dev, "w").close()
    open(log, "w").close()
    import builtins as _b
    import subprocess as _sp
    import re as _re

    _real_run, _real_open = _sp.run, _b.open
    _sp.run = lambda *a, **k: _real_run(["true"], capture_output=True)
    pfanel.open = lambda p, *a, **k: (
        _real_open(log, "a") if str(p) == "/var/log/pfanel.log" else _real_open(p, *a, **k))
    try:
        pfanel.apply_persisted_state()
    finally:
        _sp.run = _real_run
        pfanel.open = _real_open
        pfanel._APPLIED = False
    writes = [l for l in _real_open(dev, encoding="utf-8").read().splitlines()
              if "_FSL" in l]
    last = _re.findall(r"_FSL 1 (\d+)", writes[-1]) if writes else []
    assert last and int(last[-1]) == 25, (
        "level=true 时最终档位是 %r，必须回落到 25 而不是 1（1 档离停转只差一步）"
        % (last[-1] if last else None,)
    )
    logtext = _real_open(log, encoding="utf-8").read()
    assert "还原失败" not in logtext, (
        "bool 不该走 except 也不该停转，日志=%r" % (logtext,)
    )
    assert "True" in logtext and "回落" in logtext, (
        "回落既要写进日志、也要带上坏值本身：%r" % (logtext,)
    )


def test_persisted_state_with_non_finite_float_level_falls_back_not_stops():
    """state 里 level 是 NaN / Infinity —— Python 的 json 默认 allow_nan=True，
    这三个都是**合法 JSON 字面量**：手改文件写得进去，json.loads 也读得回来。

    int(nan) 抛 ValueError（与 "abc" 同一类），int(±Infinity) 抛 OverflowError ——
    后者是 except 子句里 OverflowError 三个字唯一的测试依据：把子句收窄成
    except (TypeError, ValueError)，本测试转红而 "abc" 那条仍然绿。
    """
    pfanel._APPLIED = False
    curve_file = os.environ["PFAN_CURVE_FILE"]
    dev = os.environ["PFAN_DEV"]
    log = os.path.join(os.path.dirname(dev), "pfanel.log")
    import builtins as _b
    import subprocess as _sp
    import re as _re

    _real_run, _real_open = _sp.run, _b.open
    _sp.run = lambda *a, **k: _real_run(["true"], capture_output=True)
    pfanel.open = lambda p, *a, **k: (
        _real_open(log, "a") if str(p) == "/var/log/pfanel.log" else _real_open(p, *a, **k))
    try:
        for raw, label in ((float("nan"), "NaN"), (float("inf"), "Infinity")):
            pfanel._APPLIED = False
            with open(curve_file, "w", encoding="utf-8") as fh:
                json.dump({"curve": "free", "level": raw}, fh)  # allow_nan 默认 True
            open(dev, "w").close()
            open(log, "w").close()
            pfanel.apply_persisted_state()  # 抛异常本身就是缺陷
            writes = [l for l in _real_open(dev, encoding="utf-8").read().splitlines()
                      if "_FSL" in l]
            last = _re.findall(r"_FSL 1 (\d+)", writes[-1]) if writes else []
            assert last and int(last[-1]) == 25, (
                "level=%s 时最终档位是 %r，必须回落到 25 而不是 0（0 = 停转）"
                % (label, last[-1] if last else None,)
            )
            logtext = _real_open(log, encoding="utf-8").read()
            assert "还原失败" not in logtext, (
                "int(%s) 抛的异常冒进了外层 except，日志=%r"
                % (label, logtext,)
            )
    finally:
        _sp.run = _real_run
        pfanel.open = _real_open
        pfanel._APPLIED = False
