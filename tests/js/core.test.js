import { describe, expect, test } from "vitest";

import { checkTempOrder, dbOf, esc, fmtTemp, rpmOf } from "../../panel/core.js";

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
