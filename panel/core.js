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

/** ⑰ JSON 取数：把网络层 / HTTP 层 / 解析层三类失败翻译成【带原因】的错误。
 *  旧实现是 `const r = await fetch(u,o); return r.json();` —— 三个坑各踩一个，
 *  轮询回调里就会抛未捕获异常：面板静默停更，而且没有任何提示。 */
export async function fetchJson(url, opts, fetchImpl) {
  const f = fetchImpl || fetch;
  let r;
  try {
    r = await f(url, opts);
  } catch (e) {
    throw new Error("网络错误: " + ((e && e.message) || e));
  }
  if (!r || !r.ok) throw new Error("HTTP " + (r ? r.status : "?"));
  try {
    return await r.json();
  } catch (e) {
    throw new Error("响应不是合法 JSON: " + ((e && e.message) || e));
  }
}

/** 滞后判定的默认阈值（秒）：IV 缺失/非法时的回退 = 20，即默认 IV=10 的两倍。 */
export const DEFAULT_STALE_AGE = 20;
/** 阈值下限：validate_params 允许 IV=2，2*IV=4 秒会一采样就报"滞后"，太敏感。 */
const MIN_STALE_AGE = 10;

/** 按服务端下发的采样周期 IV 推导滞后阈值：2*IV（与旧行为 IV=10 -> 20s 一致）。
 *  IV 存在 /etc/pfand.conf、运维可改；硬编码 20 会在 IV=30 时永久报"数据滞后"。 */
export function staleAgeLimit(iv) {
  const n = Number(iv);
  if (!Number.isFinite(n) || n <= 0) return DEFAULT_STALE_AGE;
  return Math.max(MIN_STALE_AGE, 2 * n);
}

/** ⑰ 快照是否已过期：服务端标了 cached，或 age 超过阈值（调用方用 staleAgeLimit(IV) 算）。 */
export function isStale(d, maxAge = DEFAULT_STALE_AGE) {
  if (!d) return true;
  if (d.cached) return true;
  if (typeof d.age === "number" && d.age > maxAge) return true;
  return false;
}

/** ⑰ 状态条文案：实时 / 数据滞后 / 缓存 / 中断。err 非空时优先显示错误原因。 */
export function statusText(d, maxAge = DEFAULT_STALE_AGE, err = null) {
  if (err) return "⚠ " + err;
  if (!d) return "⚠ 无数据（连接中断？）";
  if (d.cached) return "缓存快照（服务端未实时刷新）";
  if (typeof d.age === "number" && d.age > maxAge) {
    return "数据滞后 " + Math.round(d.age) + "s（采样中断？）";
  }
  return "实时";
}

/** M5 前端曲线渲染的纯部分（原 renderCurve 内联）：档位表行 HTML。
 *  cur 为当前档位（null=还没读到，不高亮）；±6 视为"正在这一档附近"。 */
export function curveRowsHtml(bands, cur) {
  return (bands || []).map(b => {
    const hi = cur != null && Math.abs(cur - b.level) <= 6;
    return `<tr${hi ? ' class="hi"' : ''}><td>${b.emerg ? '≥' : '≤'}${b.upto}°C</td>` +
      `<td><b>${b.level}%</b></td>\n        <td class="mono">${b.rpm}</td>` +
      `<td class="mono">${b.db}</td><td>${hi ? '◀ 现在' : ''}</td></tr>`;
  }).join('');
}

/** M5 参数摘要行：缺字段一律 '-'，不许把 undefined 画到面板上。 */
export function curveParamsHtml(p) {
  p = p || {};
  return `微调 ±<b>${p.TRIM ?? '-'}</b>（${p.GAIN ?? '-'}/°C，只快升慢降）· 上限 <b>${p.CAP ?? '-'}%</b> · ` +
    `应急 <b>${p.EMERG ?? '-'}°C</b>→100%，回落 ${p.EMERG_REL ?? '-'}°C 才解除 · ` +
    `死区 ${p.HYST ?? '-'}°C · 驻留 ${p.DWELL ?? '-'}s · 输出死区 ${p.DEAD ?? '-'} · 采样 ${p.IV ?? '-'}s`;
}
