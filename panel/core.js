// 纯逻辑：无 DOM、无网络、无副作用 —— 可被 vitest 直接导入。
// app.js 负责把这些结果画出来；这里只做计算/格式化。

/** 空值安全的字符串化（原 app.js 的 esc） */
export function esc(s) {
  return String(s == null ? "" : s);
}

/** 空值安全的温度显示：读不到就是 "--"，否则原样返回（不擅自四舍五入） */
export function fmtTemp(t) {
  return t == null ? "--" : String(t);
}

/** 编辑器预校验：温度序列必须严格递增。
 *  返回 null 表示通过，否则返回错误消息（供 preview() 直接显示）。
 *  纯函数 —— 从 preview() 抽出，便于 vitest 覆盖（前端唯一在跑的校验逻辑）。 */
export function checkTempOrder(temps) {
  // 调用方恒传 [IDLE, T1, T2, T3, T4, T5, EMERG] 共 7 个；缺一个就没法判断递增关系
  if (!Array.isArray(temps) || temps.length < 7) {
    return `温度序列不完整（应为 IDLE,T1..T5,EMERG 共 7 个，实为 ${Array.isArray(temps) ? temps.length : "非数组"}）`;
  }
  const nums = temps.map(Number);
  if (nums.some((n) => Number.isNaN(n))) {
    return "温度必须是数字";
  }
  for (let i = 1; i < nums.length; i++) {
    if (nums[i] <= nums[i - 1]) {
      return `温度必须严格递增（当前 ${temps.join(" → ")}）`;
    }
  }
  return null;
}

/** 把档位吸附到 _FPS 表里最近的键。表外档位是常态（_FSL 允许 1..120），不是异常。
 *  ②⑥：旧实现 FPS.get(lvl) 对 42/85/95 返回 null/undefined，面板那一列就空了。 */
export function nearestFpsEntry(level, fps) {
  if (level == null || !fps) return null;
  const keys = Object.keys(fps).map(Number);
  if (!keys.length) return null;
  const near = keys.reduce((a, b) => (Math.abs(b - level) < Math.abs(a - level) ? b : a));
  return fps[near] ?? null;
}

/** 档位 -> RPM。②⑧：app.js 曾自带一份缺 85/90/95 的 nz 表，那几档显示 0。 */
export function rpmOf(level, fps) {
  const e = nearestFpsEntry(level, fps);
  return e ? e[0] : null;
}

/** 档位 -> 噪音 dB（表里是 noise_mdB，除以 1000）。不再用 lvl*0.5 硬算。 */
export function dbOf(level, fps) {
  const e = nearestFpsEntry(level, fps);
  return e ? (e[1] / 1000).toFixed(1) : null;
}
