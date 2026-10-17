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


# ---------------- 专家审计 C2 续：存档 level 不可用（0 / null / 非整数 / bool / 非有限）必须回落，而不是留停转 ----------------
# 组名必须说清这一组实际覆盖什么：本组五个成员是"值不可用"的五种形态，
# 不是"level=0 / level 缺失"两种 —— 「缺失」得到的是 0（get_state 的 d.get 默认值），
# 与第一条同字节；而 null 那条是后来补的，名字也早就从 missing 改成了 null_level。
# 写成两种覆盖的是组名，与成员对不上 —— 正是这个仓库在删的毛病。
# 上一条（test_free_curve_must_not_break_persisted_state_restore）只覆盖 level=40
# （有意的非零档位）；这一组补的是"值根本不可用"的那一支。缺省值那一支 —— level 压根是 0，
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

# ---------------- Task 3：set_curve 切 s0i3 必须确认守护真的起来了 ----------------
# 旧 set_curve 丢弃 systemctl 的退出码就往下走：守护没起来（内核模块没加载、
# 节点缺失、配置自检 fail-safe 直接 exit）时照样返回 ok、并把 s0i3 写进 curve.state。
# 那两步刚把 _FSL 留在 0 上，守护不来就是风扇停转；而持久化又让每次 pfanel 重启
# （含每次 deploy.sh）重放同一个坏状态 —— 模块没加载正是这台机器真出过的故障。
#
# 判据必须是【两个条件】而不是一个：守护 active 却正卡在 ensure_s0i3() 的握手窗口
# （core/pfand: 先写 _FSL 1 0 再写 EC88）时 _FSL 就是 0，只查 systemctl 会放过它。


class _Proc:
    """subprocess.run 的最小替身：只提供本文件这批用例用得到的属性。

    本机（Termux）根本没有 systemctl 这个二进制（`command -v systemctl` 为空），
    不打桩的话 set_curve 里的 systemctl 调用会抛 FileNotFoundError。
    """

    def __init__(self, stdout="", returncode=0):
        self.stdout = stdout
        self.stderr = ""
        self.returncode = returncode


def _systemctl_stub(unit_state="inactive", _real_run=None):
    """subprocess.run 的替身：systemctl 返回 unit_state，其余命令照常真跑。

    dmesg 必须【放行】给真跑：acpi() 靠它的 RESULT 行判定"这次调用拿到了新结果"，
    一并打桩成 `true` 的话每次 acpi() 都会空转满 20×0.12s = 2.4s，一条用例十秒起。
    """
    if _real_run is None:
        import subprocess as _sp

        _real_run = _sp.run

    def _fake_run(cmd, *a, **k):
        if isinstance(cmd, (list, tuple)) and any("systemctl" in str(c) for c in cmd):
            return _Proc(unit_state + "\n", 0 if unit_state == "active" else 3)
        return _real_run(cmd, *a, **k)

    return _fake_run


def test_set_curve_rolls_back_when_daemon_does_not_come_up():
    """守护起不来时 set_curve 必须回滚到 cool，且【不持久化】。

    set_curve 丢弃 systemctl 的退出码，守护起不来时仍返回 {"ok": true}
    并把该状态写进 curve.state —— 之后每次 pfanel 重启都重放同一个坏状态
    （模块未加载就是这台机器真出过的故障）。
    """
    dev = os.environ["PFAN_DEV"]
    curve_file = os.environ["PFAN_CURVE_FILE"]
    log = os.path.join(os.path.dirname(dev), "pfanel.log")
    # 设备侧请求流水：假 dmesg 逐条 append，是唯一留得住【每一次】写入的地方。
    # 本用例要用它，是因为回滚现在会在 EC 写之后再兜底写一次 _FSL
    # （交回后置条件），而 acpi() 以 "w" 打开设备，设备文件里只剩最后一次写入 ——
    # 于是"最后一条是 cool 的 EC 写"这条断言在新行为下必然失败，尽管那次写确实发生了。
    dmesg_log = os.environ["PFAN_DMESG_LOG"]
    # 起点显式写成 auto：断言"没有持久化 s0i3"才不会被上一条用例留下的值顺带满足
    with open(curve_file, "w", encoding="utf-8") as fh:
        json.dump({"curve": "auto", "level": 0}, fh)
    open(dev, "w").close()
    open(log, "w").close()
    open(dmesg_log, "w").close()
    import builtins as _b
    import subprocess as _sp

    _real_run, _real_open = _sp.run, _b.open
    # getattr 而不是直接取：实现落地前 pfanel 上还没有这个属性，
    # 直接取会让本用例在 AttributeError 上死掉 —— 那样它证明的是"函数不存在"，
    # 不是"守护没起来却把 s0i3 持久化了"这条缺陷本身。
    _real_ready = getattr(pfanel, "_daemon_ready", None)
    _sp.run = _systemctl_stub("inactive", _real_run)
    # 打桩 pfanel.open：只把 /var/log/pfanel.log 换成临时文件，其余照常
    pfanel.open = lambda p, *a, **k: (
        _real_open(log, "a")
        if str(p) == "/var/log/pfanel.log"
        else _real_open(p, *a, **k)
    )
    pfanel._daemon_ready = lambda *a, **k: False  # 设备上也读不回档位
    try:
        got = pfanel.set_curve("s0i3")
    finally:
        _sp.run = _real_run
        pfanel.open = _real_open
        if _real_ready is None:
            pfanel.__dict__.pop("_daemon_ready", None)
        else:
            pfanel._daemon_ready = _real_ready
        pfanel._APPLIED = False
    assert got == "cool", "守护没起来时 set_curve 返回 %r，必须是回滚后的 cool" % (got,)
    st = pfanel.get_state()
    assert st["curve"] == "cool", (
        "守护起不来却把 %r 持久化了 —— 每次 pfanel 重启都会重放同一个坏状态"
        % (st["curve"],)
    )
    logtext = _real_open(log, encoding="utf-8").read()
    assert "回滚" in logtext, (
        "回滚必须留日志，事后才分得清是守护没起来还是根本没检查：%r" % (logtext,)
    )
    writes = _real_open(dmesg_log, encoding="utf-8").read()
    assert "0x79 0x00" in writes, (
        "没有写 cool 的 EC 曲线值（0x79=0x00）—— 没回滚到 _FSL 0 也不会停转的曲线：%r"
        % (writes,)
    )


# ---------------- 终审 I1：回滚目标自己也必须验证交回 ----------------
# set_curve("cool") 是 s0i3 拉起守护失败后的自动安全网。旧实现写完 _FSL 1 0 +
# EC88 cool 就返回，从不验证 EC 有没有真的接管；而它的兄弟分支 auto 是验证的
# （等稳 → get_ec76() → 为 0 就兜底）。固件曲线下 _FSL 0 是【相信】安全的，
# 但这条分支一旦成为自动安全网，"相信"就成了承重结构：
# EC 写不进去（楔住的 EC —— 与守护起不来同一故障类）时，EC 仍停在 s0i3、
# _FSL 停在 0、风扇停转，而 cool 不在 GUARDED 里，没有任何东西在看它。


def _last_fsl(dev):
    """假设备上【最后一条】_FSL 写入的档位数字；最后一次写入不是 _FSL 时返回 None。

    acpi() 每次都以 "w" 打开设备，所以文件里只留最后一次写入的命令（不是流水）。
    读法按整份内容匹配而不是按行：命令流不带换行，按行取会拿到别的命令。
    返回 None 有明确含义 —— 最后落下去的不是一次 _FSL 写入，即没有把档位压下来。
    """
    import re as _re

    with open(dev, encoding="utf-8") as fh:
        found = _re.findall(r"_FSL 1 (\d+)", fh.read())
    return int(found[-1]) if found else None


