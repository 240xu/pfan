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
