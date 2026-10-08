import { describe, expect, test } from "vitest";

import { checkTempOrder, dbOf, esc, fetchJson, fmtTemp, isStale,
         rpmOf, statusText } from "../../panel/core.js";

// 与 /etc/pfand.conf 实测一致
const CFG = {
  IDLE: 50, L0: 25,
  T1: 56, L1: 30,
  T2: 62, L2: 40,
  T3: 67, L3: 50,
  T4: 72, L4: 60,
  T5: 79, L5: 70,
  EMERG: 80, E: 100,
};

describe("esc / fmtTemp", () => {
  test("esc: null → 空串", () => expect(esc(null)).toBe(""));
  test("esc: undefined → 空串", () => expect(esc(undefined)).toBe(""));
  test("esc: 数字原样字符串化", () => expect(esc(42)).toBe("42"));
  test("fmtTemp: null → --", () => expect(fmtTemp(null)).toBe("--"));
  test("fmtTemp: 48 → 48（不擅自四舍五入）", () => expect(fmtTemp(48)).toBe("48"));
  test("fmtTemp: 0 是合法读数，不能当缺失", () => expect(fmtTemp(0)).toBe("0"));
});

describe("checkTempOrder（编辑器校验，preview() 调用）", () => {
  const OK = [50, 56, 62, 67, 72, 79, 80];          // IDLE T1..T5 EMERG 合法
  test("严格递增 → null", () => expect(checkTempOrder(OK)).toBeNull());
  test("相邻相等 → 报错", () => expect(checkTempOrder([50, 50, 62, 67, 72, 79, 80])).toBeTruthy());
  test("出现下降 → 报错", () => expect(checkTempOrder([50, 56, 50, 67, 72, 79, 80])).toBeTruthy());
  test("错误信息带当前序列（便于定位）", () => {
    const m = checkTempOrder([50, 56, 50, 67, 72, 79, 80]);
    expect(m).toContain("50");
  });
  test("EMERG 必须高于 T5（否则应急形同虚设）", () =>
    expect(checkTempOrder([50, 56, 62, 67, 72, 79, 79])).toBeTruthy());
  test("长度不足 → 报错，不静默通过", () => expect(checkTempOrder([50, 56])).toBeTruthy());
});

// ---------------- ②⑥ / ②⑧ 前端侧：RPM 与噪音必须来自权威表 ----------------

const FPS = {
  25: [3200, 12500, 1250], 30: [3800, 15000, 1500], 40: [5100, 20000, 2000],
  50: [6300, 25000, 2500], 60: [7400, 30000, 3000], 70: [9300, 35000, 3500],
  80: [9800, 40000, 4000], 85: [10500, 42500, 4250], 90: [11200, 45000, 4500],
  95: [11600, 47500, 4750], 100: [12000, 50000, 5000],
};

describe("nearestFpsEntry / rpmOf / dbOf（②⑧）", () => {
  test("表外档位吸附到最近键，不返回 0/null", () => {
    expect(rpmOf(42, FPS)).toBe(5100);          // 42 -> 40
    expect(rpmOf(85, FPS)).toBe(10500);         // 旧 nz 表缺 85，曾显示 0
    expect(rpmOf(95, FPS)).toBe(11600);         // 旧 nz 表缺 95，曾显示 0
  });

  test("标准档位直接命中", () => {
    expect(rpmOf(25, FPS)).toBe(3200);
    expect(rpmOf(100, FPS)).toBe(12000);
  });

  test("噪音取表里的 noise_mdB/1000，而不是 lvl*0.5 硬算", () => {
    expect(dbOf(50, FPS)).toBe("25.0");
    expect(dbOf(85, FPS)).toBe("42.5");
  });

  test("空值安全", () => {
    expect(rpmOf(null, FPS)).toBe(null);
    expect(rpmOf(undefined, null)).toBe(null);
    expect(dbOf(null, FPS)).toBe(null);
  });
});

