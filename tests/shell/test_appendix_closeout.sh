#!/usr/bin/env bash
# 附录 B 收尾的守卫（这些曾长期"文档说一套、代码做一套"）
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
fails=0; ok(){ echo "  [ok]   $1"; }; ng(){ echo "  [FAIL] $1"; fails=$((fails+1)); }

echo "== T1: free 模式的看门狗文案必须与 GUARDED 一致 =="
# GUARDED = ("quiet","s0i3","free") → free 【会】被看门狗接管。
# 曾经两处文案反着说：app.js「此模式下不接管」、pfanel.py docstring「free 模式不看门狗」。
if grep -q 'GUARDED = ("quiet", "s0i3", "free")' server/pfanel.py; then
  ok "GUARDED 含 free（代码为准）"
else
  ng "GUARDED 不是预期内容 —— 先确认代码再改文案"
fi
if grep -q '此模式下<b>不接管</b>' panel/app.js; then
  ng "panel/app.js 仍写「看门狗在此模式下不接管」—— 与 GUARDED 矛盾"
else
  ok "panel/app.js 不再声称 free 模式不接管"
fi
if grep -q 'free 模式不看门狗' server/pfanel.py; then
  ng "pfanel.py guard() docstring 仍写「free 模式不看门狗」—— 与 GUARDED 矛盾"
else
  ok "pfanel.py guard() docstring 与 GUARDED 一致"
fi

echo "== T2: /api/levels 不得宣称可以设 0（set_level 明令禁止，_FSL 0 = 停转）=="
if grep -qE '"free_range":\[0,120\]' server/pfanel.py; then
  ng "/api/levels 仍返回 free_range:[0,120] —— 0 会被 set_level 拒掉，接口在撒谎"
else
  ok "/api/levels 不再把 0 列进可用区间"
fi
if grep -qE '固件支持 0~120 任意整数' server/pfanel.py; then
  ng "note 仍写「固件支持 0~120」而未提 API 禁 0 —— 读接口文案会误导调用方"
else
  ok "note 已说明 API 侧禁 0"
fi

echo "== T3: detect --write 必须原子（半截配置会让下次开机 fail-close）=="
if grep -qE 'printf .* > "\$2"' core/pfan; then
  ng 'core/pfan detect --write 仍是直接 printf > "$2"（非原子）—— 中途崩溃留下半截配置'
elif grep -qE '\$2\.tmp|mv .*"\$2"' core/pfan; then
  ok "core/pfan detect --write 走 temp + mv"
else
  ng "core/pfan detect --write 找不到原子写实现"
fi

echo "== T4: EC_CMD 必须有注释说明为什么留着这个键 =="
if grep -qE '^EC_CMD=' platform/platform.conf.example; then
  # 同一行或紧邻上一行的注释
  if grep -B1 -E '^EC_CMD=' platform/platform.conf.example | grep -qE '^\s*#'; then
    ok "EC_CMD 有注释（行为消费者仅为 REQUIRED 校验，说明用途即可）"
  else
    ng "EC_CMD= 仍是裸键无注释 —— 死键看起来像必需品"
  fi
else
  ng "platform.conf.example 缺 EC_CMD"
fi

echo "== T5: ec88 便捷语法的处置状态必须写在附录里（推迟要写清代价）==="
if grep -q 'ec88' docs/specs/2026-10-06-pfan-design.md; then
  if grep -A1 'ec88' docs/specs/2026-10-06-pfan-design.md | grep -qiE 'rmmod|窗口|推迟|合并'; then
    ok "附录已注明 ec88 处置与『需一次内核重载窗口』的代价"
  else
    ng "附录里 ec88 条目没写清处置代价 —— 读的人会以为只是没空改"
  fi
else
  ng "附录缺 ec88 条目"
fi

echo "test_appendix_closeout: fails=$fails"; exit "$fails"
