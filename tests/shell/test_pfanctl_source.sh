#!/usr/bin/env bash
# pfanctl.c 源码级回归（本地没有内核头，编不了 → 只做源码断言；
# 真正的 `make` 在目标机上执行，见 Task 8）。
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
fails=0; ok(){ echo "  [ok]   $1"; }; ng(){ echo "  [FAIL] $1"; fails=$((fails+1)); }
C=core/pfanctl/pfanctl.c
[ -f "$C" ] || { ng "缺 $C"; echo "fails=$fails"; exit 1; }

echo "== T1: 删掉拿 res.length 与【类型/分配常量】比较的死分支（⑱）=="
if grep -qE 'res\.length *== *ACPI_TYPE_INTEGER' "$C"; then
  ng "仍在比较 res.length == ACPI_TYPE_INTEGER（res.length 是字节长度，不是对象类型）"
else ok "TYPE_INTEGER 死分支已删"
fi
if grep -qE 'res\.length *== *ACPI_ALLOCATE_BUFFER' "$C"; then
  ng "仍在比较 res.length == ACPI_ALLOCATE_BUFFER（求值成功后该值是实际长度，不可能相等）"
else ok "ALLOCATE_BUFFER 死分支已删"
fi

echo "== T2: 参数解析必须能拒绝前导零（⑱ + I1 的根因）=="
# simple_strtol 的 base 0 会把 "080" 当八进制读成 0（'8' 非法八进制数字 → 就地截断），
# _FSL 收到 0 => 风扇停转，而用户写的是 80。
if grep -q 'pfan_parse' "$C"; then
  ok "存在 pfan_parse 助手"
else ng "没有 pfan_parse —— 参数仍在用裸 simple_strtol(..., 0)"
fi
# base-0 解析【唯一】允许的形式是 pfan_parse 内部那句 simple_strtol(s, endp, 0)。
# 用行号定位 pfan_parse 函数体，把体内的行排除掉（否则会把自己合法的 hex 分支算成违规）。
ps=$(grep -nE '^static (long|int) pfan_parse' "$C" | cut -d: -f1)
pe=$(awk -v s="$ps" 'NR>s && /^}/{print NR; exit}' "$C")
bare=$(grep -nE 'simple_strtol\([^)]*, *0\)' "$C" | awk -F: -v s="$ps" -v e="$pe" '(s=="" || $1<s || $1>e)')
if [ -n "$bare" ]; then
  ng "pfan_parse 函数体之外仍有裸的 simple_strtol(..., 0):"
  echo "$bare" | sed 's/^/      /'
elif [ -z "$ps" ]; then
  ng "找不到 pfan_parse 函数"
else ok "base-0 解析只存在于 pfan_parse 体内（第 ${ps}-${pe} 行）"
fi
# 显式 base 的裸调用同样违规（0b、8、16 …）—— 解析策略必须只住在 pfan_parse 里，
# 否则"坏 token 怎么办"会在第二个解析点分叉（2026-10-07 复审 F5 收紧）。
if [ -n "$ps" ]; then
  stray=$(grep -n 'simple_strtol' "$C" | grep -vE ':[[:space:]]*(//|\*|/\*)' \
          | awk -F: -v s="$ps" -v e="$pe" '($1<s || $1>e)')
  if [ -z "$stray" ]; then ok "pfan_parse 体外无任何 simple_strtol（含显式 base）"
  else ng "pfan_parse 体外出现 simple_strtol（解析策略分叉点）:"; echo "$stray" | sed 's/^/      /'; fi
fi
# 必须保留 0x 解析能力（EC88 的 0x79 依赖它）
if grep -qE "0x79" core/pfand core/pfanel.py 2>/dev/null; then
  if grep -qE "'x'|== *'x'|0xX" "$C"; then ok "保留 0x 前缀的 base-0 解析"
  else ng "改成了纯十进制 —— 会解析不了 0x79 这类 EC 寄存器参数"; fi
fi

echo "== T2b: pfan_parse 必须拒绝坏 token（-EINVAL，不进 ACPI）=="
# 旧实现不检查 endp：任何非数字 token 静默解析成 0 → _FSL 0 = 风扇停转。
# docs/OPERATIONS.md 鼓励恢复期手动 echo，正是这条触发路径（复审 F5）。
if [ -n "$ps" ]; then
  body=$(sed -n "${ps},${pe}p" "$C")
  if echo "$body" | grep -q 'return -EINVAL'; then
    ok "pfan_parse 体内坏 token 返回 -EINVAL"
  else
    ng "pfan_parse 不拒绝坏 token —— 非数字/半截 token 静默变 0（_FSL 0 = 停转）"
  fi
fi
# 调用方必须检查返回值：-EINVAL 若被当参数值发出，等于把错误码送进 ACPI
if grep -qE 'err ?= ?pfan_parse\(|if ?\(pfan_parse\(' "$C"; then
  ok "调用方检查 pfan_parse 返回值（-EINVAL 不会被当参数发出）"
else
  ng "调用方不检查 pfan_parse 返回值 —— -EINVAL(-22) 会被当参数值发进 ACPI"
fi
# 注释不得再承诺 base 0 处理 0b/0B：内核 simple_strtoull 只认 0x/0X，承诺不兑现=注释撒谎
if grep -qF '0x/0X/0b/0B' "$C"; then
  ng "注释仍声称 0x/0X/0b/0B 都走 base 0 —— 内核不识别 0b 前缀（实测 0b… 会截断成 0）"
else ok "注释不再承诺 0b/0B 走 base 0"
fi

echo "== T3: 每次调用的 argc/st/len 必须降噪（⑭）=="
# 这条是 dmesg 里 97% 的来源；RESULT 行才是消费者依赖的，必须保留。
if grep -q 'pr_debug("pfanctl: %s argc=%d' "$C"; then ok "argc/st/len 已降为 pr_debug"
else ng "argc/st/len 仍是 pr_info（每次 ACPI 调用刷一行）"; fi

echo "== T4: 唯一真正生效的 RESULT 打印必须保留 =="
# 注意：旧版 grep -c 会给 3，但其中 2 处在【死分支】里、从未执行过。
# 真正被 pfan/pfand/pfanel 消费的只有 dump_obj 那一条 `RESULT %s`。
if grep -q 'pr_info("pfanctl: RESULT %s\\n", out)' "$C"; then
  ok "dump_obj 路径的 RESULT 打印存在（消费者实际依赖的那一条）"
else ng "dump_obj 路径的 RESULT 打印缺失 —— 三个消费者都读不到结果"
fi
# 格式必须仍是 `RESULT ` + dump_obj 的输出（pfand 用 grep -oE 'RESULT \\[[0-9]+,[0-9]+' 抠值）
if grep -q 'dump_obj((union acpi_object \*)res.pointer, out, 8192, 0)' "$C"; then
  ok "dump_obj 调用签名未变"
else ng "dump_obj 调用变了 —— 输出格式可能不再匹配 pfand 的正则"
fi

echo "== T5: get_handle 失败必须继续报错（fail-closed 依赖它）=="
grep -q 'pr_err("pfanctl: get_handle' "$C" && ok "get_handle 失败仍 pr_err" || ng "get_handle 失败不再报错"

echo "test_pfanctl_source: fails=$fails"; exit "$fails"
