// uPlot 由本机 vendored 路由提供（服务端 /pfan-vendor-uplot.js 从 panel/vendor 直读）。
// 静态 route import 而非 CDN <script>：面板要在无出口的 LAN 设备上跑，
// 且 ESM 的 default 导出即 uPlot 构造器（vendored 文件末尾 export { uPlot as default }）。
import uPlot from "/pfan-vendor-uplot.js";
import { checkTempOrder, classColor, curveParamsHtml, curveRowsHtml, dbOf, decimateCols,
         esc, fetchJson, fmtTemp, gaugeMarkup, historyColumns, idealStep, isStale,
         levelClass, rpmOf, scatterPoints, statusText, tempClass, valueText,
         xSortedFlag, DEFAULT_STALE_AGE, staleAgeLimit } from "/pfan-core.js";

const API="";   // 同源：反代 /pfan -> 8789，用相对路径即可
const TOKEN="__PFAN_TOKEN__";   // 服务端注入真值；/pfan.js 免鉴权 ⇒ 任何能访问面板者一次 GET 就拿到，同源策略不保护它。挡住跨站【浏览器】的是浏览器模型（无 ACAO 读不回响应、脚本报不出带该自定义头的跨域请求），不是保密；curl 两样都能做。详见 SECURITY.md
// 0 已移除：实测 _FSL 0 在 s0i3 下 = 风扇停转（2026-10-06），不允许从 UI 停扇
const LV=[25,30,40,50,60,70,80,85,90,95,100];
// curLevel 必须【声明】：模块永远是严格模式，`curLevel=d.level` 这种未声明赋值
// 会直接抛 ReferenceError（实测），paint() 会在第 2 行就死 —— 面板永不刷新。
let ch1,ch2,cur=25,lastLvl=null,curLevel=null;

async function j(u,o){
  o=o||{};
  if((o.method||"GET").toUpperCase()==="POST"){
    o.headers=Object.assign({},o.headers,{"X-Pfan-Token":TOKEN});
  }
  // ⑰ 网络/HTTP/解析三类失败都会被 fetchJson 翻成带原因的 Error，
  // 调用方必须 catch —— 否则在 setInterval 里会变成未捕获异常、面板静默停更。
  return fetchJson(u,o);
}

/* ---------------- ⑰ 连接状态与数据新鲜度 ---------------- */
let lastSnap=null;
// 滞后阈值：由服务端 params.IV 派生（staleAgeLimit(2*IV)），不再写死 20s。
// 默认回退 DEFAULT_STALE_AGE —— /api/curve 还没回来前按旧口径判。
let STALE_AGE=DEFAULT_STALE_AGE;
function why(e){ return (e&&e.message)||String(e); }
// R-09：动作失败是【粘性】的 —— 只有下一个动作开始才清除。旧行为里下一次成功的
// 8s 轮询用 setConn(null) 把「切换曲线失败」抹掉，失败在 ≤8s 后看起来像成功
// （2026-10-17 实测：+0.4s 红 → +9.4s 绿「实时」，而编辑器根本没打开）。
// 只服务 #conn-st 通道的五个动作；saveParams 的失败走编辑器自己的 #ed-msg，与此无关。
let actErr=null;
function setConn(err){
  const e=document.getElementById("conn-st"); if(!e) return;
  const t=statusText(lastSnap,STALE_AGE,err);
  e.textContent=t;
  // 绿=实时（isStale=false）；黄=滞后/缓存/无数据；红=取数或写操作失败
  e.style.color = err ? "#f85149" : (isStale(lastSnap,STALE_AGE) ? "#d29922" : "#3fb950");
}
function applyIV(iv){
  const n=staleAgeLimit(iv);
  if(n===STALE_AGE) return;
  STALE_AGE=n; setConn(actErr);   // 阈值变了，立刻按新阈值重画状态条（不吞粘性动作错误）
}
async function pollNow(){
  try{
    lastSnap=await j(API+"/api/now");
    paint(lastSnap);
    setConn(actErr);   // R-09：轮询成功【不】清除动作失败；有未清除的 actErr 就继续显示
  }catch(e){ setConn(e&&e.message||String(e)); }
}

/* ---------------- SVG 弧形表盘 ----------------
 * 几何/配色/文案全在 core.js（纯函数、有单测）；这里只做 DOM 写入。
 * 数值与颜色是两个独立通道：色盲/单色屏也必须能读出具体数字（温度右上角那行 <div class=v>）。 */
