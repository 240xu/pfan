import os

from pfan_platform import load, get

# 相对【测试文件自身】，不依赖 CWD —— pytest 可从仓库根或 tests/python 调起。
EXAMPLE = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "..", "platform", "platform.conf.example"
)


def test_example_parses_all_required_keys():
    d = load(EXAMPLE)
    for k in ("EC_ROOT", "FAN_DEVICE", "THERMAL_ZONE", "DEV", "EC_CMD"):
        assert k in d, f"missing {k}"


def test_fan_device_is_independent_of_ec_root():
    """EC_ROOT 与 FAN_DEVICE 必须是两个独立键，不可推导（存在 IETM.TFN1 机型变体）。"""
    d = load(EXAMPLE)
    assert d["FAN_DEVICE"] != d["EC_ROOT"]
    assert d["FAN_DEVICE"].endswith(".TFN1")


def test_missing_file_raises():
    try:
        load("/nonexistent/platform.conf")
    except FileNotFoundError:
        return
    raise AssertionError("应当抛 FileNotFoundError")


def test_missing_key_returns_default():
    assert get("NOPE", EXAMPLE, default="fallback") == "fallback"
