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
