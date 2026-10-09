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
  // ⚠ cached 只表示"数据来自采集器缓存"——server/pfanel.py 的 API 查询路径
  // （snapshot(live=False)）为了 <1ms 永远返回 cached=true，所以它【不是】过期信号。
  // 真正的判据是 age（采集器快照的年龄）。2026-10-09 实机浏览器验证：API 报
  // cached=true / age=10，面板却显示"缓存快照（服务端未实时刷新）"——就是这个误判。
  if (typeof d.age === "number") return d.age > maxAge;
  // 没有 age 可依据时，退回用 cached：宁可保守说陈旧，也不要谎称实时
  return d.cached === true;
}

/** ⑰ 状态条文案：实时 / 数据滞后 / 缓存 / 中断。err 非空时优先显示错误原因。 */
export function statusText(d, maxAge = DEFAULT_STALE_AGE, err = null) {
  if (err) return "⚠ " + err;
  if (!d) return "⚠ 无数据（连接中断？）";
  // age 是判据，cached 不是：API 查询路径永远 cached=true（见 isStale 注释）。
  if (typeof d.age === "number") {
    return d.age > maxAge
      ? "数据滞后 " + Math.round(d.age) + "s（采样中断？）"
      : "实时";
  }
  // 没有 age 可依据时才退回 cached，宁可保守也不谎称实时
  return d.cached ? "缓存快照（无 age，无法判断新鲜度）" : "实时";
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

/* ==========================================================================
 * V1/V2 —— uPlot 数据整形（純函数，DOM-free）
 * uPlot 吃【列式】数组：data[0]=x，data[1..]=各 series 的 y，
 * 且 xScale:{time:true} 时期望 unix【秒】（不是 Chart.js 的毫秒）。
 * ========================================================================== */

/** 每条轮询拉回的全量历史的采样点上限。
 *  API 每 8s 可取数千点；不降采样的话浏览器每帧绘制指令数 = 点数，页面会卡。
 *  800 ≈ 12h @60s 的规模，足够看清趋势又不糊。 */
export const HISTORY_CAP = 800;

/** 均匀降采样：把 arr 收敛到至多 cap 个元素，【必须保住首末两点】
 *  （末点=最新读数，掉了就是"曲线停在十分钟前"）。≤cap 时原样返回。 */
export function decimate(arr, cap = HISTORY_CAP) {
  if (!Array.isArray(arr) || !arr.length) return [];
  const n = arr.length;
  const c = Number(cap);
  if (!Number.isFinite(c) || c <= 0 || n <= c) return arr.slice();
  const out = [];
  for (let i = 0; i < c; i++) {
    // Math.min 兜住浮点：i=c-1 时必须命中 n-1，否则末点会被舍掉
    out.push(arr[Math.min(n - 1, Math.floor((i * n) / c))]);
  }
  out[c - 1] = arr[n - 1];
  return out;
}

/** 多列同步降采样：必须按【同一组下标】取，否则 x/y 错位，整幅图散架。 */
export function decimateCols(cols, cap = HISTORY_CAP) {
  if (!Array.isArray(cols) || !cols.length) return [];
  const n = cols[0] ? cols[0].length : 0;
  const c = Number(cap);
  if (!Number.isFinite(c) || c <= 0 || n <= c) return cols.map((x) => (Array.isArray(x) ? x.slice() : []));
  const idx = [];
  for (let i = 0; i < c; i++) idx.push(Math.min(n - 1, Math.floor((i * n) / c)));
  idx[c - 1] = n - 1;
  return cols.map((y) => (Array.isArray(y) ? idx.map((i) => y[i]) : []));
}

/** history → uPlot 列：[ts 秒, temp, level, ec76]。
 *  null/缺失保留下来 —— uPlot 遇到 null 会断开线段，
 *  这正是"这段时间读不到温度"的正确画法（Chart.js 时代用 filter 丢点，会把
 *  缺失处连成一条直线，看起来像温度平稳，实际是无数据）。 */
export function historyColumns(h, cap = HISTORY_CAP) {
  const rows = (Array.isArray(h) ? h : []).filter((x) => x && typeof x.ts === "number");
  const cols = [
    rows.map((x) => x.ts),
    rows.map((x) => (x.temp == null ? null : x.temp)),
    rows.map((x) => (x.level == null ? null : x.level)),
    rows.map((x) => (x.ec76 == null ? null : x.ec76)),
  ];
  return decimateCols(cols, cap);
}

/** x 数组的排序标记：uPlot 的 scale.sorted —— 1=升序 / -1=降序 / 0=无序。
 *  实测散点的温度列【不是】升序（温度会上下走），标 1 会让 uPlot 在点上
 *  二分查找取到错误的值域，点被画到错的 x 位置。 */
export function xSortedFlag(xs) {
  if (!Array.isArray(xs) || xs.length < 2) return xs && xs.length === 1 ? 1 : 0;
  let up = true, down = true;
  for (let i = 1; i < xs.length; i++) {
    const a = xs[i - 1], b = xs[i];
    if (a == null || b == null) return 0;
    if (b < a) up = false;
    if (b > a) down = false;
    if (!up && !down) return 0;
  }
  return up ? 1 : down ? -1 : 0;
}

/** 实测散点：温度(x) → 档位(y)。
 *  无条件剔除 0 档（=释放控制，不是"风扇 0% 转"）与 >100（越界），
 *  这两类点在图上会把 y 轴拉到荒谬的量纲。 */
export function scatterPoints(h, cap = HISTORY_CAP) {
  const pts = (Array.isArray(h) ? h : [])
    .filter((x) => x && x.temp != null && x.level != null && x.level > 0 && x.level <= 100)
    .map((x) => ({ x: x.temp, y: x.level }));
  const x = decimate(pts.map((p) => p.x), cap);
  const y = decimate(pts.map((p) => p.y), cap);
  return { x, y };
}

/** 理想阶梯曲线：每段从上一段档位水平延伸到本段上界，末段延到 105°C 兜底。
 *  返回 {x,y} 且 x 严格升序 —— uPlot 的 line series 画乱序点会来回折。 */
export function idealStep(bands, tailX = 105) {
  const x = [], y = [];
  let prev = null;
  for (const b of Array.isArray(bands) ? bands : []) {
    if (!b || !(b.level > 0)) continue;
    if (prev !== null && prev !== b.level) { x.push(b.upto); y.push(prev); }
    x.push(b.upto); y.push(b.level);
    prev = b.level;
  }
  if (prev !== null) { x.push(tailX); y.push(prev); }
  const pairs = x.map((v, i) => [v, y[i]])
    .sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0));
  return { x: pairs.map((p) => p[0]), y: pairs.map((p) => p[1]) };
}