def test_rollback_to_cool_verifies_the_handover_before_returning():
    """EC 写不进去时，回滚必须自己发现并兜底，不能"回滚成功"着把风扇留在 _FSL 0。

    两个方向都要跑，缺一不可：
      ① EC 写被丢弃（楔住的 EC）+ 读回 0 -> 最后一次写入必须是非零下限；
      ② EC 写成功、固件真的接管（读回 44）-> 最后一次写入不得是 _FSL。
    只跑 ① 的话，一条"无条件写兜底档位"的实现也全绿 —— 它会把每次正常切
    cool/quiet 都降成手动档位，是另一种事故。只跑 ② 则本缺陷完全看不见。
    """
    dev = os.environ["PFAN_DEV"]
    curve_file = os.environ["PFAN_CURVE_FILE"]
    log = os.path.join(os.path.dirname(dev), "pfanel.log")
    import subprocess as _sp

    _real_run, _real_open, _real_acpi = _sp.run, builtins.open, pfanel.acpi
    _real_ready = getattr(pfanel, "_daemon_ready", None)
    _real_ec = pfanel.get_ec76

    def _rollback_with(ec_reads, drop_curve_write):
        """守护起不来 -> 回滚 cool。ec_reads 是 get_ec76 的返回值序列（用尽后重复末条）。"""
        with open(curve_file, "w", encoding="utf-8") as fh:
            json.dump({"curve": "auto", "level": 0}, fh)
        open(dev, "w").close()
        open(log, "w").close()
        seq = list(ec_reads)
        dropped = []

        def _acpi(path, args=""):
            # 楔住的 EC：0x79 曲线写既不落到设备也不回 RESULT。
            # 注意要拦的是"写"，不是"读"—— get_ec76 读的是 0x76，不含 0x79。
            if drop_curve_write and str(path) == pfanel.EC88 and "0x79" in str(args):
                dropped.append(args)
                return None
            return _real_acpi(path, args)

        def _ec():
            return seq.pop(0) if len(seq) > 1 else seq[0]

        _sp.run = _systemctl_stub("inactive", _real_run)
        pfanel.acpi = _acpi
        pfanel.get_ec76 = _ec
        pfanel.open = lambda p, *a, **k: (
            _real_open(log, "a")
            if str(p) == "/var/log/pfanel.log"
            else _real_open(p, *a, **k)
        )
        pfanel._daemon_ready = lambda *a, **k: False
        try:
            got = pfanel.set_curve("s0i3")
        finally:
            _sp.run = _real_run
            pfanel.open = _real_open
            pfanel.acpi = _real_acpi
            pfanel.get_ec76 = _real_ec
            if _real_ready is None:
                pfanel.__dict__.pop("_daemon_ready", None)
            else:
                pfanel._daemon_ready = _real_ready
        return got, dropped, _real_open(log, encoding="utf-8").read()

    got, dropped, logtext = _rollback_with([0], True)
    assert dropped, "0x79 曲线写一个都没被丢弃 —— 本用例的故障没有真的注入"
    assert got == "cool", "守护没起来时应回滚到 cool，实际返回 %r" % (got,)
    last = _last_fsl(dev)
    assert last is not None and last >= pfanel.MIN_SAFE_LEVEL, (
        "EC 写被丢弃、读回 0 时最后一次 _FSL 写入是 %r —— 回滚停在 _FSL 0 上，"
        "风扇停转，而 cool 不在 GUARDED 里没有任何东西在看它（0 在 ACPI 里就是停转）"
        % (last,)
    )
    assert "未交回成功" in logtext, (
        "兜底写必须留日志，事后才分得清是回滚没生效还是根本没检查：%r" % (logtext,)
    )

    _got2, dropped2, _log2 = _rollback_with([44], False)
    assert not dropped2, "反向对照里曲线写不该被丢弃"
    assert _got2 == "cool", "反向对照里守护同样没起来，应同样回滚到 cool：%r" % (_got2,)
    last2 = _last_fsl(dev)
    assert last2 is None, (
        "固件已经接管（EC=44）时最后写下去的却是 _FSL 1 %r —— 无条件兜底会把每次"
        "正常切 cool/quiet 都降成手动档位，那是另一种事故" % (last2,)
    )


def test_rollback_that_raises_still_leaves_a_non_stopping_level_and_a_log():
    """回滚自己抛异常时：异常不许逃出 set_curve，风扇不许留在 _FSL 0，失败必须留痕。

    旧实现是裸的 `rolled = set_curve("cool")`，而 acpi() 在设备锁/权限故障下会抛
    —— 异常穿过 set_curve("cool") 出去，回滚半途而废、_FSL 还停在 s0i3 分支
    刚写下的 0 上，而且一条日志都没有。那条路径刻意用 except OSError 保护了
    【日志写】，却没保护【回滚本身】，而后者才是保命的那一步。
    """
    dev = os.environ["PFAN_DEV"]
    curve_file = os.environ["PFAN_CURVE_FILE"]
    log = os.path.join(os.path.dirname(dev), "pfanel.log")
    import subprocess as _sp

    _real_run, _real_open, _real_acpi = _sp.run, builtins.open, pfanel.acpi
    _real_ready = getattr(pfanel, "_daemon_ready", None)

    class _WedgedEc(Exception):
        pass

    def _acpi(path, args=""):
        # 只让【cool 的曲线写】抛：s0i3 自己那一次必须落地，
        # 否则用例死在回滚之前，测的就不是"回滚抛异常"这件事了。
        if str(path) == pfanel.EC88 and "0x79 0x00" in str(args):
            raise _WedgedEc("设备锁/权限故障（模拟）")
        return _real_acpi(path, args)

    with open(curve_file, "w", encoding="utf-8") as fh:
        json.dump({"curve": "auto", "level": 0}, fh)
    open(dev, "w").close()
    open(log, "w").close()
    _sp.run = _systemctl_stub("inactive", _real_run)
    pfanel.acpi = _acpi
    pfanel.open = lambda p, *a, **k: (
        _real_open(log, "a")
        if str(p) == "/var/log/pfanel.log"
        else _real_open(p, *a, **k)
    )
    pfanel._daemon_ready = lambda *a, **k: False
    try:
        got = pfanel.set_curve("s0i3")   # 抛出去本身就是缺陷
    finally:
        _sp.run = _real_run
        pfanel.open = _real_open
        pfanel.acpi = _real_acpi
        if _real_ready is None:
            pfanel.__dict__.pop("_daemon_ready", None)
        else:
            pfanel._daemon_ready = _real_ready
    last = _last_fsl(dev)
    assert last is not None and last >= pfanel.MIN_SAFE_LEVEL, (
        "回滚抛异常后最后一次 _FSL 写入是 %r —— 风扇停在 _FSL 0 上且没有日志（0 = 停转）"
        % (last,)
    )
    logtext = _real_open(log, encoding="utf-8").read()
    assert "回滚未完成" in logtext, (
        "回滚失败必须如实记录；写成【已回滚到 cool】是一条事后没人能核对的谎：%r"
        % (logtext,)
    )
    assert "回滚未完成" in got, (
        "返回值必须带出【回滚没完成】，不能谎称已回滚：%r" % (got,)
    )