describe("app.js 不再自带残缺 rpm 表（②⑧）", () => {
  test("源码里没有字面量 nz={…}", async () => {
    const { readFileSync } = await import("node:fs");
    const src = readFileSync(new URL("../../panel/app.js", import.meta.url), "utf8");
    expect(src).not.toMatch(/nz\s*=\s*\{/);
    expect(src).toMatch(/import\s*\{[^}]*rpmOf/);
    expect(src).toMatch(/import\s*\{[^}]*dbOf/);
  });
});

// ---------------- ⑰ fetch 错误处理 + cached/age ----------------

describe("fetchJson（⑰ 错误必须被翻译成人话）", () => {
  test("网络层拒绝 → 带原因抛出，而不是静默", async () => {
    const bad = async () => { throw new TypeError("Failed to fetch"); };
    await expect(fetchJson("/api/now", {}, bad)).rejects.toThrow(/网络/);
  });

  test("HTTP 500 → 抛出带状态码的错误", async () => {
    const stub = async () => ({ ok: false, status: 500, json: async () => ({}) });
    await expect(fetchJson("/api/now", {}, stub)).rejects.toThrow(/HTTP 500/);
  });

  test("401 也必须抛（不能把鉴权失败当成功）", async () => {
    const stub = async () => ({ ok: false, status: 401, json: async () => ({}) });
    await expect(fetchJson("/api/level", { method: "POST" }, stub)).rejects.toThrow(/HTTP 401/);
  });

  test("响应不是 JSON → 抛出可读错误（旧实现 r.json() 直接抛 SyntaxError）", async () => {
    const stub = async () => ({ ok: true, status: 200, json: async () => { throw new SyntaxError("Unexpected token <"); } });
    await expect(fetchJson("/api/now", {}, stub)).rejects.toThrow(/JSON/);
  });

  test("正常响应 → 返回解析后的对象", async () => {
    const stub = async () => ({ ok: true, status: 200, json: async () => ({ temp: 50 }) });
    await expect(fetchJson("/api/now", {}, stub)).resolves.toEqual({ temp: 50 });
  });
});

describe("isStale / statusText（⑰ cached 与 age）", () => {
  test("cached=true 视为过期（拿的是缓存快照）", () => {
    expect(isStale({ temp: 50, cached: true, age: 1 })).toBe(true);
  });

  test("age 超过阈值（默认 20s，采样周期 10s 的两倍）视为过期", () => {
    expect(isStale({ temp: 50, cached: false, age: 5 })).toBe(false);
    expect(isStale({ temp: 50, cached: false, age: 32 })).toBe(true);
  });

  test("连续快照都没来 → 无对象也算过期", () => {
    expect(isStale(null)).toBe(true);
    expect(isStale(undefined)).toBe(true);
  });

  test("实时数据不算过期", () => {
    expect(isStale({ temp: 50, cached: false, age: 2 })).toBe(false);
  });

  test("statusText 要能区分「实时 / 缓存 / 中断」", () => {
    expect(statusText({ temp: 50, cached: false, age: 2 })).toMatch(/实时/);
    expect(statusText({ temp: 50, cached: false, age: 32 })).toMatch(/32|缓存/);
    expect(statusText({ temp: 50, cached: true, age: 3 })).toMatch(/缓存/);
    expect(statusText(null)).toMatch(/中断|无数据/);
  });

  test("statusText 接受自定义错误（fetch 失败时）", () => {
    expect(statusText({ temp: 50, cached: false, age: 2 }, 20, "HTTP 500")).toMatch(/HTTP 500/);
  });
});

// 本套只配了 describe/test/expect 全局（没有 beforeAll），所以每次测试自己读源码。
async function appSrc() {
  const { readFileSync } = await import("node:fs");
  return readFileSync(new URL("../../panel/app.js", import.meta.url), "utf8");
}

describe("app.js 轮询必须有错误保护（⑰）", () => {
  test("没有裸的 setInterval(async()=>paint(await j(...)))", async () => {
    const src = await appSrc();
    expect(src).not.toMatch(/setInterval\(\s*async\s*\(\s*\)\s*=>\s*paint\(\s*await\s*j\(/);
  });

  test("取数走 pollNow，且它有 try/catch", async () => {
    const src = await appSrc();
    expect(src).toMatch(/setInterval\(pollNow,\s*8000\)/);
    expect(src).toMatch(/async function pollNow\(\)\s*\{[\s\S]*?try\{[\s\S]*?\}catch\(/);
  });

  test("j() 不再直接 r.json()（必须经过 fetchJson）", async () => {
    const src = await appSrc();
    expect(src).not.toMatch(/const r\s*=\s*await\s*fetch\(u,\s*o\)\s*;\s*return\s*r\.json\(\)/);
    expect(src).toMatch(/return fetchJson\(u,\s*o\)/);
  });

  test("boot 里有状态位 conn-st 与容错", async () => {
    const src = await appSrc();
    expect(src).toMatch(/conn-st/);
    expect(src).toMatch(/async function boot\(\)\s*\{[\s\S]*?try\{[\s\S]*?\}catch\(/);
  });
});

// 只看代码行：注释里解释"这里曾用 *120"是正常写法，匹配它只是假阳性
// （与 test_panel_split 的 DOM 守卫同一类问题，那次已踩过）。
function codeOnly(src) {
  return src.replace(/\/\*[\s\S]*?\*\//g, "").replace(/^\s*\/\/.*$/gm, "");
}

describe("曲线编辑器预览必须用权威表（②⑧ 复审 I7）", () => {
  test("代码里不再出现 *120 / *0.5 的近似公式", async () => {
    const code = codeOnly(await appSrc());
    expect(code).not.toMatch(/\*\s*120\b/);
    expect(code).not.toMatch(/\*\s*0\.5\b/);
  });
  test("编辑器渲染改走 rpmOf/dbOf", async () => {
    const code = codeOnly(await appSrc());
    expect(code).toMatch(/rpmOf\(/);
    expect(code).toMatch(/dbOf\(/);
  });
});

// ================= 复审 M1..M5 =================

/** 从源码抠出某个函数的完整函数体（数大括号）。
 *  写路径守卫逐函数检查 try/catch —— 比"整文件搜 try"可靠，
 *  也能防止"只给其中一个函数加了 catch"就蒙混过关。 */
function fnBody(src, name) {
  const m = src.match(new RegExp("function\\s+" + name + "\\s*\\("));
  if (!m) return null;
  const start = src.indexOf("{", m.index);
  if (start < 0) return null;
  let depth = 0;
  for (let k = start; k < src.length; k++) {
    if (src[k] === "{") depth++;
    else if (src[k] === "}") {
      depth--;
      if (depth === 0) return src.slice(start, k + 1);
    }
  }
  return null;
}

describe("M1: isStale 必须真正参与渲染（不能是死 import）", () => {
  test("代码行里真的调用了 isStale( 快照", async () => {
    const code = codeOnly(await appSrc());
    expect(code).toMatch(/isStale\(\s*lastSnap/);
  });

  test("状态条颜色由 isStale 决定，而不是跟文案字符串比相等", async () => {
    const body = fnBody(codeOnly(await appSrc()), "setConn");
    expect(body, "找不到 setConn").toBeTruthy();
    expect(body).toMatch(/isStale\(/);
    expect(body).not.toMatch(/t\s*===\s*["']实时["']|["']实时["']\s*===\s*t/);
  });
});

describe("M2: 写路径/用户动作必须把失败反馈给用户（⑰ 遗留缺口）", () => {
  // 覆盖：档位/曲线按钮（用户点了在等结果）、编辑器读写、
  // 以及 boot 起的两个后台刷新（以前在 setInterval 里裸抛 = 未捕获 rejection）
  const WRITE_FNS = ["setLvl", "setCurve", "setHold", "setAuto",
                     "saveParams", "openEditor", "refreshHist",
                     "renderEvents", "drawScatter"];

  test("每个写路径都有 try{…}catch，并把错误交给已有的 setConn()/msg()", async () => {
    const code = codeOnly(await appSrc());
    for (const name of WRITE_FNS) {
      const body = fnBody(code, name);
      expect(body, `找不到 function ${name}（被改名或删除？）`).toBeTruthy();
      expect(body, `${name} 失败时必须走 setConn()/msg()，不能静默`).toMatch(
        /catch\s*\([^)]*\)\s*\{[^}]*(setConn|msg)\(/);
      expect(body, `${name} 必须有被保护的 await`).toMatch(/try\s*\{[\s\S]*await\s+j\(/);
    }
  });

  test("不能靠删掉 await 来“修”错误处理", async () => {
    const code = codeOnly(await appSrc());
    expect(fnBody(code, "setLvl")).toMatch(/await\s+j\(/);
    expect(fnBody(code, "saveParams")).toMatch(/await\s+j\(/);
    expect(fnBody(code, "openEditor")).toMatch(/await\s+j\(/);
  });
});

describe("M3: 滞后阈值随服务端 IV，不再硬编码 20s", () => {
  // 动态 import：新函数尚不存在（RED 阶段）时只红这一条，
  // 不像静态 import 缺 export 那样让整个测试文件收集失败。
  const core = () => import("../../panel/core.js");

  test("IV=30（运维可改 /etc/pfand.conf）→ 阈值 60s：45s 实时，61s 滞后", async () => {
    const c = await core();
    const lim = c.staleAgeLimit(30);
    expect(lim).toBe(60);
    expect(isStale({ temp: 50, cached: false, age: 45 }, lim)).toBe(false);
    expect(isStale({ temp: 50, cached: false, age: 61 }, lim)).toBe(true);
    expect(statusText({ temp: 50, cached: false, age: 45 }, lim)).toMatch(/实时/);
    expect(statusText({ temp: 50, cached: false, age: 61 }, lim)).toMatch(/滞后/);
  });

  test("IV 缺失/非法 → 回退默认 20s（与硬编码时代的判定一致）", async () => {
    const c = await core();
    for (const bad of [undefined, null, 0, -5, "abc", NaN]) {
      expect(c.staleAgeLimit(bad), String(bad)).toBe(20);
    }
    const lim = c.staleAgeLimit(undefined);
    expect(isStale({ temp: 50, cached: false, age: 5 }, lim)).toBe(false);
    expect(isStale({ temp: 50, cached: false, age: 32 }, lim)).toBe(true);
    expect(statusText({ temp: 50, cached: false, age: 32 }, lim)).toMatch(/32/);
  });

  test("IV=10 默认值 → 阈值仍是 20（向后兼容）", async () => {
    const c = await core();
    expect(c.staleAgeLimit(10)).toBe(20);
  });

  test("IV=2（validate_params 允许的下限）→ 有下限保护，不会 4s 就报滞后", async () => {
    const c = await core();
    expect(c.staleAgeLimit(2)).toBeGreaterThanOrEqual(10);
    expect(isStale({ temp: 50, cached: false, age: 9 }, c.staleAgeLimit(2))).toBe(false);
  });

  test("app.js: setConn 用 STALE_AGE，函数体里不再出现写死的 20", async () => {
    const code = codeOnly(await appSrc());
    const body = fnBody(code, "setConn");
    expect(body, "找不到 setConn").toBeTruthy();
    expect(body).toMatch(/STALE_AGE/);
    expect(body).not.toMatch(/\b20\b/);
    expect(code).toMatch(/staleAgeLimit\(/);
  });

  test("app.js: boot/saveParams/openEditor 各自都把服务端 IV 灌给阈值（逐点，非计数）", async () => {
    const code = codeOnly(await appSrc());
    // 计数式断言会被"删掉 boot 那次调用、在别处多加一次"骗过：复审实测删掉 boot 的
    // applyIV 后整套仍 54 绿 —— 而 boot 是页面加载时唯一的初始化点，删了它 STALE_AGE
    // 就永远停在 20s，M3 的原始缺陷（IV=30 却一直报"数据滞后"）原样回归。
    for (const fn of ["boot", "saveParams", "openEditor"]) {
      const body = fnBody(code, fn);
      expect(body, `找不到 ${fn}`).toBeTruthy();
      expect(body, `${fn} 没有调用 applyIV —— 服务端 IV 不会灌进阈值`).toMatch(/applyIV\(/);
    }
  });
});

describe("M4: FPS fixture 不许与权威表（server/pfan_core.py）漂移", () => {
  // 单一事实源 = server/pfan_core.py::FPS（/api/levels 运行时也从它出）。
  // vitest 没法 import python，所以让 python3 把权威表 + nearest_fps 的
  // 判定结果吐成 JSON，和 JS fixture / nearestFpsEntry 逐项对拍。
  async function pyFps() {
    const { execFileSync } = await import("node:child_process");
    const { fileURLToPath } = await import("node:url");
    const serverDir = fileURLToPath(new URL("../../server", import.meta.url));
    const py = [
      "import json,sys",
      `sys.path.insert(0,${JSON.stringify(serverDir)})`,
      "from pfan_core import FPS, nearest_fps",
      "levels=[25,26,35,42,45,50,60,65,70,80,85,90,95,100]",
      'print(json.dumps({"fps":{str(k):list(v) for k,v in FPS.items()},'
        + '"near":{str(l):list(nearest_fps(l)) for l in levels}}))',
    ].join(";");
    return JSON.parse(execFileSync("python3", ["-c", py], { encoding: "utf8" }));
  }

  test("fixture 与 pfan_core.FPS 完全一致（含键集合，谁漂移谁红）", async () => {
    expect(FPS).toEqual((await pyFps()).fps);
  });

  test("表外档位：js nearestFpsEntry 与 py nearest_fps 同值", async () => {
    const near = (await pyFps()).near;
    for (const [k, v] of Object.entries(near)) {
      const lvl = Number(k);
      expect(rpmOf(lvl, FPS), `level ${lvl}`).toBe(v[0]);
      expect(dbOf(lvl, FPS), `level ${lvl}`).toBe((v[1] / 1000).toFixed(1));
    }
  });

  test("平局取先出现的键（两边都在升序键上保留第一个最小值）", async () => {
    const near = (await pyFps()).near;
    // 45 与 40/50 等距、65 与 60/70 等距：py min() 与 js 的严格 < 比较都留低键
    expect(near["45"][0]).toBe(5100);
    expect(rpmOf(45, FPS)).toBe(5100);
    expect(rpmOf(65, FPS)).toBe(7400);
    expect(rpmOf(42, FPS)).toBe(5100);   // 表外 -> 40
    expect(rpmOf(26, FPS)).toBe(3200);   // 表外 -> 25
  });

  test("运行时单源：app.js 从 /api/levels 取表，不自带第二份", async () => {
    const code = codeOnly(await appSrc());
    expect(code).toMatch(/api\/levels/);
    expect(code).toMatch(/window\.FPS\s*=/);
  });
});

describe("M5: renderCurve 的纯逻辑抽进 core.js 可测", () => {
  const core = () => import("../../panel/core.js");

  test("行：温度界 / 档位 / RPM / 噪音列齐全，未命中不高亮", async () => {
    const c = await core();
    const html = c.curveRowsHtml([{ upto: 56, level: 30, rpm: 3800, db: "15.0" }], null);
    expect(html).toContain("≤56°C");
    expect(html).toContain("<b>30%</b>");
    expect(html).toContain("3800");
    expect(html).toContain("15.0");
    expect(html).not.toContain('class="hi"');
    expect(html).not.toContain("◀ 现在");
  });

  test("当前档位 ±6 内高亮并标「现在」，其余不高亮", async () => {
    const c = await core();
    const html = c.curveRowsHtml(
      [{ upto: 56, level: 30, rpm: 3800, db: "15.0" },
       { upto: 62, level: 40, rpm: 5100, db: "20.0" }], 33);
    expect(html.match(/class="hi"/g) || []).toHaveLength(1);
    expect(html.match(/◀ 现在/g) || []).toHaveLength(1);
    expect(html).toContain("<td><b>40%</b></td>");
  });

  test("应急段用 ≥，正常段用 ≤", async () => {
    const c = await core();
    expect(c.curveRowsHtml([{ upto: 80, level: 100, rpm: 12000, db: "50.0", emerg: true }], null))
      .toContain("≥80°C");
    expect(c.curveRowsHtml([{ upto: 56, level: 30, rpm: 3800, db: "15.0" }], null))
      .toContain("≤56°C");
  });

  test("bands 缺失/为空 → 空串，不抛异常", async () => {
    const c = await core();
    expect(c.curveRowsHtml(undefined, 50)).toBe("");
    expect(c.curveRowsHtml([], 50)).toBe("");
    expect(c.curveRowsHtml(null, null)).toBe("");
  });

  test("params 缺字段 → 占位 '-'，不显示 undefined", async () => {
    const c = await core();
    const empty = c.curveParamsHtml({});
    expect(empty).not.toContain("undefined");
    expect(empty).toContain("采样 -s");
    const full = c.curveParamsHtml({ IV: 10, HYST: 2, EMERG: 80, EMERG_REL: 75,
                                     CAP: 70, TRIM: 5, GAIN: 2, DWELL: 10, DEAD: 2 });
    expect(full).toContain("采样 10s");
    expect(full).toContain("应急 <b>80°C</b>");
  });

  test("app.js 的 renderCurve 改用这两个纯函数", async () => {
    const code = codeOnly(await appSrc());
    expect(code).toMatch(/curveRowsHtml\(/);
    expect(code).toMatch(/curveParamsHtml\(/);
  });
});

// ================= 前端修复轮（U1..U5） =================

async function htmlSrc() {
  const { readFileSync } = await import("node:fs");
  return readFileSync(new URL("../../panel/index.html", import.meta.url), "utf8");
}

describe("U1: API 字符串进 innerHTML 必须经 esc()（导出了却没接线 = 漏掉的 XSS 缝）", () => {
  // d.curve 与事件 kind/msg 是仅有的【字符串型】API 数据 → innerHTML 路径。
  // 服务端当前会白名单/构造它们，但面板是公网可达的读端点，
  // 一行 esc() 让这条缝不依赖服务端恰好没写错。
  test("d.curve（paint/renderCurve）与事件 kind/msg 的插值都包了 esc(", async () => {
    const code = codeOnly(await appSrc());
    expect(code, "paint 的 else-if 分支把 d.curve 拼进 innerHTML").toMatch(/esc\(\s*cv\s*\)/);
    expect(code, "renderCurve 的兜底分支把 cv2 拼进 innerHTML").toMatch(/esc\(\s*cv2\s*\)/);
    expect(code, "renderEvents 把 x.msg 拼进 innerHTML").toMatch(/esc\(\s*x\.msg\s*\)/);
    expect(code, "renderEvents 把事件类型名拼进 innerHTML").toMatch(
      /esc\(\s*kind\[x\.kind\]\s*\|\|\s*x\.kind\s*\)/);
  });
});

describe("U2: drawScatter 的图表配置（scales 必须在 opts 顶层）", () => {
  // 结构与结构的桥: Chart.js 时代踩过的坑是"scales 嵌进了 plugins 被整包忽略"。
  // 换成 uPlot 后同一个坑仍在 —— 把 new uPlot(...) 的第一个实参求值，按【真实嵌套】断言。
  // 求值即 eval: guarded by the fact that both arguments are source literals here.
  function chartConfig(src, anchor) {
    const i = src.indexOf(anchor);
    expect(i, `找不到 ${anchor}`).toBeGreaterThan(-1);
    const brace = src.indexOf("{", i);
    let depth = 0, end = -1;
    for (let k = brace; k < src.length; k++) {
      if (src[k] === "{") depth++;
      else if (src[k] === "}") {
        depth--;
        if (depth === 0) { end = k; break; }
      }
    }
    expect(end, "配置对象没闭合").toBeGreaterThan(-1);
    // opts 段里嵌了几个 drawScatter 作用域内的表达式（xSortedFlag(pts.x) 等）——
    // 给桩，只对【结构嵌套】求值（纯正则看不见 scales 到底嵌在第几层）。
    const xSortedFlag = () => 0;
    const LEGEND = {}, Y_AXIS = {}, TICK = "";
    const pts = { x: [50], y: [25] };
    return eval("(" + src.slice(brace, end + 1) + ")");
  }

  test("ch3: scales 在顶层且 x/y 值域生效；plugins 里没有 scales", async () => {
    const code = codeOnly(await appSrc());
    const cfg = chartConfig(code, "ch3=mount(\"");
    expect(cfg.scales, "opts.scales 缺失 —— 值域没生效").toBeTruthy();
    expect(cfg.scales.x.range).toEqual([35, 105]);
    expect(cfg.scales.y.range).toEqual([0, 105]);
    expect(cfg.plugins && cfg.plugins.scales,
      "scales 嵌进了 plugins（会被整包忽略）").toBeUndefined();
  });

  test("ch3: 实测点必须声明 sorted（温度列非单调 → 0）", async () => {
    const code = codeOnly(await appSrc());
    expect(code).toMatch(/sorted:\s*xSortedFlag\(/);
    const cfg = chartConfig(code, "ch3=mount(\"");
    expect(cfg.scales.x).toHaveProperty("sorted");
  });

  test("ch3: 实测是点云、设定曲线是虚线阶梯（视觉意图不因换库而丢）", async () => {
    const code = codeOnly(await appSrc());
    const cfg = chartConfig(code, "ch3=mount(\"");
    expect(cfg.series[1].points.show, "实测应当是散点").toBe(true);
    expect(cfg.series[2].points.show, "设定曲线不画点标记").toBe(false);
    expect(cfg.series[2].dash, "设定曲线应为虚线").toEqual([5, 4]);
  });
});

describe("U3: 模块作用域 / 未处理 Promise / 视图刷新（浏览器里真的能跑）", () => {
  test("curLevel 必须显式声明 —— 模块是严格模式，未声明赋值会让 paint 每次抛 ReferenceError", async () => {
    const code = codeOnly(await appSrc());
    expect(code).toMatch(/\blet\s+[^;]*\bcurLevel\b/);
  });

  test("index.html 内联 onclick 调用的每个函数都必须导出到 window", async () => {
    const html = await htmlSrc();
    const names = [...html.matchAll(/onclick="(\w+)\s*\(/g)].map(m => m[1]);
    expect(names.length, "index.html 应有内联 onclick").toBeGreaterThan(0);
    const code = codeOnly(await appSrc());
    for (const n of names) {
      expect(code, `缺 window.${n}=${n} —— 模块顶层函数不是全局，内联 onclick 找不到它`).toMatch(
        new RegExp(`window\\.${n}\\s*=\\s*${n}\\b`));
    }
  });

  test("boot 的初始化请求各自独立 try/catch（单个失败不拖垮曲线/散点视图）", async () => {
    const body = fnBody(codeOnly(await appSrc()), "boot");
    expect(body, "找不到 boot").toBeTruthy();
    expect((body.match(/try\s*\{/g) || []).length,
      "levels/mode/profile/curve 各一个 try —— 合并成一个 = levels 失败后曲线视图永不渲染").toBeGreaterThanOrEqual(4);
  });

  test("boot() 顶层调用挂 catch（否则尾段异常 = 未捕获 rejection）", async () => {
    const code = codeOnly(await appSrc());
    expect(code).toMatch(/boot\(\)\s*\.catch\(/);
  });

  test("buildLv: DOM 缺失时不能把 boot 砸死", async () => {
    const body = fnBody(codeOnly(await appSrc()), "buildLv");
    expect(body).toMatch(/if\s*\(\s*!box\s*\)/);
  });

  test("曲线表「◀ 现在」高亮随 8s 轮询刷新（paint 内重渲染 cvtbl）", async () => {
    const body = fnBody(codeOnly(await appSrc()), "paint");
    expect(body, "renderCurve 全量刷新间隔 180s，中间高亮不动 = 视图永不刷新").toMatch(
      /curveRowsHtml\(/);
  });

  test("表盘值域把 API 的 1..120 映射进 [min,max]，不再靠 CSS width 百分比", async () => {
    // 旧版是 `style.width = Math.min(100, level)+"%"` —— level=120 时溢出卡片。
    // 改成 SVG 弧后钳制发生在 gaugeArc 内部（frac 已 clamp 到 [0,1]），
    // 这里改为守【值域上限确实覆盖了 120】，并验证 gaugeArc 不产生越界 offset。
    const code = codeOnly(await appSrc());
    expect(code).toMatch(/paintGauge\([\s\S]*?max/);
    const c = await core();
    for (const over of [121, 500, 9999]) {
      const g = c.gaugeArc({ cx: 50, cy: 46, r: 36, sweep: 240, start: 150,
                             value: over, min: 0, max: 120 });
      expect(g.dashoffset, `level=${over} 不得溢出`).toBe(0);
      expect(g.frac).toBeLessThanOrEqual(1);
      expect(g.frac).toBeGreaterThanOrEqual(0);
    }
  });

  test("saveParams 发送前本地拦 NaN 与温度乱序（复用 checkTempOrder）", async () => {
    const body = fnBody(codeOnly(await appSrc()), "saveParams");
    expect(body, "空输入 parseInt→NaN→JSON null→服务端 500").toMatch(/Number\.isFinite/);
    expect(body, "温度递增校验 preview 有、保存路径没有 = 发一个注定 400 的请求").toMatch(
      /checkTempOrder\(/);
  });
});

describe("U4: 文案 / 单位 / 可访问性", () => {
  test("renderCurve 不再读 window.GUARD_TEMP（从未赋值 → 恒 82），直接用模块变量", async () => {
    const code = codeOnly(await appSrc());
    expect(code).not.toMatch(/window\.GUARD_TEMP/);
    expect(fnBody(code, "renderCurve")).toMatch(/\bGUARD_TEMP\b/);
  });

  test("c-rpm-note 显示 dB（fps[1] 是 mdB，直接拼出 '35000mdB' 对用户是乱码）", async () => {
    const code = codeOnly(await appSrc());
    expect(code).toMatch(/d\.fps\[1\]\s*\/\s*1000/);
    expect(code).not.toMatch(/d\.fps\[1\]\s*\+\s*"mdB"/);
  });

  test("FPS 表噪音列换算成 dB（与相邻 hint 的 '37.5 dB' 同单位），表头不再写 mdB", async () => {
    const code = codeOnly(await appSrc());
    expect(code).toMatch(/v\[1\]\s*\/\s*1000/);
    const html = await htmlSrc();
    expect(html).not.toMatch(/噪音\s*mdB/);
  });

  test("renderEditor 应急行用权威表，不留 12000/50.0 字面量", async () => {
    const code = codeOnly(await appSrc());
    expect(code).not.toMatch(/12000/);
    expect(fnBody(code, "renderEditor")).toMatch(/dbOf\(/);
  });

  test("index.html 不再硬编码 thermal_zoneN（zone 序号是机器相关的，detect 可能写 zone0）", async () => {
    const html = await htmlSrc();
    expect(html).not.toMatch(/thermal_zone\d+/);
  });

  test("styles.css 提供 :focus-visible 焦点环（原先键盘焦点完全不可见）", async () => {
    const { readFileSync } = await import("node:fs");
    const css = readFileSync(new URL("../../panel/styles.css", import.meta.url), "utf8");
    expect(css).toMatch(/:focus-visible/);
  });
});

// ================= V1: 本地化 uPlot（去 CDN + Chart.js） =================

async function panelFile(rel) {
  const { readFileSync } = await import("node:fs");
  return readFileSync(new URL("../../" + rel, import.meta.url), "utf8");
}

describe("V1: index.html 不得再从 CDN 拉图表库（LAN 设备可能无出口）", () => {
  test("没有 https:// CDN 引用 —— 无出口机器上会静默缺图", async () => {
    const html = await panelFile("panel/index.html");
    expect(html).not.toMatch(/https?:\/\/cdn\./);
    expect(html).not.toMatch(/https?:\/\/unpkg\.com/);
  });

  test("没有 chart.umd / date-fns 适配器残留（含注释）", async () => {
    const html = await panelFile("panel/index.html");
    expect(html).not.toMatch(/chart\.umd/i);
    expect(html).not.toMatch(/adapter-date-fns/i);
    expect(html).not.toMatch(/cdn\.jsdelivr\.net/i);
  });

  test("引入本地 uPlot 样式路由", async () => {
    const html = await panelFile("panel/index.html");
    expect(html).toMatch(/href="\/pfan-vendor-uplot\.css"/);
  });
});

describe("V1: 服务端必须给 vendored 资产提供本地路由", () => {
  test("pfanel.py 有两个 vendor 路由 + 正确的 Content-Type", async () => {
    const py = await panelFile("server/pfanel.py");
    expect(py).toMatch(/"\/pfan-vendor-uplot\.js"/);
    expect(py).toMatch(/"\/pfan-vendor-uplot\.css"/);
    expect(py).toMatch(/text\/css/);
    expect(py).toMatch(/application\/javascript/);
  });

  test("vendor 路由从 panel/vendor/ 读文件（去重写了 CDN 却漏了读路径）", async () => {
    const py = await panelFile("server/pfanel.py");
    expect(py).toMatch(/VENDOR_DIR|["']vendor["']/);
    expect(py).toMatch(/uPlot\.esm\.js/);
    expect(py).toMatch(/uPlot\.min\.css/);
  });
});

describe("V1: app.js 从本地路由 import uPlot，不再 new Chart(", () => {
  test("静态 route import：from \"/pfan-vendor-uplot.js\"", async () => {
    const code = codeOnly(await appSrc());
    expect(code).toMatch(/import\s+uPlot\s+from\s+["']\/pfan-vendor-uplot\.js["']/);
    expect(code).toMatch(/new\s+uPlot\(/);
  });

  test("源码任何位置都没有 new Chart( 残留", async () => {
    const src = await appSrc();
    expect(src).not.toMatch(/new\s+Chart\s*\(/);
    expect(src).not.toMatch(/chart\.umd/i);
    expect(src).not.toMatch(/adapter-date-fns/i);
  });

  test("app.js 也不许再从 CDN 拉任何东西（把风险HTML 搬到 JS 一样致命）", async () => {
    const src = await appSrc();
    expect(src).not.toMatch(/https?:\/\/cdn\./);
    expect(src).not.toMatch(/https?:\/\/unpkg\.com/);
    expect(src).not.toMatch(/https?:\/\/esm\.sh/);
  });

  test("uPlot 是默认导出（vendored ESM 只 export default uPlot）", async () => {
    const vend = await panelFile("panel/vendor/uPlot.esm.js");
    expect(vend).toMatch(/export\s*\{\s*uPlot\s+as\s+default\s*\}/);
  });
});

// ================= V2: uPlot 数据整形（不依赖 DOM） =================

const core = () => import("../../panel/core.js");

describe("V2: history → uPlot 列式数据（time 轴用 unix 秒）", () => {
  test("抽出三列并对齐到同一份 x：null 保留，uPlot 会断开连线", async () => {
    const c = await core();
    const h = [{ ts: 100, temp: 50, level: 25, ec76: 30 },
               { ts: 110, temp: 51, level: 25, ec76: null },
               { ts: 120, temp: null, level: 30, ec76: 40 }];
    const d = c.historyColumns(h);
    expect(d[0]).toEqual([100, 110, 120]);   // 秒，不 *1000
    expect(d[1]).toEqual([50, 51, null]);
    expect(d[2]).toEqual([25, 25, 30]);
    expect(d[3]).toEqual([30, null, 40]);
  });

  test("喂了 Date 对象会被翻译成秒级数字（*_1000 是 Chart.js 时代的包袱）", async () => {
    const c = await core();
    const d = c.historyColumns([{ ts: 1000, temp: 1, level: 1, ec76: 1 }]);
    expect(typeof d[0][0]).toBe("number");
    expect(d[0][0]).toBe(1000);
  });

  test("空/脏输入不抛，且长度自洽", async () => {
    const c = await core();
    for (const bad of [[], null, undefined]) {
      const d = c.historyColumns(bad);
      expect(Array.isArray(d)).toBe(true);
      expect(d).toHaveLength(4);
      expect(d[0]).toEqual([]);
    }
  });

  test("缺 ts 的行整体丢弃（不能拿 undefined 当 x 轴刻度）", async () => {
    const c = await core();
    const d = c.historyColumns([{ ts: 1, temp: 1, level: 1, ec76: 1 },
                                { temp: 2, level: 2, ec76: 2 },
                                { ts: 3, temp: 3, level: 3, ec76: 3 }]);
    expect(d[0]).toEqual([1, 3]);
    expect(d[1]).toEqual([1, 3]);
  });
});

describe("V2: 800 点降采样（每 goroutine-free 次拉全量历史的关键防线）", () => {
  test("≤800 不动，>800 收敛到 800 且保持首尾", async () => {
    const c = await core();
    const src = Array.from({ length: 5000 }, (_, i) => i);
    const out = c.decimate(src, 800);
    expect(out).toHaveLength(800);
    expect(out[0]).toBe(0);
    expect(out[799]).toBe(4999);
    const small = c.decimate([1, 2, 3], 800);
    expect(small).toEqual([1, 2, 3]);
  });

  test("均匀性：相邻间隔不超过 2 步（不会把后一半数据全丢掉）", async () => {
    const c = await core();
    const out = c.decimate(Array.from({ length: 8000 }, (_, i) => i), 800);
    const gaps = out.slice(1).map((v, i) => v - out[i]);
    expect(Math.max(...gaps)).toBeLessThanOrEqual(20);   // 8000/800=10 → ≤20 留余量
    expect(Math.min(...gaps)).toBeGreaterThanOrEqual(1);
  });

  test("cap 非法/空输入安全", async () => {
    const c = await core();
    expect(c.decimate([], 800)).toEqual([]);
    expect(c.decimate(null, 800)).toEqual([]);
    expect(c.decimate([1, 2, 3], 0)).toEqual([1, 2, 3]);
  });
});

describe("V2: 散点图 uPlot 化（unsorted x 必须标 sorted:0）", () => {
  test("抽出 {x:温度,y:档位} 并过滤非法档位（0=释放，>100=越界）", async () => {
    const c = await core();
    const pts = c.scatterPoints([
      { temp: 50, level: 25 }, { temp: 51, level: 0 },
      { temp: 52, level: 101 }, { temp: null, level: 30 },
      { temp: 53, level: null }, { temp: 54, level: 100 },
    ]);
    expect(pts.x).toEqual([50, 54]);
    expect(pts.y).toEqual([25, 100]);
  });

  test("sorted=-1/1/0：实测温度【不是】升序 → 必须 0，否则点会画错位置", async () => {
    const c = await core();
    expect(c.xSortedFlag([3, 1, 2])).toBe(0);
    expect(c.xSortedFlag([1, 2, 3])).toBe(1);
    expect(c.xSortedFlag([3, 2, 1])).toBe(-1);
    expect(c.xSortedFlag([])).toBe(0);
    expect(c.xSortedFlag([1])).toBe(1);      // 单点是升序也是降序 → 报升序，uPlot 无所谓
  });

  test("散点降采样后 x/y 仍然等长（错位 = 整幅图散架）", async () => {
    const c = await core();
    const big = Array.from({ length: 3000 }, (_, i) => ({ temp: 35 + (i % 70), level: 25 + (i % 70) }));
    const pts = c.scatterPoints(big);
    const d = c.decimateCols([pts.x, pts.y], 800);
    expect(d[0]).toHaveLength(800);
    expect(d[1]).toHaveLength(800);
  });
});

describe("V2: 理想阶梯曲线（设定曲线的静态投影）", () => {
  test("每段从上一段档位水平延伸到本段上界，最后延到 105°C", async () => {
    const c = await core();
    const s = c.idealStep([{ upto: 56, level: 30 }, { upto: 62, level: 40 },
                           { upto: 80, level: 70 }]);
    expect(s.x[0]).toBe(56);       expect(s.y[0]).toBe(30);
    expect(s.x).toContain(62);     expect(s.y).toContain(40);
    expect(Math.max(...s.x)).toBe(105);
    expect(s.x[s.x.length - 1]).toBe(105);
    // x 必须升序 —— uPlot line 画乱序点会来回折
    expect(c.xSortedFlag(s.x)).toBe(1);
  });

  test("bands 空/含 0 档 → 退化成空系列而不抛", async () => {
    const c = await core();
    expect(c.idealStep([]).x).toEqual([]);
    expect(c.idealStep(null).y).toEqual([]);
    expect(c.idealStep([{ upto: 56, level: 0 }, { upto: 62, level: 25 }]).y).toContain(25);
  });
});

// ================= V3: SVG 表盘几何（DOM-free 纯函数） =================

describe("V3: gaugeArc 几何", () => {
  const G = { cx: 50, cy: 50, r: 40, sweep: 240, start: 150 };

  test("0% → 满 dashoffset（弧不可见）；100% → 0", async () => {
    const c = await core();
    const full = c.gaugeArc({ ...G, value: 0, min: 0, max: 100 });
    expect(full.dashoffset).toBeCloseTo(full.circumference, 6);
    const at100 = c.gaugeArc({ ...G, value: 100, min: 0, max: 100 });
    expect(at100.dashoffset).toBeCloseTo(0, 6);
  });

  test("中点 = 半个 sweep", async () => {
    const c = await core();
    const m = c.gaugeArc({ ...G, value: 50, min: 0, max: 100 });
    expect(m.dashoffset).toBeCloseTo(m.circumference * 0.5, 6);
  });

  test("周长只由 sweep 决定：整圆 vs 240°（几何与 value 无关）", async () => {
    const c = await core();
    const full = c.gaugePath({ cx: 0, cy: 0, r: 10, sweep: 360, start: 0 });
    expect(full.circumference).toBeCloseTo(2 * Math.PI * 10, 6);
    const arc = c.gaugePath({ cx: 0, cy: 0, r: 10, sweep: 240, start: 0 });
    expect(arc.circumference).toBeCloseTo(2 * Math.PI * 10 * (240 / 360), 6);
  });

  test("路径从左端点到右端点（240° ≠ 半圆，得算坐标）", async () => {
    const c = await core();
    // 几何本身与 value 无关 → 单独由 gaugePath 暴露（gaugeArc 在 value 无效时会返回 null，
    // 那时拿不到 path —— 两者职责必须分开，否则空态连底弧都画不出来）
    const d = c.gaugePath({ cx: 50, cy: 50, r: 40, sweep: 240, start: 150 });
    const nums = d.path.match(/-?\d+(\.\d+)?/g).map(Number);
    // 起点：150° → (50+40cos150, 50-40sin150)
    expect(nums[0]).toBeCloseTo(50 + 40 * Math.cos(150 * Math.PI / 180), 3);
    expect(nums[1]).toBeCloseTo(50 - 40 * Math.sin(150 * Math.PI / 180), 3);
    // 终点：150+240=390° → 等价于 30°
    expect(nums[nums.length - 2]).toBeCloseTo(50 + 40 * Math.cos(390 * Math.PI / 180), 3);
    expect(nums[nums.length - 1]).toBeCloseTo(50 - 40 * Math.sin(390 * Math.PI / 180), 3);
    expect(d.largeArc).toBe(1);        // 240° > 180° → large-arc-flag=1
    expect(d.sweepFlag).toBe(1);
  });

  test("半圈及以下 large-arc-flag=0（>180 的判定不能写死为 1）", async () => {
    const c = await core();
    expect(c.gaugePath({ cx: 0, cy: 0, r: 10, sweep: 180, start: 0 }).largeArc).toBe(0);
    expect(c.gaugePath({ cx: 0, cy: 0, r: 10, sweep: 181, start: 0 }).largeArc).toBe(1);
  });

  test("gaugeArc 返回体带上同一份 path（调用方不必再算一遍）", async () => {
    const c = await core();
    const g = c.gaugeArc({ cx: 50, cy: 50, r: 40, sweep: 240, start: 150,
                           value: 50, min: 0, max: 100 });
    expect(g.path).toBe(c.gaugePath({ cx: 50, cy: 50, r: 40, sweep: 240, start: 150 }).path);
  });

  test("非满量程：min/max 决定比例（0..120 下 60% = 一半）", async () => {
    const c = await core();
    const g = c.gaugeArc({ ...G, value: 60, min: 0, max: 120 });
    expect(g.dashoffset).toBeCloseTo(g.circumference * 0.5, 6);
  });

  test("越界钳制：超出 [min,max] 不会画出一个负 dashoffset", async () => {
    const c = await core();
    const over = c.gaugeArc({ ...G, value: 999, min: 0, max: 100 });
    expect(over.dashoffset).toBe(0);
    const under = c.gaugeArc({ ...G, value: -50, min: 0, max: 100 });
    expect(under.dashoffset).toBeCloseTo(under.circumference, 6);
  });

  test("min===max（配置错）不产生 NaN/Infinity", async () => {
    const c = await core();
    const bad = c.gaugeArc({ ...G, value: 5, min: 10, max: 10 });
    expect(Number.isFinite(bad.dashoffset)).toBe(true);
    expect(Number.isFinite(bad.circumference)).toBe(true);
  });

  test("value 为 null/undefined/NaN → null（调用方据此画空态）", async () => {
    const c = await core();
    for (const v of [null, undefined, NaN, "abc"]) {
      expect(c.gaugeArc({ ...G, value: v, min: 0, max: 100 })).toBeNull();
    }
  });
});

describe("V3: 阈值配色沿用 styles.css 的 .ok/.warn/.bad 语义", () => {
  test("温度：≤65 ok / 66..78 warn / >78 bad（沿用旧进度条的严格 >65/>78）", async () => {
    const c = await core();
    expect(c.tempClass(50)).toBe("ok");
    expect(c.tempClass(64)).toBe("ok");
    expect(c.tempClass(65)).toBe("ok");     // 严格大于：65 还没进预警
    expect(c.tempClass(66)).toBe("warn");
    expect(c.tempClass(78)).toBe("warn");
    expect(c.tempClass(79)).toBe("bad");
    expect(c.tempClass(95)).toBe("bad");
  });

  test("null 不是 bad（读不到 ≠ 过热），要有独立空态", async () => {
    const c = await core();
    expect(c.tempClass(null)).toBe("na");
    expect(c.tempClass(undefined)).toBe("na");
  });

  test("class → CSS 变量色号必须是 panel 现有调色板", async () => {
    const c = await core();
    expect(c.classColor("ok")).toBe("#3fb950");
    expect(c.classColor("warn")).toBe("#d29922");
    expect(c.classColor("bad")).toBe("#f85149");
    expect(c.classColor("na")).toBe("#484f58");
    expect(c.classColor("bogus")).toBe("#484f58");
  });

  test("档位表盘走档位阈值（>85 bad / >70 warn / 其余 ok）", async () => {
    const c = await core();
    expect(c.levelClass(50)).toBe("ok");
    expect(c.levelClass(70)).toBe("ok");
    expect(c.levelClass(75)).toBe("warn");
    expect(c.levelClass(90)).toBe("bad");
    expect(c.levelClass(null)).toBe("na");
  });

  test("数值不能被颜色独担：valueText 永远返回可显示字符串", async () => {
    const c = await core();
    expect(c.valueText(null)).toBe("--");
    expect(c.valueText(undefined)).toBe("--");
    expect(c.valueText(0)).toBe("0");     // 0 是合法读数
    expect(c.valueText(68)).toBe("68");
    expect(c.valueText(68.4)).toBe("68");
  });
});

describe("V3: 表盘必须真的接进 app.js（不是写在 core 里没人用）", () => {
  test("paint 走 setGauge + core 的 POST/norm 纯函数", async () => {
    const c = await core();
    // 这几个是 app.js 画表盘必经的导出；缺一个就是"写了没接线"
    expect(c.gaugeArc).toBeTypeOf("function");
    expect(c.tempClass).toBeTypeOf("function");
    expect(c.levelClass).toBeTypeOf("function");
    expect(c.classColor).toBeTypeOf("function");
    expect(c.valueText).toBeTypeOf("function");
    expect(c.gaugeMarkup).toBeTypeOf("function");
  });

  test("app.js 代码行里有 gaugeMarkup 调用，且仍从 core.js 取数", async () => {
    const code = codeOnly(await appSrc());
    expect(code).toMatch(/gaugeMarkup\(/);
    expect(code).toMatch(/from\s+["']\/pfan-core\.js["']/);
  });
});
