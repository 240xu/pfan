#!/bin/bash
# 平台配置加载器（bash 侧）。
# 与 server/pfan_platform.py 读【同一份文件】，语义必须一致：
#   纯 KEY=VALUE；`#` 起注释；值不含等号与前导空格。
# 覆盖：PFAN_PLATFORM_CONF 指向别的配置（测试用 example）。
pfan_platform_conf(){ printf '%s' "${PFAN_PLATFORM_CONF:-/etc/pfan/platform.conf}"; }

pfan_plat(){          # pfan_plat KEY [CONF_PATH] -> stdout；成功 rc=0，缺文件/缺键 rc!=0
  local k="$1" f p
  f="${2:-$(pfan_platform_conf)}"
  [ -r "$f" ] || return 1
  # sed 的左半边匹配 "^KEY="（KEY 只含 [A-Z0-9_]，不需转义）；右半边空，即取剩余全部。
  # 不用 cut：值本身含反斜杠（\_SB...），cut/awk 处理需额外转义，sed 取剩余最稳。
  p=$(sed -n "s/^$k=//p" "$f" 2>/dev/null | head -1)
  [ -n "$p" ] || return 1
  printf '%s\n' "$p"
}