def test_daemon_ready_waits_for_the_fan_to_settle_before_its_first_read():
    """终审 I2：第一读之前必须等稳，否则读数比判据早、风扇比判据慢。

    这个函数是在 `acpi(FSL,"1 0") + acpi(EC88, s0i3)` 之后约 0.5s 被调用的，
    此刻 EC 0x76 报的仍是切换前的转速；守护真在跑而 _FSL 还是 0 时，
    立刻读到非零就判成"就绪"。auto 分支早就为同一件事等过 1.6s。
    判据是【顺序】：ec76 读必须排在 settle 等待【之后】，不是"某处有个 sleep"。
    """
    import subprocess as _sp

    _real_run, _real_ec, _real_time = _sp.run, pfanel.get_ec76, pfanel.time
    events = []

    class _Clock:
        def sleep(self, s):
            events.append(("sleep", round(float(s), 3)))

        def __getattr__(self, name):
            return getattr(_real_time, name)

    pfanel.time = _Clock()
    pfanel.get_ec76 = lambda: (events.append(("ec76",)), 30)[1]
    _sp.run = lambda *a, **k: _Proc("active\n")
    try:
        assert pfanel._daemon_ready(timeout_s=1, interval=0.1) is True, (
            "守护 active 且设备读回 30 时必须判成就绪，否则正常切换会一直被回滚"
        )
    finally:
        _sp.run = _real_run
        pfanel.get_ec76 = _real_ec
        pfanel.time = _real_time
    kinds = [e[0] for e in events]
    assert "ec76" in kinds, "本用例根本没有走到读 EC 那一步：%r" % (events,)
    first_ec = kinds.index("ec76")
    waits = [v for k, v in events[:first_ec] if k == "sleep"]
    assert waits, (
        "第一读 EC 之前一次都没等 —— 读数比判据早：守护刚 restart、_FSL 还是 0 时，"
        "EC 0x76 报的仍是切换前的转速，读到非零就判成【就绪】。事件=%r" % (events,)
    )
    # R-13：这里原先写的是 `max(waits) >= pfanel.HANDOVER_SETTLE_S` —— 恒真的
    # 同义反复：waits 记录的就是 time.sleep(settle)，而 settle 的缺省值正是那个
    # 常量，拿常量与自己比只能蒙对。改成对独立字面下界断言：固件接管不是瞬时的，
    # 低于 1s 的"等稳"等于没等；上限 5s 是延迟预算。1.6->0.001 的变异因此转红。
    assert 1.0 <= max(waits) <= 5.0, (
        "第一读之前最长只等了 %rs，越出 [1.0, 5.0] —— 等得不够久等于没等，"
        "等太久是纯延迟；事件=%r" % (max(waits), events)
    )


def test_daemon_ready_still_attempts_once_when_settle_eats_the_whole_budget():
    """settle 大于 timeout_s 时也必须做【至少一次】真实尝试。

    写成 `while now < deadline` 的话，settle 睡完就已经越过 deadline，
    循环体一次都不执行，直接返回 False —— 那不是"未就绪"，是"没检查"，
    而调用方会把两者当成同一件事。这里用可控时钟把时间轴摊平来验证。
    """
    import subprocess as _sp

    _real_run, _real_ec, _real_time = _sp.run, pfanel.get_ec76, pfanel.time
    attempts = []

    class _Clock:
        """虚拟时钟：sleep 只推进虚拟时间，本用例因此是零等待的。"""

        def __init__(self):
            self.t = 1000.0

        def sleep(self, s):
            self.t += float(s)

        def time(self):
            return self.t

        def __getattr__(self, name):
            return getattr(_real_time, name)

    clock = _Clock()

    def _ec():
        attempts.append(clock.t)
        return 30

    pfanel.time = clock
    pfanel.get_ec76 = _ec
    _sp.run = lambda *a, **k: _Proc("active\n")
    try:
        # settle(5) 恰好等于 timeout_s(5)：老写法在这一档上一次都不试。
        got = pfanel._daemon_ready(timeout_s=5, interval=1, settle=5)
    finally:
        _sp.run = _real_run
        pfanel.get_ec76 = _real_ec
        pfanel.time = _real_time
    assert attempts, (
        "settle 吃掉了整个预算后一次都没试过就返回 —— 那是【没检查】，不是【未就绪】"
    )
    assert got is True, "做了一次真实尝试（守护 active + EC=30）却判未就绪：%r" % (got,)


# ---------------- 终审 Minor 4/5：回落下限只有一份，且真的被当常量用 ----------------


def test_min_safe_level_is_derived_from_the_shared_floor_not_a_third_copy():
    """MIN_SAFE_LEVEL 必须【派生】自 pfan_core.L0_MIN，而不是再抄一份 25。

    同一个下限在本仓库里有三处出处：pfan_core.L0_MIN、min(pfan_core.FPS)、
    以及【本分支新增的】pfanel.MIN_SAFE_LEVEL —— 而新增那处的注释恰好写着
    "表只有一份"。值相同，所以只断言数值相等根本抓不住它（25 == 25）。
    真正要守的是"它是派生来的"，所以这里解析 AST 看赋值的右端：
    字符串包含会被一次自动折行静默废掉（见本文件 test_state_seam_defaults_equal_production
    记过的 2026-10-08 实例），AST 是结构上的，折行/改引号都影响不到它。
    """
    import ast as _ast
    import inspect

    import pfan_core

    assert pfanel.MIN_SAFE_LEVEL == pfan_core.L0_MIN, (
        "MIN_SAFE_LEVEL=%r != pfan_core.L0_MIN=%r"
        % (pfanel.MIN_SAFE_LEVEL, pfan_core.L0_MIN)
    )
    assert pfanel.MIN_SAFE_LEVEL == min(pfan_core.FPS), (
        "L0_MIN 与 _FPS 表最低档分叉了：%r vs %r"
        % (pfanel.MIN_SAFE_LEVEL, min(pfan_core.FPS))
    )
    tree = _ast.parse(inspect.getsource(pfanel))
    assigns = [
        n
        for n in tree.body
        if isinstance(n, _ast.Assign)
        and any(isinstance(t, _ast.Name) and t.id == "MIN_SAFE_LEVEL" for t in n.targets)
    ]
    assert len(assigns) == 1, "MIN_SAFE_LEVEL 的模块级赋值应恰好一处，实际 %d" % len(assigns)
    rhs = assigns[0].value
    assert isinstance(rhs, _ast.Name) and rhs.id == "L0_MIN", (
        "MIN_SAFE_LEVEL 的右端是 %s 而不是 L0_MIN —— 这是又一份会漂移的硬编码副本"
        % (_ast.dump(rhs),)
    )


def test_auto_fallback_writes_the_min_safe_level_constant():
    """auto 分支的兜底档位必须走 MIN_SAFE_LEVEL 常量，不能是又硬编码的 25。

    做法是把常量临时改成一个 25 以外的值再跑 auto 分支：如果实现写的是常量，
    设备上就是那个新值；如果写的是字面量 25，设备上就是 25 —— 两种实现就此可区分。
    旧注释曾声称 auto 的兜底值是 MIN_SAFE_LEVEL，实际上那一行写的是硬编码 25，
    所以这条断言在修复前就是红的。
    """
    dev = os.environ["PFAN_DEV"]
    curve_file = os.environ["PFAN_CURVE_FILE"]
    log = os.path.join(os.path.dirname(dev), "pfanel.log")
    import subprocess as _sp

    _real_run, _real_open = _sp.run, builtins.open
    _real_time, _real_ec = pfanel.time, pfanel.get_ec76
    _real_min = pfanel.MIN_SAFE_LEVEL

    class _NoSleep:
        def sleep(self, _s):
            return None

        def __getattr__(self, name):
            return getattr(_real_time, name)

    with open(curve_file, "w", encoding="utf-8") as fh:
        json.dump({"curve": "auto", "level": 0}, fh)
    open(dev, "w").close()
    open(log, "w").close()
    _sp.run = _systemctl_stub("inactive", _real_run)
    pfanel.time = _NoSleep()
    # get_ec76 这里【不打桩】：夹具已改成生产形状（EC 读回裸整数），auto 分支刚写过
    # `_FSL 1 0` 所以记住的档位是 0，真解析读回来的就是 0 -> 必须兜底。
    # 曾经这里是 `lambda: 0`，于是整条兜底路径一次都没跑过真解析。
    pfanel.MIN_SAFE_LEVEL = 33         # 故意与 25 不同
    pfanel.open = lambda p, *a, **k: (
        _real_open(log, "a")
        if str(p) == "/var/log/pfanel.log"
        else _real_open(p, *a, **k)
    )
    try:
        got = pfanel.set_curve("auto")
    finally:
        _sp.run = _real_run
        pfanel.open = _real_open
        pfanel.time = _real_time
        pfanel.MIN_SAFE_LEVEL = _real_min
    assert got == "auto"
    last = _last_fsl(dev)
    assert last == 33, (
        "auto 的兜底写的是 %r 而不是 MIN_SAFE_LEVEL(33) —— 说明那行仍是硬编码字面量" % (last,)
    )