function paintGauge(arcId, valId, v, min, max, unit, cls) {
  const clsFn = typeof cls === "function" ? cls : (cls === "temp" ? tempClass : levelClass);
  const c = clsFn(v);
  const box = document.getElementById(arcId);
  if (box) box.innerHTML = gaugeMarkup({ value: v, min, max, cls: c, unit, label: unit });
  const el = document.getElementById(valId);
  if (!el) return;
  el.innerHTML = valueText(v) + '<span class="u">' + unit + '</span>';
  // 数字本身也上色（冗余通道），但 "--" 用中性灰，不用 semantically wrong 的红
  el.style.color = classColor(c);
}

function paint(d){
  cur=d.level; curLevel=d.level;
  // R-05：这里曾传字面量 "classTemp" → 与 paintGauge 里 `cls === "temp"` 的分支
  // 永不匹配，全部走 levelClass，"temp" 分支恒死：79–85.9°C（82°C 看门狗区）画成琥珀而非红。传 "temp"。
  paintGauge("c-temp-arc","c-temp",d.temp,0,105,"°C","temp");
  paintGauge("c-lvl-arc","c-lvl",d.level,0,120,"%","level");
  document.getElementById("c-ec").innerHTML=(d.ec76==null?"--":d.ec76)+'<span class="u">%</span>';
  document.getElementById("c-rpm").innerHTML=(d.rpm==null?"--":d.rpm)+'<span class="u">rpm</span>';
  const ecd=document.getElementById("c-ec");
  ecd.className="v "+(d.ec76>d.level+8?"warn":d.ec76<d.level-8?"warn":"ok");
  document.getElementById("c-ec-note").textContent =
    d.ec76==null?"EC 未响应":(d.ec76>d.level+5?"固件自行加速降温":"与设定一致");
  document.getElementById("c-rpm-note").textContent = d.fps?
    // fps[1] 是 noise_mdB：直接拼会显示 "35000mdB"，用户要的是 35.0dB
    ("官方表 "+d.fps[0]+"rpm / "+(d.fps[1]/1000).toFixed(1)+"dB"):"—";
  LV.forEach(v=>{const b=document.getElementById("lv"+v);if(b)b.classList.toggle("on",v===d.level)});
  // 曲线表的「◀ 现在」高亮跟着 8s 轮询走：renderCurve 的全量刷新间隔是 180s，
  // 中间档位变了表却不动（"视图永不刷新"）。这里只重渲染纯函数产出的 tbody。
  const ct=document.querySelector('#cvtbl tbody');
  if(ct&&window.CURVE&&window.CURVE.bands) ct.innerHTML=curveRowsHtml(window.CURVE.bands,d.level);
  // 模式横幅
  const st=document.getElementById("m-st"), tx=document.getElementById("m-tx");
  if(d.curve==="s0i3"){
    st.textContent="自定义曲线（守护接管）"; st.className="st d";
    tx.textContent="pfand 按温度曲线调档，档位由守护决定。点档位按钮会进入接管模式。";
  } else if(d.curve==="free"){
    st.textContent="接管模式（手动）"; st.className="st m";
    tx.textContent="守护已暂停，档位完全由你定。看门狗 82°C 仍会强制回退保护。";
  } else {
    st.textContent="固件曲线（"+(d.curve||"auto")+"）"; st.className="st d";
    tx.textContent="由 EC 固件自己的曲线控制，pfand 未接管。要精确控制请切 s0i3。";
  }
  // 曲线高亮
  const cv=d.curve||"auto";
  ["quiet","s0i3","cool","free","auto"].forEach(n=>{
    const b=document.getElementById("cv-"+n); if(b) b.classList.toggle("on",n===cv);
  });
  const note=document.getElementById("curve-note");
  if(cv==="s0i3"){
    const c=window.CURVE||{};
    let tb="";
    if(c.IDLE!==undefined){
      const bands=[["≤"+c.IDLE,c.L0],["≤"+c.T1,c.L1],["≤"+c.T2,c.L2],
                   ["≤"+c.T3,c.L3],["≤"+c.T4,c.L4],["≤"+c.T5,c.L5],
                   ["≥"+c.EMERG,c.E||100]];
      // ②⑧ RPM/噪音必须来自权威表：旧的 nz 字面量缺 85/90/95（那几档显示 0），
      // 噪音也用 lvl*0.5 硬算。window.FPS 由 boot() 从 /api/levels 填入。
      const fps=window.FPS||{};
      tb='<table style="margin-top:8px;font-size:12px"><thead><tr><th>温度</th><th>档位</th><th>RPM</th><th>噪音dB</th><th></th></tr></thead><tbody>'
        +bands.map(([t,l])=>{
            const lvl=parseInt(l,10), rpm=rpmOf(lvl,fps) ?? '—';
            const dB=dbOf(lvl,fps) ?? '—';
            const note = lvl===c.L3?"听感甜点":lvl===c.L5?"上限":lvl===c.E?"应急":"";
            return `<tr><td>${t}°C</td><td><b>${l}%</b></td><td>${rpm}</td><td>${dB}</td><td style="color:#d29922">${note}</td></tr>`;
          }).join("")
        +'</tbody></table>';
    }
    // R-07b：标签行的字段在 window.CURVE.params 里 —— window.CURVE 是 curve_view
    // （{params,bands,curve}），旧的 c.HYST 一直是 undefined：健康机器上每次 8s 轮询
    // 都会把「迟滞 undefined°C … undefineds」写进屏幕（2026-10-18 实机只读复核），
    // /api/curve 失败时同样。改读 params，?? '-' 只兜真正的缺数据。
    const cp=(window.CURVE&&window.CURVE.params)||{};
    note.innerHTML='<b style="color:#3fb950">自定义曲线生效中</b> —— s0i3 已让固件退出热保护，'+
      'EC 完全跟随 pfand 的设定值。'+tb+
      '<br><span class="tag g">迟滞 '+(cp.HYST??'-')+'°C 防抖</span>'+
      '<span class="tag">应急 '+(cp.EMERG??'-')+'°C 满速，'+(cp.EMERG_REL??'-')+'°C 才解除（锁定防抖）</span>'+
      '<span class="tag">采样 '+(cp.IV??'-')+'s</span>'+
      '<br><b>本机余量</b>：实测全核负载下 25% 最低档也仅 68°C → 应急线 80°C 很难触及。';
  } else if(cv==="free"){
    note.innerHTML='<b style="color:#d29922">自由模式</b> —— 曲线守护已暂停，'+
      'EC 只跟随你手动选的档位（仍在 s0i3 下，所以设定值一定生效）。'+
      '<br>用上面的档位按钮直接挑；看门狗仍在——超过 '+GUARD_TEMP+'°C 会自动回退到安全曲线（quiet/s0i3/free 同一套，见 server GUARDED）。'+
      '<br>想回到自动曲线，点「交还 pfand 守护」（s0i3 按钮）。';
  } else if(cv!=="auto"){
    // cv 来自 API 的字符串字段 → 进 innerHTML 前必须 esc()（服务端今天会白名单，
    // 但 panel 是无鉴权读端点，不能把 XSS 缝赌在"服务端恰好没写错"上）
    note.innerHTML='<b style="color:#d29922">当前 '+esc(cv)+' 曲线生效中</b> —— 已释放设定值(_FSL=0)并停守护，'+
      'EC 完全按固件曲线走。<br>⚠️ 社区实测 quiet 会把温度拉到 ~74°C 且周期性震荡。'+
      '<span class="tag" style="background:#5a1d1d;color:#f85149">看门狗 '+GUARD_TEMP+'°C 自动回退</span>';
  } else {
    note.innerHTML='当前由 <b>pfand 守护</b>按温度曲线调档（设定值生效，EC 固件曲线被忽略）。'+
      '<br>切到 quiet 会释放设定值，让 EC 用固件自己的静音曲线。';
  }
  lastLvl=d.level;
}

