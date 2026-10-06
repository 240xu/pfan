"""纯函数测试：曲线参数校验 + RPM 估算（从 pfanel.py 抽出后必须仍可独立导入）。"""
import pytest

from pfan_core import est_rpm, validate_params

# 与 /etc/pfand.conf 实测一致的一组合法参数
GOOD = dict(IDLE=50, L0=25, T1=56, L1=30, T2=62, L2=40, T3=67, L3=50,
            T4=72, L4=60, T5=79, L5=70, EMERG=80, E=100, EMERG_REL=75,
            CAP=70, TRIM=6, GAIN=1, HYST=3, DWELL=30, DEAD=2, IV=10)


def test_valid_params_pass():
    assert validate_params(dict(GOOD)) == []


def test_missing_key_reported():
    d = dict(GOOD)
    del d["EMERG"]
    errs = validate_params(d)
    assert errs and "EMERG" in errs[0]


def test_emerg_rel_must_be_below_emerg():
    errs = validate_params(dict(GOOD, EMERG_REL=85))
    assert errs and any("EMERG_REL" in e for e in errs)


def test_temps_must_strictly_increase():
    errs = validate_params(dict(GOOD, T2=50))   # 50 <= T1=56
    assert errs and any("递增" in e for e in errs)


def test_l0_zero_is_rejected():
    """backlog ⑩：L0=0 与面板 set_level 的钳制不一致 —— 校验层必须挡住。"""
    errs = validate_params(dict(GOOD, L0=0))
    assert errs, "L0=0 居然通过了校验"


def test_l0_below_lowest_table_step_rejected():
    """⑩ 要求 L0 >= 25（_FPS 表最低档）。"""
    errs = validate_params(dict(GOOD, L0=10))
    assert errs, "L0=10 低于 _FPS 最低档 25，居然通过"


def test_emergency_level_must_not_be_below_cap():
    errs = validate_params(dict(GOOD, E=50))
    assert errs and any("E(" in e for e in errs)


def test_out_of_range_trim_gain_rejected():
    assert validate_params(dict(GOOD, TRIM=99))
    assert validate_params(dict(GOOD, GAIN=99))


def test_est_rpm_returns_none_for_missing_or_zero():
    assert est_rpm(None) is None
    assert est_rpm(0) is None


def test_est_rpm_within_table_for_normal_level():
    assert est_rpm(50) == pytest.approx(6300, rel=0.01)


def test_est_rpm_capped_at_table_max():
    """backlog ⑪：EC 字节越界时不得算出超过表最大值的 RPM。"""
    v = est_rpm(0xFF)
    assert v is None or v <= 12000, f"est_rpm(255)={v} 超过 12000"