def test_daemon_ready_needs_the_unit_and_the_device_to_agree():
    """① systemctl active 与 ② 设备读回非零档位必须同时成立，缺一即未就绪。

    只查 ① 的实现会在握手窗口里判成就绪：core/pfand 的 ensure_s0i3() 先写
    `_FSL 1 0` 再写 EC88（中间 sleep 0.3），守护进程活着，_FSL 是 0。
    三个方向都要压：只有守护 / 只有设备 / 两个都有。
    """
    import subprocess as _sp

    _real_run, _real_ec = _sp.run, pfanel.get_ec76
    state = {"unit": "active", "ec": 0}
    pfanel.get_ec76 = lambda: state["ec"]
    _sp.run = lambda *a, **k: _Proc(state["unit"] + "\n")
    try:
        assert not pfanel._daemon_ready(timeout_s=0.2, interval=0.05), (
            "守护 active 但设备读回 0 档位时判成就绪 —— ensure_s0i3 的握手窗口会被放过"
        )
        state["ec"] = 30
        assert pfanel._daemon_ready(timeout_s=0.2, interval=0.05), (
            "守护 active 且设备读回 30 档位时必须判成就绪，否则正常切换会一直被回滚"
        )
        state["unit"] = "inactive"
        assert not pfanel._daemon_ready(timeout_s=0.2, interval=0.05), (
            "设备读回 30 但守护没 active 时判成就绪 —— 档位可能是【上一次】留下的"
        )
    finally:
        _sp.run = _real_run
        pfanel.get_ec76 = _real_ec


def test_firmware_curves_never_wait_for_the_daemon():
    """RF4：守护【故意】停着的曲线一条都不许等守护就绪。

    core/pfand 在曲线非 s0i3 时 exit 0，那是设计不是故障。对应四条曲线：
    auto（交回固件）、quiet / cool（固件自己的曲线）、free（档位由面板直接控）。
    判据只属于 s0i3 分支 —— 只有那里"守护不来"等于把风扇留在 _FSL 0 上（停转）；
    其余曲线上守护不来正是【预期】，套上判据就会把用户选的曲线回滚成 cool。

    两条断言，缺一不可：
      ① 返回值与持久化都仍是请求的曲线 —— 判据若带完整回滚，这里会变成 cool；
      ② _daemon_ready 一次都没被调用 —— 2026-10-11 实测：只往 free 分支注入一个
         【裸调用】（不改返回流程）时，持久化的曲线根本没变，只有"调用发生过"是
         唯一可观测的差异。只断言 ① 的版本对此全绿放行，那正是本条最初漏掉 free
         的原因（上一版只覆盖了 quiet/cool）。

    全程【行为】断言，不看源码形状：字符串包含会被一次自动折行静默废掉 ——
    那正是本文件 test_state_seam_defaults_equal_production 注释里记过的
    2026-10-08 实例，"格式化器悄悄废掉安全守卫，比没有守卫更危险"。
    """
    import subprocess as _sp

    _real_run = _sp.run
    _real_ready = getattr(pfanel, "_daemon_ready", None)
    _real_open, _real_time = builtins.open, pfanel.time
    dev = os.environ["PFAN_DEV"]
    log = os.path.join(os.path.dirname(dev), "pfanel.log")
    curve_file = os.environ["PFAN_CURVE_FILE"]
    calls = []

    def _never_ready(*a, **k):
        calls.append(1)
        return False

    class _NoSleep:
        """只有 sleep 变空操作，其余属性全部转给真 time 模块。

        auto 分支里的 time.sleep(1.6) 是等固件接管曲线；假设备后面没有固件，
        这一等不可能改变"哪条曲线被写进 curve.state"。连同 acpi() 每次调用的
        轮询 sleep 一起桩掉，本条实测 5.14s -> 1.80s（tests/python 已 ~74s）。
        _result_state() 判"有没有新结果"用的是假 dmesg 自己的递增计数，不是墙钟，
        所以桩掉 sleep 不会让 acpi() 读不到 RESULT。
        """

        def sleep(self, _s):
            return None

        def __getattr__(self, name):
            return getattr(_real_time, name)

    _sp.run = _systemctl_stub("inactive", _real_run)
    pfanel._daemon_ready = _never_ready
    pfanel.time = _NoSleep()
    pfanel.open = lambda q, *a, **k: (
        _real_open(log, "a")
        if str(q) == "/var/log/pfanel.log"
        else _real_open(q, *a, **k)
    )
    try:
        for want in ("auto", "quiet", "cool", "free"):
            # 起点写一个 CURVES 里根本不存在的曲线名：断言"写进去的正是请求的曲线"
            # 才不会因为起点恰好相等而空过 —— auto 那条尤其要防这个。
            with open(curve_file, "w", encoding="utf-8") as fh:
                json.dump({"curve": "nonexistent", "level": 0}, fh)
            got = pfanel.set_curve(want)
            assert got == want, (
                "请求 %r 却拿到 %r —— 判据被套到守护本来就该停着的曲线上并回滚了"
                % (want, got)
            )
            st = pfanel.get_state()
            assert st["curve"] == want, (
                "请求 %r 却把 %r 持久化了 —— 固件接管被换成了另一种曲线" % (want, st["curve"])
            )
            assert not calls, (
                "%s 分支调用了 _daemon_ready —— 这条曲线上守护本来就该是停的，"
                "没有【就绪】可等（core/pfand 在非 s0i3 曲线下 exit 0 是设计）"
                % (want,)
            )
    finally:
        _sp.run = _real_run
        pfanel.open = _real_open
        pfanel.time = _real_time
        if _real_ready is None:
            pfanel.__dict__.pop("_daemon_ready", None)
        else:
            pfanel._daemon_ready = _real_ready
        pfanel._APPLIED = False


