"""平台配置加载。

与 core/platform.sh 读同一份文件，两侧语义必须一致：
纯 KEY=VALUE，`#` 起注释，值不得含等号与前导空格。
"""
import os

DEFAULT_PATH = "/etc/pfan/platform.conf"
REPO_EXAMPLE = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "platform", "platform.conf.example"
)
REQUIRED = ("EC_ROOT", "FAN_DEVICE", "THERMAL_ZONE", "DEV", "EC_CMD")


def _path(path=None):
    return path or os.environ.get("PFAN_PLATFORM_CONF") or DEFAULT_PATH


def load(path=None):
    """读平台配置 -> dict。文件不存在抛 FileNotFoundError（不静默回退）。"""
    p = _path(path)
    out = {}
    with open(p, encoding="utf-8") as fh:
        for raw in fh:
            line = raw.split("#", 1)[0].strip()
            if not line or "=" not in line:
                continue
            k, v = line.split("=", 1)
            out[k.strip()] = v.strip()
    return out


def get(key, path=None, default=None):
    """取单键；缺文件或缺键返回 default（None 表示抛错）。"""
    try:
        d = load(path)
    except OSError:
        if default is not None:
            return default
        raise
    if key in d:
        return d[key]
    if default is not None:
        return default
    raise KeyError(key)