function buildLv(){
  const box=document.getElementById("levels");
  if(!box) return;   // DOM 结构被改动时宁可没有按钮，也不能让 boot 在 try 之前就死
  LV.forEach(v=>{const b=document.createElement("button");
    b.id="lv"+v;b.textContent=v;b.onclick=()=>setLvl(v);box.appendChild(b)});
}
let MODE="daemon";
let GUARD_TEMP=82;
// ⑰ 写路径：这些是用户点下去在等结果的动作，失败必须给可见反馈（复用 #conn-st 状态条）。
// 旧实现全是裸 await —— 网络抖一下按钮"点了没反应"，用户无从判断是没生效还是没发出去。
// R-09：失败还必须是【粘性】的（actErr）—— 每个动作开始时清除旧错误并立即反映到状态条，
// 失败则写回 actErr；pollNow 成功只重画、不清除，错误至少留到下一个动作。
async function setCurve(n){
  try{
    actErr=null; setConn(null);
    const d=await j(API+"/api/profile",{method:"POST",headers:{"Content-Type":"application/json"},
      body:JSON.stringify({profile:n})});
    paint(d);
  }catch(e){ actErr="切换曲线失败: "+why(e); setConn(actErr); }
}
async function setLvl(v){
  try{
    actErr=null; setConn(null);
    // 守护模式下先接管，否则 10 秒内会被自动改回
    if(MODE!=="manual"){
      await j(API+"/api/now",{method:"POST",headers:{"Content-Type":"application/json"},
        body:JSON.stringify({hold:true})});
      MODE="manual";
    }
    const d=await j(API+"/api/now",{method:"POST",headers:{"Content-Type":"application/json"},
      body:JSON.stringify({level:v})});
    paint(d);
  }catch(e){ actErr="设置档位失败: "+why(e); setConn(actErr); }
}
async function setHold(){
  try{
    actErr=null; setConn(null);
    const d=await j(API+"/api/now",{method:"POST",headers:{"Content-Type":"application/json"},
      body:JSON.stringify({hold:true})});
    MODE="manual"; paint(d);
  }catch(e){ actErr="接管失败: "+why(e); setConn(actErr); }
}
async function setAuto(){
  try{
    actErr=null; setConn(null);
    const d=await j(API+"/api/now",{method:"POST",headers:{"Content-Type":"application/json"},
      body:JSON.stringify({auto:true})});
    MODE="daemon"; paint(d);
  }catch(e){ actErr="交还守护失败: "+why(e); setConn(actErr); }
}