def test_s0i3_restore_must_not_write_a_level_from_the_backend():
    """RF5：s0i3 下档位由守护写，后端【不该】自己写。

    apply_persisted_state 在 curve==s0i3 时只重启守护就返回；如果这条分支也写了
    档位，后端与守护会各写一次，而两者算出的 base/trim 可能不同 —— 表现为风扇抖动。
    """
    pfanel._APPLIED = False
    dev = os.environ["PFAN_DEV"]
    log = os.path.join(os.path.dirname(dev), "pfanel.log")
    with open(os.environ["PFAN_CURVE_FILE"], "w", encoding="utf-8") as fh:
        json.dump({"curve": "s0i3", "level": 40}, fh)
    open(dev, "w").close()
    import builtins as _b
    import subprocess as _sp

    _real_run, _real_open = _sp.run, _b.open
    _sp.run = _systemctl_stub("active", _real_run)
    pfanel.open = lambda p, *a, **k: (
        _real_open(log, "a")
        if str(p) == "/var/log/pfanel.log"
        else _real_open(p, *a, **k)
    )
    try:
        pfanel.apply_persisted_state()
    finally:
        _sp.run = _real_run
        pfanel.open = _real_open
        pfanel._APPLIED = False
    fsl = [
        l for l in _real_open(dev, encoding="utf-8").read().splitlines() if "_FSL" in l
    ]
    # s0i3 分支会写 _FSL 1 0（交回控制权），但【不应】再写一个具体档位
    nonzero = [l for l in fsl if not l.rstrip().endswith("_FSL 1 0")]
    assert not nonzero, (
        "s0i3 还原时后端写了具体档位 %r —— 应由守护写，否则两个写者会打架" % nonzero
    )


# ---------------- 终审 Minor 3：预算守卫必须有覆盖 -----------------------------
# `now + interval >= deadline` 是唯一拦着"预算用完了还再发一次 systemctl"的行。
# 它此前是零覆盖：删掉它，全部测试照样绿。断言的对象是【尝试次数】而不是时间轴 ——
# 时间轴本身就是被测代码算出来的，拿它当期望值等于自己验自己。


def test_daemon_ready_never_starts_an_attempt_past_the_budget():
    """剩余时间留不下一整次轮询时就不许再发一次 systemctl。

    do-while 的结构决定了第一读永远会做（见上一条），所以能超额发起的只有
    第二读及以后：某一次尝试结束时若 now + interval < deadline，循环就再睡一轮
    并重试。少了 `now + interval >= deadline` 那一半，那个"再睡一轮"会在预算
    刚好用尽时照发，于是多出一次【整次成本都落在预算之外】的尝试 ——
    一次尝试的上界是 systemctl 的 5s 加 acpi() 的 2.4s 轮询。

    断言写成"每一次尝试的开始时刻都严格早于 deadline"：这条在删掉守卫后立刻
    为假（会多出一次恰好落在 deadline 上的尝试），而不是靠数次数那种脆弱写法。
    虚拟时钟让本用例零等待。
    """
    import subprocess as _sp

    _real_run, _real_ec, _real_time = _sp.run, pfanel.get_ec76, pfanel.time

    class _Clock:
        def __init__(self):
            self.t = 1000.0

        def sleep(self, s):
            self.t += float(s)

        def time(self):
            return self.t

        def __getattr__(self, name):
            return getattr(_real_time, name)

    for timeout_s, interval, want in ((5, 1, 5), (2, 0.5, 4), (1, 0.25, 4)):
        clock = _Clock()
        attempts = []

        def _run(*a, **k):
            attempts.append(clock.t)
            return _Proc("inactive\n")      # 永不 active -> 循环只受预算支配

        pfanel.time = clock
        pfanel.get_ec76 = lambda: None
        _sp.run = _run
        try:
            got = pfanel._daemon_ready(timeout_s=timeout_s, interval=interval, settle=0)
        finally:
            _sp.run = _real_run
            pfanel.get_ec76 = _real_ec
            pfanel.time = _real_time
        deadline = 1000.0 + timeout_s
        assert attempts, "(%s,%s) 一次都没试过 —— 那是【没检查】不是【未就绪】" % (
            timeout_s, interval)
        assert max(attempts) < deadline, (
            "有一次 systemctl 发起于 t=%r，已经在 deadline=%r 之外或正好压线"
            "（timeout=%s, interval=%s）—— 预算用完之后还发起的尝试，"
            "它的整次成本都落在预算之外" % (max(attempts), deadline, timeout_s, interval)
        )
        assert got is False, "守护全程 inactive 却判成就绪：%r" % (got,)
        assert len(attempts) == want, (
            "尝试次数是 %d，期望 %d（timeout=%s, interval=%s）"
            % (len(attempts), want, timeout_s, interval)
        )


# ---------------- 终审 Minor 4：EC 读的 RESULT 形状，夹具而不是测试 -------------


def _device_requests():
    """假设备的【累计】请求流水（每一条 ACPI 写都留痕）。

    不能用 _last_fsl：acpi() 每次以 "w" 打开设备，文件里只剩最后一次写入，而
    交回后置条件的 EC 读恰好是最后一次 —— 于是"有没有兜底写"根本看不见。
    """
    with open(os.environ["PFAN_DMESG_LOG"], encoding="utf-8") as fh:
        return [ln.strip() for ln in fh if ln.strip()]


def _reset_device_requests():
    open(os.environ["PFAN_DMESG_LOG"], "w").close()


def _fake_device_env(ec_word=None):
    """把假设备的 EC 0x76 读回值设好；返回恢复函数。"""
    prev = os.environ.get("PFAN_DMESG_EC")

    def _restore():
        if prev is None:
            os.environ.pop("PFAN_DMESG_EC", None)
        else:
            os.environ["PFAN_DMESG_EC"] = prev

    if ec_word is None:
        os.environ.pop("PFAN_DMESG_EC", None)
    else:
        os.environ["PFAN_DMESG_EC"] = str(ec_word)
    return _restore


def test_get_ec76_parses_the_two_production_result_shapes():
    """get_ec76 的真解析必须跑在生产形状上，而不是被夹具喂一个假形状。

    pfanctl.c 的 dump_obj 按 ACPI 对象类型打印：ACPI_TYPE_INTEGER 打成【裸整数】，
    ACPI_TYPE_PACKAGE 打成 `[a,b,c]`。实机上 _FSL 写与 _FST 读是 Package，
    EC 0x76 读是 Integer。旧夹具对所有请求都吐 Package，于是 get_ec76 的
    `int(r.split()[0])` 对着 `[0,40,4294967295]` 抛 ValueError、被 except 吞掉、
    恒返回 None —— 本条在夹具修好之前必然是红的（它就是那次修复的验收）。

    同一份 RESULT 值有两个读者：read_pkg 按 Package 解（get_level 用），
    get_ec76 按 Integer 解。夹具若把两者混成一个形状，这两个读者就会对同一份
    数据给出互相矛盾的答案，而且没人会发现。
    """
    restore = _fake_device_env(44 << 8)
    try:
        got = pfanel.get_ec76()
        assert got == 44, (
            "夹具报出 EC=11264(=44<<8) 时 get_ec76 必须解出 44，实际 %r —— "
            "解析没走在生产形状上（裸整数），或者 byte1 的取法变了" % (got,)
        )
        ec_line = pfanel.acpi(pfanel.EC88, "4 181 118 0 0")
        assert ec_line is not None and ec_line.strip().isdigit(), (
            "EC 读的 RESULT 必须是【裸整数】（dump_obj 对 ACPI_TYPE_INTEGER 的打印），"
            "实际拿到 %r —— 夹具形状回退成了 Package" % (ec_line,)
        )
        fst_line = pfanel.acpi(pfanel.FST)
        assert pfanel.read_pkg(fst_line) and len(pfanel.read_pkg(fst_line)) >= 2, (
            "_FST 读的 RESULT 必须是 Package（read_pkg 读得动），实际 %r" % (fst_line,)
        )
    finally:
        restore()

    for word, want, why in (
        (0, 0, "EC=0 是【交回没生效】那一侧，必须原样解出 0 而不是 None"),
        (4294967295, None, "0xFFFFFFFF 是固件的无效哨兵，必须解成 None"),
    ):
        restore = _fake_device_env(word)
        try:
            got = pfanel.get_ec76()
            assert got == want, (
                "夹具报出 EC=%r 时 get_ec76 必须是 %r，实际 %r —— %s"
                % (word, want, got, why)
            )
        finally:
            restore()


