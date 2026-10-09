"""评估曲线【实际交付】的档位，而不是它声明的骨架。

存在的理由（专家审计 safety 域，实测）：core/pfand 的 floor_of/center_of 原先是按
字面档位 {25,30,40,50,60,70} 写的 case，恰好等于 config/pfand.conf.example 的梯子，
所以现役 example 完全正常 —— 两套新预设却整体落进 `*)` 分支返回 $EMERG，于是
  * trim 被永久钉在 -TRIM（center_of 返回 85/80，高于任何工作温度）
  * 降档滞回恒真（floor_of 返回 EMERG，`T <= EMERG-HYST` 恒成立）
实测交付：performance 在 68°C 只给 54%，比现役的 60% 更弱 —— 与它的名字相反。

做法：从 core/pfand 里【真的】抽出 want_for/floor_of/center_of，配上每份配置的参数
放进干净子 shell 跑，逐温度点算交付档���。所以它评估的是现役代码，不是重写一份算法。

用法：python3 tests/fixtures/eval_curve_delivery.py   （从仓库根运行）
"""
import re, subprocess, sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]   # 从任意 cwd 都能定位仓库根
src = (REPO / "core" / "pfand").read_text(encoding="utf-8")
fns = ""
for fn in ("want_for", "floor_of", "center_of"):
    m = re.search(r"\n" + fn + r"\(\)\{(.*?)\n\}", src, re.S)
    fns += f"{fn}(){{{m.group(1)}\n}}\n"

DIST = [45,48,50,50,50,52,53,54,55,56,56,57,58,58,60,62,64,66,67,68,70,73]

def deliver(conf):
    setup = ""
    for line in (REPO / conf).read_text(encoding="utf-8").splitlines():
        m = re.match(r"^([A-Z0-9_]+)=(-?\d+)$", line.strip())
        if m:
            setup += f"{m.group(1)}={m.group(2)}\n"
    script = setup + fns + """
for Tc in %s; do
  T=$Tc   # readT 已经 /1000，单位是摄氏度
  base=$(want_for "$T")
  c=$(center_of "$base")
  w=$(( (T - c) * GAIN ))
  [ "$w" -gt "$TRIM" ] && w=$TRIM
  [ "$w" -lt $(( -TRIM )) ] && w=$(( -TRIM ))
  want=$(( base + w ))
  [ "$want" -lt 25 ] && want=25
  [ "$want" -gt "$CAP" ] && want=$CAP
  printf "%%s " "$want"
done
echo
""" % (" ".join(map(str, DIST)))
    r = subprocess.run(["bash", "-c", script], capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    return [int(x) for x in r.stdout.split()]

def deliver_at(conf, tcs):
    setup = ""
    for line in (REPO / conf).read_text(encoding="utf-8").splitlines():
        m = re.match(r"^([A-Z0-9_]+)=(-?\d+)$", line.strip())
        if m:
            setup += f"{m.group(1)}={m.group(2)}\n"
    script = setup + fns + """
for Tc in %s; do
  T=$Tc   # readT 已经 /1000，单位是摄氏度
  base=$(want_for "$T")
  c=$(center_of "$base")
  w=$(( (T - c) * GAIN ))
  [ "$w" -gt "$TRIM" ] && w=$TRIM
  [ "$w" -lt $(( -TRIM )) ] && w=$(( -TRIM ))
  want=$(( base + w ))
  [ "$want" -lt 25 ] && want=25
  [ "$want" -gt "$CAP" ] && want=$CAP
  printf "%%s " "$want"
done
echo
""" % (" ".join(map(str, tcs)))
    r = subprocess.run(["bash", "-c", script], capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    return [int(x) for x in r.stdout.split()]

print("  温度(°C):", " ".join(map(str, DIST)))
res = {}
for name, conf in (("example", "config/pfand.conf.example"),
                   ("cool-quiet", "config/pfand.conf.cool-quiet"),
                   ("performance", "config/pfand.conf.performance")):
    res[name] = deliver(conf)
    print(f"  {name:12}:", " ".join(f"{v:3d}" for v in res[name]))
print()
for t in (56, 63, 68, 75):
    a = deliver_at("config/pfand.conf.example", [t])[0]
    c = deliver_at("config/pfand.conf.cool-quiet", [t])[0]
    p = deliver_at("config/pfand.conf.performance", [t])[0]
    print(f"  {t}C: example={a:3d}  cool-quiet={c:3d}  performance={p:3d}")
print()
for name in res:
    print(f"  {name:12} 加权均值 = {sum(res[name])/len(res[name]):.1f}%")