/* ---------------- 图表（uPlot） ----------------
 * uPlot 构造器签名是 new uPlot(opts, data, target)，data 是【列式】
 * [x[], y1[], y2[]] —— 由 core.historyColumns 出。xScale:{time:true} +
 * 默认 ms=1e-3 ⇒ x 取 unix【秒】（Chart.js 时代的 *1000 必须留在历史服务业 trace 里）。 */
// uPlot 不带主题，颜色全部显式给；容器继承 body 的 #0d1117，不用再铺底。
const TICK = "#8b949e", GRID = "#21262d";
const TIME_AXIS = { stroke: TICK, grid: { stroke: GRID, width: 1 },
                    ticks: { stroke: GRID } };
const Y_AXIS = { stroke: TICK, grid: { stroke: GRID, width: 1 },
                 ticks: { stroke: GRID } };
const LEGEND = { show: true, stroke: TICK, live: true };
// 轴标题/刻度 ⇒ uPlot 默认继承 body 的字体，这里统一 panel 的 #8b949e 灰
const T_STAMP = "YYYY-MM-DD HH:mm:ss";

/* uPlot【不会】自己跟着容器跑 —— 它只在构造时按 opts.width/height 算一次
 * （源码里没有 ResizeObserver；见 vendored 文件 _setSize(opts.width, opts.height)）。
 * 而 .uplot 的默认 CSS 是 width:min-content ⇒ 不给宽高等尺寸的话图会塌成一条线。
 * 旧版 Chart.js 用 responsive:true 自动处理这件事，这里必须手动补。
 * 做法：构造前把宿主盒子的实测尺寸喂进去，并挂 ResizeObserver 持续同步
 * （ResizeObserver 触发时会回调一次初始尺寸，不会重复损失首帧）。 */
// ⚠ 必须量【父容器】.chartbox，不能量 #chN 自己。
// #chN 的高度 = uPlot 的 .u-wrap 高度 + 32px 的 .u-legend（.u-wrap 的兄弟节点）。
// 把这个值原样喂回 u.setSize 就是 h = h + 32 —— 没有不动点，图表无界增高。
// （专家审计 CRITICAL 1，浏览器实测：#ch1 长到 11744px、整页 7658px，
//  把 #ch1 钉成 220px 后 4 次采样全部稳定在 220px。）
const CHART_H = 220;
function sizeOf(el) {
  const box = el.parentElement || el;   // .chartbox 才是由 CSS 定高、且不含图例的元素
  const b = box.getBoundingClientRect();
  return {
    width: Math.max(0, b.width || el.getBoundingClientRect().width),
    height: Math.max(0, b.height || CHART_H),
  };
}
function fitChart(el, u) {
  if (!el || !u) return;
  const s = sizeOf(el);
  let last = s;
  if (s.width > 0 && s.height > 0) u.setSize(s);
  // 面板后台标签/窗口缩放都要跟随；ResizeObserver 不可用时（老浏览器）退回
  // 一次性 fitting —— 图不会跟着变但不至于塌掉
  if (typeof ResizeObserver === "function") {
    // 观察父容器（.chartbox），不是 #chN —— 否则 setSize 又会触发自己的观察者
    new ResizeObserver(() => {
      const t = sizeOf(el);
      if (t.width <= 0 || t.height <= 0) return;
      // 反馈回环的护栏：只把【不同于上次请求】的尺寸喂回去。
      // 没有这一条，任何"测量对象包含 uPlot 自身高度"的改动都会重新变成无界增长。
      // ⚠ 键名必须与 sizeOf() 的返回值一致（{width,height}）。之前这里写的是
      // last.w / last.h，与返回对象的键永不匹配 —— undefined === number 恒假，
      // 于是这条"反馈回环 fail closed"的护栏从不触发，而 commit b06a191 把它
      // 描述成一道已经就位的第二道防线（2026-10-09 自审发现）。
      if (last.width === t.width && last.height === t.height) return;
      last = t;
      u.setSize(t);
    }).observe(el.parentElement || el);
  }
}
function mount(elId, opts, data) {
  const el = document.getElementById(elId);
  if (!el) return null;
  return new uPlot(Object.assign({}, sizeOf(el), opts), data, el);
}