def test_auto_handover_success_needs_no_fallback_write():
    """auto 交回【成功】那一侧：真解析读到非零时不得有任何兜底写。

    与 test_auto_fallback_writes_the_min_safe_level_constant 成对：那条走失败侧
    （EC=0），这条走成功侧。两条都对着夹具跑真解析，所以"读不出来"与"读到 0"
    不再是同一种情况、也不再靠打桩制造。
    """
    dev = os.environ["PFAN_DEV"]
    curve_file = os.environ["PFAN_CURVE_FILE"]
    log = os.path.join(os.path.dirname(dev), "pfanel.log")
    import subprocess as _sp

    _real_run, _real_open, _real_time = _sp.run, builtins.open, pfanel.time
    restore_ec = _fake_device_env(44 << 8)

    class _NoSleep:
        def sleep(self, _s):
            return None

        def __getattr__(self, name):
            return getattr(_real_time, name)

    with open(curve_file, "w", encoding="utf-8") as fh:
        json.dump({"curve": "s0i3", "level": 0}, fh)
    open(dev, "w").close()
    open(log, "w").close()
    _reset_device_requests()
    _sp.run = _systemctl_stub("inactive", _real_run)
    pfanel.time = _NoSleep()
    pfanel.open = lambda p, *a, **k: (
        _real_open(log, "a")
        if str(p) == "/var/log/pfanel.log"
        else _real_open(p, *a, **k)
    )
    try:
        got = pfanel.set_curve("auto")
    finally:
        _sp.run = _real_run
        pfanel.open = _real_open
        pfanel.time = _real_time
        restore_ec()
    assert got == "auto"
    logtext = _real_open(log, encoding="utf-8").read()
    assert "未交回成功" not in logtext, (
        "EC 读到 44（固件已接管）却仍然判成未交回成功并写了兜底档位 —— "
        "这会把每次正常交回都降成手动档位：%r" % (logtext,)
    )
    reqs = _device_requests()
    fallback = "_FSL 1 %d" % pfanel.MIN_SAFE_LEVEL
    assert not [r for r in reqs if r.endswith(fallback)], (
        "EC=44 时设备上仍然收到了 %s —— 成功侧多写了一次兜底档位：%r"
        % (fallback, reqs)
    )
    assert [r for r in reqs if r.endswith("_FSL 1 0")], (
        "整次切换连交回本身的 _FSL 1 0 都没写出去，本用例什么也没验到：%r" % (reqs,)
    )


def test_cool_handover_success_needs_no_fallback_write():
    """quiet/cool 交回【成功】那一侧：真解析读到非零时不得有兜底写。

    与 test_rollback_to_cool_verifies_the_handover_before_returning 的第二条方向
    互补：那条把 get_ec76 整个打桩来造"固件真的接管"，所以它验证的是
    set_curve 的分支逻辑；本条让真的 acpi()、真的假 dmesg、真的解析跑一遍。
    夹具修好之前本条不可能通过（真解析恒为 None，只能走兜底那一侧）。
    """
    dev = os.environ["PFAN_DEV"]
    curve_file = os.environ["PFAN_CURVE_FILE"]
    log = os.path.join(os.path.dirname(dev), "pfanel.log")
    import subprocess as _sp

    _real_run, _real_open, _real_time = _sp.run, builtins.open, pfanel.time
    restore_ec = _fake_device_env(44 << 8)

    class _NoSleep:
        def sleep(self, _s):
            return None

        def __getattr__(self, name):
            return getattr(_real_time, name)

    with open(curve_file, "w", encoding="utf-8") as fh:
        json.dump({"curve": "nonexistent", "level": 0}, fh)
    open(dev, "w").close()
    open(log, "w").close()
    _reset_device_requests()
    _sp.run = _systemctl_stub("inactive", _real_run)
    pfanel.time = _NoSleep()
    pfanel.open = lambda p, *a, **k: (
        _real_open(log, "a")
        if str(p) == "/var/log/pfanel.log"
        else _real_open(p, *a, **k)
    )
    try:
        got = pfanel.set_curve("cool")
    finally:
        _sp.run = _real_run
        pfanel.open = _real_open
        pfanel.time = _real_time
        restore_ec()
    assert got == "cool"
    logtext = _real_open(log, encoding="utf-8").read()
    assert "未交回成功" not in logtext, (
        "EC 读到 44（固件已接管）却仍然判成未交回成功并写了兜底档位：%r" % (logtext,)
    )
    reqs = _device_requests()
    fallback = "_FSL 1 %d" % pfanel.MIN_SAFE_LEVEL
    assert not [r for r in reqs if r.endswith(fallback)], (
        "EC=44 时设备上仍然收到了 %s —— 成功侧多写了一次兜底档位：%r"
        % (fallback, reqs)
    )
    assert [r for r in reqs if r.endswith("_FSL 1 0")], (
        "整次切换连交回本身的 _FSL 1 0 都没写出去，本用例什么也没验到：%r" % (reqs,)
    )


def test_firmware_curve_handover_waits_before_its_first_ec_read():
    """终审 Minor 1：quiet/cool 的交回读之前必须等稳（原来注释里的理由是假的）。

    这一分支原先没有等，且注释声称"写接口本来就已经 sleep 2s"。那是假的：
    写接口的 time.sleep(2) 在 do_POST 里 set_curve()【返回之后】才执行。
    判据是【顺序】：EC 读必须排在 settle 等待【之后】，不是"某处有个 sleep"。
    """
    import subprocess as _sp

    _real_run, _real_open, _real_acpi, _real_time = (
        _sp.run,
        builtins.open,
        pfanel.acpi,
        pfanel.time,
    )
    dev = os.environ["PFAN_DEV"]
    log = os.path.join(os.path.dirname(dev), "pfanel.log")
    events = []

    class _Clock:
        def sleep(self, s):
            events.append(("sleep", round(float(s), 3)))

        def __getattr__(self, name):
            return getattr(_real_time, name)

    def _acpi(path, args=""):
        if str(path) == pfanel.EC88 and "118" in str(args):
            events.append(("ec76", args))
            return "11264"          # 44 << 8：真解析也认这个形状
        return _real_acpi(path, args)

    open(dev, "w").close()
    open(log, "w").close()
    _sp.run = _systemctl_stub("inactive", _real_run)
    pfanel.time = _Clock()
    pfanel.acpi = _acpi
    pfanel.open = lambda p, *a, **k: (
        _real_open(log, "a")
        if str(p) == "/var/log/pfanel.log"
        else _real_open(p, *a, **k)
    )
    try:
        got = pfanel.set_curve("cool")
    finally:
        _sp.run = _real_run
        pfanel.open = _real_open
        pfanel.acpi = _real_acpi
        pfanel.time = _real_time
    assert got == "cool"
    kinds = [e[0] for e in events]
    assert "ec76" in kinds, "本用例根本没走到读 EC 那一步：%r" % (events,)
    first_ec = kinds.index("ec76")
    waits = [v for k, v in events[:first_ec] if k == "sleep"]
    assert waits, (
        "第一读 EC 之前一次都没等 —— 从 s0i3 切过来时，过早的读拿到的是"
        "【切换前】的非零转速，楔住的 EC 会被判成【交回成功】、兜底不写，"
        "而 EC 还停在 s0i3、_FSL 停在 0（= 停转）。事件=%r" % (events,)
    )
    # 同 test_daemon_ready_waits_for_the_fan_to_settle_before_its_first_read（R-13）：
    # 独立字面下界，不拿常量与自己比；1.6->0.001 的变异在这里同样转红。
    assert 1.0 <= max(waits) <= 5.0, (
        "第一读之前最长只等了 %rs，越出 [1.0, 5.0] —— 等得不够久等于没等；"
        "事件=%r" % (max(waits), events)
    )
