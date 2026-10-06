"""HTTP 层测试：②⑤ Origin 白名单可配置、②⑦ CORS 不再全开、⑯ daemon_threads。

导入 pfanel 前必须给平台配置，否则模块级加载会按设计快速失败（P1 的 I4 修复）。
"""
import os
import socket
import threading
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


def test_state_seam_defaults_equal_production():
    """接缝的【缺省值】必须等于生产值 —— 否则测试跑的是另一套语义。

    注意：本文件已经把这些环境变量指向临时目录了，所以不能断言解析后的值，
    只能断言源码里写的缺省值（与 pfand 侧 T0 的做法一致）。
    """
    import inspect
    src = inspect.getsource(pfanel)
    for default in ('os.environ.get("PFAN_DB", "/var/lib/pfanel/pfanel.db")',
                    'os.environ.get("PFAN_CURVE_FILE", "/var/lib/pfanel/curve.state")',
                    'os.environ.get("PFAN_TOKEN_FILE", "/var/lib/pfanel/token")',
                    'os.environ.get("PFAN_CONF", "/etc/pfand.conf")',
                    'os.environ.get("PFAN_LOCK", "/run/pfanel.lock")'):
        assert default in src, f"缺省值不是生产值: {default}"
    # PFAN_DEV 是三层回退（环境变量 -> 平台配置 -> 字面兜底），
    # 兜底值来自平台配置，所以断言平台配置里写的 DEV 才是真正的"生产值"。
    assert 'os.environ.get("PFAN_DEV", "")' in src, "PFAN_DEV 接缝缺失"
    with open(os.path.join(_REPO, "platform", "platform.conf.example"), encoding="utf-8") as fh:
        assert any(line.strip() == "DEV=/dev/pfanctl" for line in fh), \
            "平台配置里的 DEV 不是 /dev/pfanctl（生产值变了？）"


def _free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def _serve(port):
    srv = pfanel.Server(("127.0.0.1", port), pfanel.H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv


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
    port = _free_port()
    srv = _serve(port)
    try:
        r = urllib.request.urlopen(f"http://127.0.0.1:{port}/api/now", timeout=10)
        acao = r.headers.get("Access-Control-Allow-Origin")
        assert acao != "*", f"仍是通配 CORS: {acao}"
    finally:
        srv.shutdown()
        srv.server_close()


def test_api_still_serves_json_shape():
    port = _free_port()
    srv = _serve(port)
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
    port = _free_port()
    srv = _serve(port)
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
    port = _free_port()
    srv = _serve(port)
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
    port = _free_port()
    srv = _serve(port)
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
