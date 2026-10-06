#!/usr/bin/env bash
# smoke.sh 的可测试纯函数。被 tests/shell/test_guards.sh 直接 source。
#
# svc_verdict active enabled nrestarts -> rc
#   0 = ok      健康
#   1 = warn    当前健康但有异常计数（不阻断 push —— NRestarts 是历史计数，
#               而 pfanel 是 Restart=once/always 的长驻服务；把历史计数当失败会
#               迫使运维重启生产服务才能让门变绿）
#   2 = bad     当前不健康
svc_verdict() {
  [ "$1" = active ]  || return 2
  [ "$2" = enabled ] || return 2
  [ "${3:-0}" -eq 0 ] 2>/dev/null || return 1
  return 0
}