# ---------------- R-02：free 的起点不许是 _FSL 0（F2 的活体孪生） ----------------
# 实测（2026-10-17，HEAD）：POST /api/profile {"profile":"free"} 先 stop pfand，
# 再写 `_FSL 1 0` + EC88 s0i3 就返回 —— s0i3 下 0 就是停转，守护已停、没有任何
# 后验；唯一的安全网是 82°C 看门狗。quiet/cool/auto/s0i3 全都有交回后置条件，
# 只有 free 没有，属遗漏。修法与 core/pfand 的 ensure_s0i3（R-01）同一手法：
# 写【当前档位】（读不到/低于下限退 MIN_SAFE_LEVEL），交回后按 quiet/cool 的
# 口径等稳、读 EC，为 0/读不到就兜底 —— 两处必须一致。


def test_free_curve_starts_from_the_current_level_not_stop():
    """free 的起点写当前档位（不是 0），EC 未接管时按 quiet/cool 口径兜底。

    两个方向都跑，缺一不可：
      ① 当前档位 50、EC 正常读回 -> 起点写 50、全程不出现 _FSL 0、无兜底写；
      ② EC 的 0x79 写被丢弃、读回 0 -> 最后一次 _FSL 写必须是 MIN_SAFE_LEVEL 兜底。
    只跑 ② 的话，"无条件写兜底"的实现也全绿，那会把每次切 free 都压成 25%；
    只跑 ① 则本缺陷（留在停转）完全看不见。
    """
    dev = os.environ["PFAN_DEV"]
    curve_file = os.environ["PFAN_CURVE_FILE"]
    state = os.environ["PFAN_DMESG_STATE"]
    log = os.path.join(os.path.dirname(dev), "pfanel.log")
    import re as _re
    import subprocess as _sp

    _real_run, _real_open, _real_acpi = _sp.run, builtins.open, pfanel.acpi
    _real_ec, _real_time = pfanel.get_ec76, pfanel.time

    class _NoSleep:
        def sleep(self, _s):
            return None

        def __getattr__(self, name):
            return getattr(_real_time, name)

    def _free(keep_level, ec_fn, drop_curve_write):
        with open(curve_file, "w", encoding="utf-8") as fh:
            json.dump({"curve": "s0i3", "level": 50}, fh)
        open(dev, "w").close()
        open(log, "w").close()
        _reset_device_requests()
        # 假设备的"当前档位"：get_level() 读的 _FST 由它回答
        if keep_level is None:
            if os.path.exists(state):
                os.remove(state)
        else:
            with open(state, "w", encoding="utf-8") as fh:
                fh.write(str(keep_level))
        dropped = []

        def _acpi(path, args=""):
            # 楔住的 EC：0x79 曲线写既不落到设备也不回 RESULT
            if drop_curve_write and str(path) == pfanel.EC88 and "0x79" in str(args):
                dropped.append(args)
                return None
            return _real_acpi(path, args)

        _sp.run = _systemctl_stub("inactive", _real_run)
        pfanel.acpi = _acpi
        pfanel.get_ec76 = ec_fn
        pfanel.time = _NoSleep()
        pfanel.open = lambda p, *a, **k: (
            _real_open(log, "a")
            if str(p) == "/var/log/pfanel.log"
            else _real_open(p, *a, **k)
        )
        try:
            got = pfanel.set_curve("free")
        finally:
            _sp.run = _real_run
            pfanel.open = _real_open
            pfanel.acpi = _real_acpi
            pfanel.get_ec76 = _real_ec
            pfanel.time = _real_time
        reqs = _device_requests()
        fsl = [
            int(m.group(1))
            for m in (_re.search(r"_FSL 1 (\d+)$", r) for r in reqs)
            if m
        ]
        return got, dropped, fsl, reqs, _real_open(log, encoding="utf-8").read()

    # ① 正常侧
    got, dropped, fsl, reqs, logtext = _free(50, _real_ec, False)
    assert not dropped, "正常侧不该丢弃任何 0x79 写"
    assert got == "free" and pfanel.get_state()["curve"] == "free"
    assert fsl, "free 切换一个 _FSL 都没写 —— 本用例什么也没验到"
    assert 0 not in fsl, (
        "free 交回写了 _FSL 0（= 停转，而守护已停、没有后验）: %r" % (fsl,)
    )
    assert fsl[0] == 50, (
        "free 的起点档位应是【当前档位 50】，实际 %r —— 写死下限会把用户档位压成 25"
        % (fsl[0],)
    )
    i_fsl = next(i for i, r in enumerate(reqs) if r.endswith("_FSL 1 50"))
    i_ec = next(i for i, r in enumerate(reqs) if "EC88" in r and "0x79" in r)
    assert i_fsl < i_ec, (
        "握手形状必须仍是【先 _FSL 写、后 EC88 写】（与 core/pfand 一致）：%r" % (reqs,)
    )
    ec_after = pfanel.get_ec76()
    assert ec_after and ec_after > 0, "free 切换后 EC 读回 %r（0 = 停转）" % (ec_after,)
    assert "未落到设备" not in logtext and "直接写 _FSL" not in logtext, (
        "EC 正常读回 50 却仍然兜底写了：%r" % (logtext,)
    )

    # ② EC 写被吞、读回 0 -> 必须兜底
    got2, dropped2, fsl2, _reqs2, logtext2 = _free(50, lambda: 0, True)
    assert dropped2, "0x79 曲线写在注入里没被丢弃 —— 本用例的故障没有真的发生"
    assert got2 == "free"
    assert 0 not in fsl2, "兜底路径也不许出现 _FSL 0: %r" % (fsl2,)
    assert fsl2[-1] == pfanel.MIN_SAFE_LEVEL, (
        "EC 写被吞、读回 0 时最后一次 _FSL 写是 %r —— free 停在停转上"
        % (fsl2[-1] if fsl2 else None,)
    )
    assert "直接写 _FSL 1 %d" % pfanel.MIN_SAFE_LEVEL in logtext2, (
        "兜底写必须留日志（事后分得清是没检查还是兜底了）：%r" % (logtext2,)
    )


# ---------------- R-03：s0i3 的 curve.state 必须在 restart 之前落盘 ----------------
# pfand 启动时读 curve.state，不是 s0i3 就 log + exit 0（设计）。旧顺序
# （先 restart 后 save_state）让守护读到旧曲线退出，新门禁于是把它当成"没起来"
# 回滚到 cool，而回滚把 cool 持久化 —— s0i3 永久不可达，每次尝试还伴随 5-9s 的
# 命令性停转。修复是重启前先 save_state；失败路径由回滚自己改回 cool。