/* ==========================================================================
 * V3 —— SVG 弧形表盘几何（純数学，DOM-free）
 * 画svg是 app.js 的事；这里只算 (路径, 周长, dash 偏移)。
 * ========================================================================== */

/** 度数 → 直角坐标。SVG 的 y 轴向下，所以用 cy - r*sin（数学惯例取反）。
 *  uPlot 之外不再引任何库 —— 一个 gauge 就是两条 path + stroke-dasharray。 */
function polar(cx, cy, r, deg) {
  const rad = (deg * Math.PI) / 180;
  return [cx + r * Math.cos(rad), cy - r * Math.sin(rad)];
}

/** 底弧路径：从 start 度顺时针扫 sweep 度。
 *  largeArc/sweepFlag 必须由 sweep 是否 >180 算出来 —— 写死 1 的话
 *  半圆表盘会画成反向的大弧（sweep=180 时几何上两种画法重合，181 就翻车）。 */
export function gaugePath(g) {
  const sweep = Number(g && g.sweep);
  const start = Number(g && g.start);
  const cx = Number(g && g.cx), cy = Number(g && g.cy), r = Number(g && g.r);
  const s = Number.isFinite(sweep) ? sweep : 0;
  const a0 = Number.isFinite(start) ? start : 0;
  const [x0, y0] = polar(cx, cy, r, a0);
  const [x1, y1] = polar(cx, cy, r, a0 + s);
  const circumference = 2 * Math.PI * Math.abs(r) * (Math.abs(s) / 360);
  return {
    path: `M ${x0.toFixed(3)} ${y0.toFixed(3)} A ${r} ${r} 0 ${Math.abs(s) > 180 ? 1 : 0} 1 ${x1.toFixed(3)} ${y1.toFixed(3)}`,
    circumference,
    largeArc: Math.abs(s) > 180 ? 1 : 0,
    sweepFlag: 1,
  };
}

