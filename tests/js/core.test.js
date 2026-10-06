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