function initCharts(h) {
  const cols = historyColumns(h);
  // 第 4 列是 EC 另一端：ch2 独立使用以免与 temp/level 的 y 值域互相拉扯
  ch1 = mount("ch1", {
    scales: { x: { time: true }, y: {}, pct: { range: [0, 120] } },
    legend: LEGEND,
    series: [
      {},
      { label: "温度 °C", stroke: "#f0883e", fill: "rgba(240,136,62,.12)", width: 1.5 },
      { label: "档位 %", stroke: "#3fb950", fill: "rgba(63,185,80,.10)",
        width: 1.5, scale: "pct" },
    ],
    axes: [TIME_AXIS, Y_AXIS],
  }, [cols[0], cols[1], cols[2]]);
  fitChart(document.getElementById("ch1"), ch1);

  ch2 = mount("ch2", {
    scales: { x: { time: true }, y: { range: [0, 110] } },
    legend: LEGEND,
    series: [
      {},
      { label: "EC 0x76 实际状态 %", stroke: "#58a6ff",
        fill: "rgba(88,166,255,.14)", width: 1.5 },
    ],
    axes: [TIME_AXIS, Y_AXIS],
  }, [cols[0], cols[3]]);
  fitChart(document.getElementById("ch2"), ch2);
}

async function refreshHist(){
  try{
    const h=await j(API+"/api/history?hours=12");
    if(!h.length) return;
    const T=x=>x*1000;
    if(!ch1){ initCharts(h); }
    else{
      // uPlot 的 setData(data, true)：第二参 true = 重算值域。
      // 等价旧版chart.update('none')的无动画刷新 ——800 点降采样已在 core 层完成，
      // 这里只是把新的三个列灌回去。
      const c=historyColumns(h);
      ch1.setData([c[0],c[1],c[2]], true);
      ch2.setData([c[0],c[3]], true);
    }
    const tb=document.querySelector("#hist tbody");
    tb.innerHTML=h.slice(-14).reverse().map(x=>`<tr>
      <td class="mono">${new Date(T(x.ts)).toLocaleTimeString("zh-CN",{hour12:false})}</td>
      <td>${x.temp==null?"--":x.temp+"°C"}</td>
      <td>${x.level==null?"--":x.level+"%"}</td>
      <td>${x.ec76==null?"--":x.ec76+"%"}</td></tr>`).join("");
  }catch(e){ setConn("刷新历史曲线失败: "+why(e)); }   // 以前在 setInterval 里裸抛 = 未捕获 rejection
}