def test_s0i3_persists_the_curve_before_restarting_the_daemon():
    """restart 发生的那一刻，curve.state 必须已经是 s0i3。

    判据取【restart 瞬间的状态】，不是事后的状态：事后 s0i3 也能由失败回滚的
    反向覆盖蒙对"最后是 cool"，而这里要钉的正是顺序。
    第二个方向：真死守护仍必须回滚到 cool 并持久化 cool（回归保护）。
    """
    dev = os.environ["PFAN_DEV"]
    curve_file = os.environ["PFAN_CURVE_FILE"]
    log = os.path.join(os.path.dirname(dev), "pfanel.log")
    import subprocess as _sp

    _real_run, _real_open = _sp.run, builtins.open
    _real_ready = getattr(pfanel, "_daemon_ready", None)
    _real_time = pfanel.time

    class _NoSleep:
        def sleep(self, _s):
            return None

        def __getattr__(self, name):
            return getattr(_real_time, name)

    def _run(ready):
        with open(curve_file, "w", encoding="utf-8") as fh:
            json.dump({"curve": "cool", "level": 40}, fh)
        open(log, "w").close()
        seen = []

        def _fake_run(cmd, *a, **k):
            if isinstance(cmd, (list, tuple)) and any(
                "systemctl" in str(c) for c in cmd
            ):
                if "restart" in cmd:
                    # 真 pfand 在启动时读这个文件；记录它当时会读到什么
                    seen.append(pfanel.get_state()["curve"])
                return _Proc("active\n" if ready else "inactive\n", 0 if ready else 3)
            return _real_run(cmd, *a, **k)

        _sp.run = _fake_run
        pfanel._daemon_ready = lambda *a, **k: ready
        pfanel.time = _NoSleep()
        pfanel.open = lambda p, *a, **k: (
            _real_open(log, "a")
            if str(p) == "/var/log/pfanel.log"
            else _real_open(p, *a, **k)
        )
        try:
            got = pfanel.set_curve("s0i3")
        finally:
            _sp.run = _real_run
            pfanel.open = _real_open
            pfanel.time = _real_time
            if _real_ready is None:
                pfanel.__dict__.pop("_daemon_ready", None)
            else:
                pfanel._daemon_ready = _real_ready
        return got, seen

    got, seen = _run(True)
    assert seen, "本用例没有观察到 restart —— 注入没有生效"
    assert got == "s0i3", "预持久化后健康切换仍被回滚：%r" % (got,)
    assert seen[0] == "s0i3", (
        "restart 发生时 curve.state 是 %r，不是 s0i3 —— pfand 会读到旧曲线直接"
        "exit 0，门禁回滚 cool 并持久化，s0i3 从此不可达" % (seen[0],)
    )
    assert pfanel.get_state()["curve"] == "s0i3"

    got2, seen2 = _run(False)
    assert seen2 and seen2[0] == "s0i3", (
        "失败路径也必须先落盘（否则重试永远从旧状态出发）：%r" % (seen2,)
    )
    assert got2 == "cool", "真死守护必须仍回滚到 cool：%r" % (got2,)
    assert pfanel.get_state()["curve"] == "cool", (
        "回滚必须把 cool 持久化，不能把预写入的 s0i3 留下：%r"
        % (pfanel.get_state()["curve"],)
    )


# ---------------- R-04 + R-13：guard() 的行为与两个常量 ----------------
# 变异实测（本分支 43609b9 上）：删掉 guard() 里的 set_curve("auto")、把
# GUARD_TEMP 82->100、HANDOVER_SETTLE_S 1.6->0.001 —— pytest 70/70 全绿。
# guard 的动作是 free/quiet/s0i3 停转的唯一自动恢复，没有任何行为测试。
# 判据必须钉【动作】（stub 记录 set_curve 被调），日志不算：只删调用、留下
# "已自动回退"日志的版本照样全绿，而那条日志是一条没人能核对的谎。


def test_guard_rolls_back_at_the_threshold_and_only_for_guarded_curves():
    """受管曲线 >= GUARD_TEMP 才回退；阈值用字面温度双向夹住；两个常量对独立下界。

    ① 行为：GUARDED 每一条在 90.0C 恰好调一次 set_curve("auto")；81.9C（低于阈值）
       不调；恰好 GUARD_TEMP 调（>= 语义）；auto/cool 在 95.0C 不调；温度 None 不调。
    ② 阈值本身：90.0 与 81.9 是【字面温度】—— GUARD_TEMP 改成 100 或 70 都会让
       其中一条转红，不依赖常量自己比自己。
    ③ GUARD_TEMP 与 HANDOVER_SETTLE_S 对独立字面边界断言（旧的两条
       `max(waits) >= pfanel.HANDOVER_SETTLE_S` 是恒真的同义反复）。
    """
    dev = os.environ["PFAN_DEV"]
    log = os.path.join(os.path.dirname(dev), "pfanel.log")
    _real_open = builtins.open

    _had_open = hasattr(pfanel, "open")

    def _probe(curve, temp):
        calls = []
        temps = []
        # 用 getattr：本文件其它用例把 pfanel.open 留在模块上，但单独跑本用例时
        # 它并不存在 —— 直接取 pfanel.open 会在 -k 单跑时 AttributeError（本文件
        # 自己就踩过一次），那是测试互染，不是被测行为。
        real = (pfanel.get_curve, pfanel.get_temp, pfanel.set_curve, pfanel.log_event,
                getattr(pfanel, "open", builtins.open))
        pfanel.get_curve = lambda: curve
        pfanel.get_temp = lambda: (temps.append(temp), temp)[1]
        pfanel.set_curve = lambda name: calls.append(name)
        pfanel.log_event = lambda *a, **k: None
        pfanel.open = lambda p, *a, **k: (
            _real_open(log, "a")
            if str(p) == "/var/log/pfanel.log"
            else _real_open(p, *a, **k)
        )
        try:
            got = pfanel.guard()
        finally:
            (pfanel.get_curve, pfanel.get_temp, pfanel.set_curve, pfanel.log_event,
             _ret) = real
            if _had_open:
                pfanel.open = _ret
            else:
                pfanel.__dict__.pop("open", None)
        return got, calls, temps

    open(log, "w").close()

    for curve in pfanel.GUARDED:
        got, calls, _t = _probe(curve, 90.0)
        assert calls == ["auto"], (
            "受管曲线 %s 在 90.0C 没有回退（动作被删/阈值被改）：calls=%r" % (curve, calls)
        )
        assert got == 90.0, "guard 触发时应返回触发温度：%r" % (got,)

    _got, calls, _t = _probe("quiet", 81.9)
    assert calls == [], "81.9C（低于 GUARD_TEMP）触发了回退：calls=%r" % (calls,)

    _got, calls, _t = _probe("quiet", float(pfanel.GUARD_TEMP))
    assert calls == ["auto"], "恰好 GUARD_TEMP 时必须触发（>= 语义）：calls=%r" % (calls,)

    for curve in ("auto", "cool"):
        _got, calls, _t = _probe(curve, 95.0)
        assert calls == [], "不受管曲线 %s 被 guard 回退了：calls=%r" % (curve, calls)

    _got, calls, temps = _probe("quiet", None)
    assert calls == [], "温度读不到（None）时不该回退：calls=%r" % (calls,)
    assert temps, "guard 在受管曲线上必须先读温度（None 分支被跳过？）"

    # 常量：独立字面边界 + 出处。TjMax=100（见 GUARD_TEMP 注释）；
    # 阈值必须在它之下留出余量，70..95 是收窄后的合法带。
    assert 70 <= pfanel.GUARD_TEMP <= 95, (
        "GUARD_TEMP=%r 越出 [70,95] —— 到 100 等于永不触发（TjMax 本身）；"
        "低于 70 会在正常办公温度就回退" % (pfanel.GUARD_TEMP,)
    )
    # 交回后读 EC 的等稳时间：固件接管不是瞬时的（1.0s 下界）；
    # 5.0s 上界是延迟预算 —— 0.001 这类值实测蒙过整个套件。
    assert 1.0 <= pfanel.HANDOVER_SETTLE_S <= 5.0, (
        "HANDOVER_SETTLE_S=%r 越出 [1.0,5.0] —— 等得不够久等于没等" % (
            pfanel.HANDOVER_SETTLE_S,
        )
    )
