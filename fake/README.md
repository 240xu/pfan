# fake/ —— 无硬件、无 root 时跑真实 `pfand` 的假设备层

由 `tests/shell/test_pfand_loop.sh` 使用。三个部件：

| 文件 | 作用 |
|---|---|
| `platform.conf` | 平台配置模板；`THERMAL_ZONE` 是 `@TEMP@` 占位，测试 sed 成假温度文件路径 |
| `bin/dmesg` | 伪内核日志：读假设备上最后一次 ACPI 请求，产出与实机同格式的 `RESULT` 行 |

**配套接缝**（缺省值都等于生产值，由测试 T0 断言）：

```
PFAN_DMESG=fake/bin/dmesg        默认 dmesg
PFAN_CONF=<临时文件>             默认 /etc/pfand.conf
PFAN_CURVE_FILE=<临时文件>       默认 /var/lib/pfanel/curve.state
PFAN_DEV=<普通文件>              默认 /dev/pfanctl（生产要求字符设备）
PFAN_LOCK/LOG/PLATFORM_CONF/PORT 同理
```

**为什么必须逐点对齐真驱动**：测试绿而真机错是最危险的失败形态。对齐核对（I1 后收紧）：
行格式、时间戳单调、以及 **fail-closed** —— 只有已知好路径上的合法请求才产生 RESULT：
`FAN_DEVICE` 上的 `_FSL 1 <n>`（记档）/ `_FST`（读档），与 `EC_ROOT` 上的 `EC88 <args>`
（pfanel 读 ec76 依赖）；坏路径 / 坏格式 / 设备文件缺失或读不出时一条 RESULT 都不产生
（对应 `pfanctl.c` 的 `get_handle` 失败分支只 `pr_err` 不打 RESULT）。
没有这条，写失败的死设备照样吐出"新鲜"RESULT，`getL` 会把陈旧档位当成实际值，
E2E 层就永远抓不到 fail-open（见 `tests/shell/test_pfand_loop.sh` 的前提 3 与 T12）。