async function renderCurve(cv){
  const cur=(typeof curLevel!=='undefined')?curLevel:null;
  const tb=document.querySelector('#cvtbl tbody');
  // 行/参数文案的纯逻辑在 core.js（curveRowsHtml/curveParamsHtml），这里只负责挂到 DOM
  if(tb){
    tb.innerHTML=curveRowsHtml(cv.bands, cur);
  }
  const p=(cv&&cv.params)||{};
  const pn=document.getElementById('cvparams');
  if(pn) pn.innerHTML = curveParamsHtml(p);

  // 曲线模式说明 + 按钮高亮
  const cv2=(cv&&cv.curve)||'auto';
  ["quiet","s0i3","cool","auto"].forEach(n=>{
    const b=document.getElementById("cv-"+n); if(b) b.classList.toggle("on",n===cv2);
  });
  const note=document.getElementById('curve-note');
  if(note){
    if(cv2==="s0i3"){
      note.innerHTML='<b style="color:#3fb950">自定义曲线生效中</b> —— s0i3 已让固件退出热保护，'+
        'EC 完全跟随 pfand 的设定值。点「⚙ 自定义曲线」可在线改参数。'+
        '<br><span class="tag g">迟滞 '+(p.HYST??'-')+'°C 防抖</span>'+
        '<span class="tag">应急 '+(p.EMERG??'-')+'°C 满速，'+(p.EMERG_REL??'-')+'°C 才解除</span>';
    } else if(cv2==="quiet"){
      note.innerHTML='<b style="color:#d29922">quiet 固件曲线</b> —— 由 EC 固件自己的静音曲线接管，'+
        'pfand 守护已停。⚠️ 社区实测会拉到 ~74°C 且震荡。看门狗 '+
        // GUARD_TEMP 是模块变量（boot 从 /api/profile 写入）。window.GUARD_TEMP 从未被赋值，
        // 旧写法恒读到 82 —— 运维改过 guard_temp 面板也不跟。
        '<span class="tag" style="background:#5a1d1d;color:#f85149">'+ GUARD_TEMP +'°C 自动回退</span>';
    } else if(cv2==="auto"){
      note.innerHTML='当前由 <b>固件曲线</b>接管（固件会按自己的温度曲线自行提速，'+
        '外部设定值可能被顶到 58~73%）。要精确控制请切 s0i3。';
    } else {
      note.innerHTML='<b>'+esc(cv2)+'</b>';   // API 字符串 → esc()
    }
  }
  drawScatter();
}

// ---- 散点图：温度 → 档位 ----
let ch3=null;
async function drawScatter(){
  // ⑰ 复选框切换 / renderCurve 收尾都会调它，失败不能变成未捕获 rejection
  try{
    const only=document.getElementById('conly')?.checked;
    const h=await j(API+"/api/history?hours=24"+(only?"&curve=1":""));
    // 剔除非法档位（0=释放控制、>100=越界）+ 800 点降采样：都在 core.scatterPoints 里。
    // 降采样保留就在这里之前做：24h 全量可达数千点，每个点一条 canvas 指令会卡浏览器。
    const pts=scatterPoints(h);
    const cv=await j(API+"/api/curve");
    // 理想阶梯曲线：每段从上一段档位水平延伸到本段上界（几何在 core.idealStep）
    const st=idealStep((cv.bands||[]).filter(b=>b.level>0));
    if(ch3){ ch3.setData([pts.x,pts.y,st.x,st.y], true); return; }
    // 实测点的温度列【不是】单调的 → xScale.sorted=0（默认 1 会让 uPlot 按升序二分找 x，
    // 把点画到错误位置）。两列共享同一个 scale key，所以一个 xScale 就够。
    ch3=mount("ch3",{
      scales:{ x:{ range:[35,105], sorted:xSortedFlag(pts.x) },
               y:{ range:[0,105] } },
      legend:LEGEND,
      series:[
        {},
        // 点云用 points 而不是连线：这是"实测轨迹"，不是时间序列
        { label:"实测采样", stroke:"rgba(88,166,255,.45)", fill:"rgba(88,166,255,.45)",
          width:0, points:{ show:true, size:3, stroke:"rgba(88,166,255,.45)",
          fill:"rgba(88,166,255,.45)" } },
        { label:"设定曲线（阶梯）", stroke:"#3fb950", width:2, points:{show:false},
          dash:[5,4] },
      ],
      axes:[
        Object.assign({}, Y_AXIS, {label:"CPU 温度 °C", labelStroke:TICK}),
        Object.assign({}, Y_AXIS, {label:"风扇档位 %", labelStroke:TICK}),
      ],
    }, [pts.x,pts.y,st.x,st.y]);
    fitChart(document.getElementById("ch3"), ch3);
  }catch(e){ setConn("刷新散点图失败: "+why(e)); }
}

async function renderEvents(){
  try{
    const e=await j(API+"/api/events?limit=40");
    const kind={curve:'曲线',mode:'模式',guard:'看门狗'};
    const col={curve:'#58a6ff',mode:'#d29922',guard:'#f85149'};
    document.querySelector('#ev tbody').innerHTML = e.length ? e.map(x=>
      `<tr><td class="mono">${new Date(x.ts*1000).toLocaleString('zh-CN',{hour12:false})}</td>
       <td style="color:${col[x.kind]||'#8b949e'}">${esc(kind[x.kind]||x.kind)}</td>
       <td>${esc(x.msg)}</td></tr>`).join('')
      : '<tr><td colspan=3 style="color:#8b949e">暂无事件</td></tr>';
  }catch(e){ setConn("刷新事件流失败: "+why(e)); }
}