/** 严格取数：null/undefined/'' 一律 NaN —— Number(null) 是 0，会把"读不到温度"
 *  当成合法的 0°C 画成满绿表盘（比留空更糟）。这是 API 允许 temp:null 时必须付的税。 */
function num(v) {
  if (v === null || v === undefined || v === "") return NaN;
  return Number(v);
}

/** value → 表盘全部几何。value 无效返回 null，调用方据此画空态
 *  （API 允许 temp:null；把它当 0 会画出"0°C 且全绿"，比什么都不画更糟）。 */
export function gaugeArc(g) {
  if (!g) return null;
  const v = num(g.value);
  if (!Number.isFinite(v)) return null;
  const base = gaugePath(g);
  const min = Number(g.min), max = Number(g.max);
  const lo = Number.isFinite(min) ? min : 0;
  const hi = Number.isFinite(max) ? max : 100;
  // min===max（配置写错）不是用户的错，但不能产出 NaN —— 退化成 0 比例
  const frac = hi > lo ? Math.min(1, Math.max(0, (v - lo) / (hi - lo))) : 0;
  return Object.assign({}, base, {
    frac,
    dasharray: `${base.circumference.toFixed(3)} ${base.circumference.toFixed(3)}`,
    dashoffset: base.circumference * (1 - frac),
  });
}

/* ---- 阈值配色：沿用 styles.css 的 .ok/.warn/.bad 三个色号，不新造调色板 ---- */
export const CLASS_COLOR = { ok: "#3fb950", warn: "#d29922", bad: "#f85149", na: "#484f58" };

export function classColor(k) {
  return CLASS_COLOR[k] || CLASS_COLOR.na;
}

/** 温度阈值：与旧版进度条同一套语义（>78 bad / >65 warn），只是从 paint() 搬到
 *  core 以便单测。等值端点维持旧的「大于」语义：65 是 warn 的第一度。 */
export function tempClass(t) {
  const v = num(t);
  if (!Number.isFinite(v)) return "na";
  return v > 78 ? "bad" : v > 65 ? "warn" : "ok";
}

/** 档位阈值：噪音/功耗随档位单调上升，>85 已经很吵。 */
export function levelClass(l) {
  const v = num(l);
  if (!Number.isFinite(v)) return "na";
  return v > 85 ? "bad" : v > 70 ? "warn" : "ok";
}

/** 数值优先：颜色只是第二通道（色盲/单色屏也必须能读出具体数字）。
 *  0 是合法读数（0°C 不多见但 0% 档位是字面量），不能显示成 "--"。 */
export function valueText(v) {
  const n = num(v);
  return Number.isFinite(n) ? String(Math.round(n)) : "--";
}

/** 表盘 SVG 源码 —— DOM 之外的最后一步：拼字符串仍是可测的纯函数，
 *  真正的 DOM 写入（innerHTML）留在 app.js。 */
export function gaugeMarkup(o) {
  o = o || {};
  const cls = o.cls || "na";
  const color = classColor(cls);
  const g = gaugeArc({ cx: 50, cy: 46, r: 36, sweep: 240, start: 150,
                       value: o.value, min: o.min, max: o.max });
  if (!g) {
    return `<svg class="g-arc" viewBox="0 0 100 74" width="${o.size || 96}" role="img" ` +
      `aria-label="${esc(o.label)} 无数据">` +
      `<path d="${gaugePath({ cx: 50, cy: 46, r: 36, sweep: 240, start: 150 }).path}" ` +
      `fill="none" stroke="#21262d" stroke-width="9" stroke-linecap="round"/>` +
      `<text x="50" y="48" text-anchor="middle" font-size="15" fill="#484f58">--</text></svg>`;
  }
  return `<svg class="g-arc" viewBox="0 0 100 74" width="${o.size || 96}" role="img" ` +
    `aria-label="${esc(o.label)} ${esc(valueText(o.value))}${esc(o.unit || "")}">` +
    `<path d="${g.path}" fill="none" stroke="#21262d" stroke-width="9" stroke-linecap="round"/>` +
    `<path d="${g.path}" fill="none" stroke="${color}" stroke-width="9" stroke-linecap="round" ` +
    `stroke-dasharray="${g.dasharray}" stroke-dashoffset="${g.dashoffset.toFixed(3)}"/>` +
    `<text x="50" y="47" text-anchor="middle" font-size="15" fill="${color}">` +
    `${esc(valueText(o.value))}</text></svg>`;
}