// R-06（五修之首）：'EMERG' 不在此列表 —— 骨架表 #edt 的红色应急行已经渲染 id="e_EMERG"
// 的输入框。重复 id 让 readEditor 的 last-wins 永远读到高级表那一份，编辑上方应急行被
// 静默忽略而保存仍报「已保存」（2026-10-17 实测）。应急温度只留一个编辑入口：骨架行。
const ED_KEYS=[
  ['EMERG_REL','应急解除 °C','降到此值才退出应急（防抖）'],
  ['CAP','档位上限 %','正常曲线最高到这'],
  ['TRIM','微调幅度 ±','叠加在骨架上的连续微调'],
  ['GAIN','微调增益 /°C','每偏离 1°C 加减几个点'],
  ['HYST','降档死区 °C','升档立即，降档需跌出此宽度'],
  ['DWELL','调档驻留 s','两次调档最小间隔'],
  ['DEAD','输出死区','差值小于此不写 EC'],
  ['IV','采样间隔 s','温度读取周期'],
];
let ED=null;

async function openEditor(){
  try{
    actErr=null; setConn(null);
    const r=await j(API+"/api/params");
    ED={params:{...r.params}, src:r.params};
    applyIV(r.params&&r.params.IV);   // 运维刚改过 IV？编辑器打开时同步阈值
    document.getElementById('ed-src').textContent=r.conf;
    renderEditor();
    document.getElementById('editor').style.display='';
    document.getElementById('editor').scrollIntoView({behavior:'smooth'});
  }catch(e){ actErr="打开参数编辑器失败: "+why(e); setConn(actErr); }   // 编辑器还没弹出来，只能走状态条
}
function closeEditor(){document.getElementById('editor').style.display='none';}
function resetParams(){ED.params={...ED.src};renderEditor();msg('已恢复为当前生效值（未保存）','#8b949e');}
function msg(t,c){const e=document.getElementById('ed-msg');e.innerHTML=`<span style="color:${c}">${t}</span>`;}

function renderEditor(){
  const p=ED.params;
  // 骨架表（6 档 + 应急）
  const rows=[];
  for(let i=0;i<6;i++){
    const tk=i===0?'IDLE':'T'+i, lk=i===0?'L0':'L'+i;
    // ②⑧/复审 I7：这里曾用 (lvl*120) 与 (lvl*0.5) 硬算 —— 70% 显示 8400 而权威表是 9300。
    // 与主曲线表同源：window.FPS 由 boot() 从 /api/levels 填入。
    const _lv=parseInt(p[lk],10);
    const rpm=rpmOf(_lv,window.FPS) ?? '—', db=dbOf(_lv,window.FPS) ?? '—';
    rows.push(`<tr>
      <td><input type="number" id="e_${tk}" value="${p[tk]}" min="-20" max="110" style="width:70px"></td>
      <td><input type="number" id="e_${lk}" value="${p[lk]}" min="0" max="120" style="width:70px"></td>
      <td class="mono">${rpm}</td><td class="mono">${db}</td></tr>`);
  }
  rows.push(`<tr style="background:#2d1214">
    <td><input type="number" id="e_EMERG" value="${p.EMERG}" min="60" max="105" style="width:70px"></td>
    <td><input type="number" id="e_E" value="${p.E}" min="0" max="120" style="width:70px"></td>
    <td class="mono">${rpmOf(parseInt(p.E,10),window.FPS) ?? '—'}</td>
    <td class="mono">${dbOf(parseInt(p.E,10),window.FPS) ?? '—'}</td></tr>`);
  document.querySelector('#edt tbody').innerHTML=rows.join('');

  // 高级参数表
  document.querySelector('#eda tbody').innerHTML=ED_KEYS.map(([k,label,desc])=>
    `<tr><td>${label}<br><span class="tag">${k}</span></td>
     <td><input type="number" id="e_${k}" value="${p[k]}" style="width:80px"></td>
     <td style="color:#8b949e;font-size:12px">${desc}</td></tr>`).join('');

  // 实时预览
  ['IDLE','T1','T2','T3','T4','T5','L0','L1','L2','L3','L4','L5','EMERG','E','CAP']
    .forEach(k=>document.getElementById('e_'+k)?.addEventListener('input',preview));
}
function readEditor(){
  const o={};
  document.querySelectorAll('#editor input[id^=e_]').forEach(i=>{
    o[i.id.slice(2)]=parseInt(i.value);
  });
  return o;
}
function preview(){
  const o=readEditor();
  // 校验逻辑在 core.js（可被 vitest 覆盖），这里只负责显示结果
  const err=checkTempOrder([o.IDLE,o.T1,o.T2,o.T3,o.T4,o.T5,o.EMERG]);
  if(err){ msg('⚠ '+err,'#f85149'); return; }
  msg('✓ 校验通过，点保存生效','#3fb950');
}
async function saveParams(){
  try{
    const o=readEditor();
    // 发送前本地拦两类注定失败的输入：空/非数字（parseInt→NaN→JSON null→服务端 500）
    // 与温度乱序（复用 preview 同一条 checkTempOrder，免得发一个必然 400 的请求）
    const nan=Object.keys(o).find(k=>!Number.isFinite(o[k]));
    if(nan){ msg('✗ '+nan+' 必须是整数（不能为空或非数字）','#f85149'); return; }
    const orderErr=checkTempOrder([o.IDLE,o.T1,o.T2,o.T3,o.T4,o.T5,o.EMERG]);
    if(orderErr){ msg('✗ '+orderErr,'#f85149'); return; }
    msg('保存中…','#8b949e');
    const r=await j(API+"/api/params",{method:'POST',
      headers:{"Content-Type":"application/json"},body:JSON.stringify({params:o})});
    if(r.ok){
      ED.src={...r.params};
      applyIV(r.params&&r.params.IV);   // IV 可能被改了 → 滞后阈值跟着换
      msg('✓ 已保存并重启守护','#3fb950');
      renderEditor();
      // R-07a：响应形状就是 curve_view（{"ok":true,"params":…,**curve_view()}），
      // 但旧代码只渲染不落盘 —— window.CURVE 停在启动时的旧值，8s 轮询/180s 全量刷新
      // 立刻把表格与阈值标签画回保存前的值。先落地再渲染，两者从此同源。
      window.CURVE=r; renderCurve(r);
      setTimeout(()=>{document.getElementById('editor').style.display='none';},1200);
    } else {
      msg('✗ '+((r.errors||[]).join('；')),'#f85149');
    }
  }catch(e){ msg('✗ 保存失败: '+why(e),'#f85149'); }   // 编辑器可见，用它自己的消息行
}

async function boot(){
  buildLv();
  // ⑰/U3 每个初始化请求【各自】兜底：旧版四个请求共用一个 try，
  // /api/levels 一失败就连带跳过 mode/profile/curve —— window.CURVE 永远是 undefined，
  // 曲线表、散点图、参数摘要从此再也不会渲染，且没有任何报错指向真正的原因。
  try{
    const lv=await j(API+"/api/levels");
    window.FPS = lv.fps;   // 权威 _FPS 表，band 渲染的 rpmOf/dbOf 用它
    document.querySelector("#fps tbody").innerHTML=Object.entries(lv.fps||{}).map(([k,v])=>
      `<tr><td>${k}%</td><td class="mono">${v[0]}</td><td class="mono">${(v[1]/1000).toFixed(1)}</td>
       <td class="mono">${(v[2]/1000).toFixed(2)}</td></tr>`).join("");
  }catch(e){ setConn("档位表加载失败: "+why(e)); }
  try{ MODE=(await j(API+"/api/mode")).mode; }
  catch(e){ setConn("运行模式读取失败: "+why(e)); }
  try{
    const pf=await j(API+"/api/profile");
    GUARD_TEMP=pf.guard_temp||82;
  }catch(e){ setConn("看门狗参数读取失败: "+why(e)); }
  try{
    window.CURVE=await j(API+"/api/curve");
    applyIV(window.CURVE&&window.CURVE.params&&window.CURVE.params.IV);   // M3: 阈值随 IV
  }catch(e){ setConn("曲线加载失败: "+why(e)); }
  renderCurve(window.CURVE||{params:{},bands:[]});   // 即便 curve 拉取失败也把散点图/表格拉起来
  await pollNow();
  renderEvents();
  refreshHist();
  setInterval(pollNow,8000);
  document.getElementById('conly')?.addEventListener('change',drawScatter);
  setInterval(refreshHist,45000);
  setInterval(()=>renderEvents(),30000);
  setInterval(()=>{if(window.CURVE)renderCurve(window.CURVE);},180000);
}
// 内联 onclick 走全局作用域，而模块顶层函数【不是】window 的属性 ——
// 不显式挂出去，index.html 里 setHold/setCurve/openEditor 等按钮点了全都没反应。
window.setHold=setHold;   window.setAuto=setAuto;    window.setCurve=setCurve;
window.openEditor=openEditor; window.saveParams=saveParams;
window.closeEditor=closeEditor; window.resetParams=resetParams;
boot().catch(e=>setConn(why(e)));   // 尾段若有异常也必须落到状态条，不能是未捕获 rejection
