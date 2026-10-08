import { checkTempOrder, curveParamsHtml, curveRowsHtml, dbOf, esc,
         fetchJson, fmtTemp, isStale, rpmOf, statusText,
         DEFAULT_STALE_AGE, staleAgeLimit } from "/pfan-core.js";

const API="";   // 同源：反代 /pfan -> 8789，用相对路径即可
const TOKEN="__PFAN_TOKEN__";   // 由服务端注入；跨站页面读不到（同源策略）
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
  STALE_AGE=n; setConn(null);   // 阈值变了，立刻按新阈值重画状态条
}
async function pollNow(){
  try{
    lastSnap=await j(API+"/api/now");
    paint(lastSnap);
    setConn(null);
  }catch(e){ setConn(e&&e.message||String(e)); }
}

function paint(d){
  cur=d.level; curLevel=d.level;
  document.getElementById("c-temp").innerHTML=fmtTemp(d.temp)+'<span class="u">°C</span>';
  document.getElementById("c-temp-bar").style.width=Math.min(100,(d.temp||0)/1.0)+"%";
  document.getElementById("c-temp-bar").style.background=d.temp>78?"#f85149":d.temp>65?"#d29922":"#1f6feb";
  document.getElementById("c-lvl").innerHTML=(d.level==null?"--":d.level)+'<span class="u">%</span>';
  document.getElementById("c-lvl-bar").style.width=Math.min(100,Number(d.level)||0)+"%";
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
    note.innerHTML='<b style="color:#3fb950">自定义曲线生效中</b> —— s0i3 已让固件退出热保护，'+
      'EC 完全跟随 pfand 的设定值。'+tb+
      '<br><span class="tag g">迟滞 '+c.HYST+'°C 防抖</span>'+
      '<span class="tag">应急 '+c.EMERG+'°C 满速，'+c.EMERG_REL+'°C 才解除（锁定防抖）</span>'+
      '<span class="tag">采样 '+c.IV+'s</span>'+
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
async function setCurve(n){
  try{
    const d=await j(API+"/api/profile",{method:"POST",headers:{"Content-Type":"application/json"},
      body:JSON.stringify({profile:n})});
    paint(d);
  }catch(e){ setConn("切换曲线失败: "+why(e)); }
}
async function setLvl(v){
  try{
    // 守护模式下先接管，否则 10 秒内会被自动改回
    if(MODE!=="manual"){
      await j(API+"/api/now",{method:"POST",headers:{"Content-Type":"application/json"},
        body:JSON.stringify({hold:true})});
      MODE="manual";
    }
    const d=await j(API+"/api/now",{method:"POST",headers:{"Content-Type":"application/json"},
      body:JSON.stringify({level:v})});
    paint(d);
  }catch(e){ setConn("设置档位失败: "+why(e)); }
}
async function setHold(){
  try{
    const d=await j(API+"/api/now",{method:"POST",headers:{"Content-Type":"application/json"},
      body:JSON.stringify({hold:true})});
    MODE="manual"; paint(d);
  }catch(e){ setConn("接管失败: "+why(e)); }
}
async function setAuto(){
  try{
    const d=await j(API+"/api/now",{method:"POST",headers:{"Content-Type":"application/json"},
      body:JSON.stringify({auto:true})});
    MODE="daemon"; paint(d);
  }catch(e){ setConn("交还守护失败: "+why(e)); }
}

function initCharts(h){
  // 用真正的 time 轴 + {x,y} 数据点。
  // 旧写法把 2000 个 Date 当 category labels，刻度会显示成
  // "2026-10-05T08:03:15.000Z" 这种完整 ISO 串，非常难看。
  const T=(x)=>x*1000;
  const tt={unit:'auto',displayFormats:{hour:'HH:mm',day:'MM-DD HH:mm',
    minute:'HH:mm',second:'HH:mm:ss'}};
  const ax={type:'time',time:tt,ticks:{color:'#8b949e',maxRotation:0,
    autoSkip:true,maxTicksLimit:8,autoSkipPadding:12},
    grid:{color:'#21262d'}};
  ch1=new Chart(document.getElementById('ch1'),{type:'line',
   data:{datasets:[
     {label:'温度 °C',data:h.filter(x=>x.temp!=null).map(x=>({x:T(x.ts),y:x.temp})),
      borderColor:'#f0883e',backgroundColor:'rgba(240,136,62,.12)',fill:true,
      tension:.3,pointRadius:0,yAxisID:'y'},
     {label:'档位 %',data:h.filter(x=>x.level!=null).map(x=>({x:T(x.ts),y:x.level})),
      borderColor:'#3fb950',backgroundColor:'rgba(63,185,80,.10)',fill:true,
      tension:.3,pointRadius:0,yAxisID:'y1'}]},
   options:{responsive:true,maintainAspectRatio:false,
    parsing:false,normalized:true,
    interaction:{mode:'index',intersect:false},
    plugins:{legend:{labels:{color:'#8b949e',boxWidth:12}},
      tooltip:{callbacks:{title:it=>new Date(it[0].parsed.x)
        .toLocaleString('zh-CN',{hour12:false})}}},
    scales:{x:ax,
      y:{position:'left',ticks:{color:'#8b949e'},grid:{color:'#21262d'},
         title:{display:true,text:'°C',color:'#8b949e'}},
      y1:{position:'right',min:0,max:120,ticks:{color:'#8b949e'},
         grid:{drawOnChartArea:false},title:{display:true,text:'%',color:'#8b949e'}}}}});
  ch2=new Chart(document.getElementById('ch2'),{type:'line',
   data:{datasets:[{label:'EC 0x76 实际状态 %',
     data:h.filter(x=>x.ec76!=null).map(x=>({x:T(x.ts),y:x.ec76})),
     borderColor:'#58a6ff',backgroundColor:'rgba(88,166,255,.14)',fill:true,
     tension:.3,pointRadius:0}]},
   options:{responsive:true,maintainAspectRatio:false,parsing:false,normalized:true,
    plugins:{legend:{labels:{color:'#8b949e',boxWidth:12}},
      tooltip:{callbacks:{title:it=>new Date(it[0].parsed.x)
        .toLocaleString('zh-CN',{hour12:false})}}},
    scales:{x:ax,y:{min:0,max:110,ticks:{color:'#8b949e'},grid:{color:'#21262d'}}}}});
}

async function refreshHist(){
  try{
    const h=await j(API+"/api/history?hours=12");
    if(!h.length) return;
    const T=x=>x*1000;
    if(!ch1){ initCharts(h); }
    else{
      ch1.data.datasets[0].data=h.filter(x=>x.temp!=null).map(x=>({x:T(x.ts),y:x.temp}));
      ch1.data.datasets[1].data=h.filter(x=>x.level!=null).map(x=>({x:T(x.ts),y:x.level}));
      ch1.update('none');
      ch2.data.datasets[0].data=h.filter(x=>x.ec76!=null).map(x=>({x:T(x.ts),y:x.ec76}));
      ch2.update('none');
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
    // 无条件剔除非法档位：0=释放控制、>100=越界
    let pts=h.filter(x=>x.temp!=null&&x.level!=null&&x.level>0&&x.level<=100)
                .map(x=>({x:x.temp,y:x.level}));
    // 降采样：点太多浏览器会卡（每点一个 canvas 绘制指令）
    const CAP=800;
    if(pts.length>CAP){
      const step=pts.length/CAP, out=[];
      for(let i=0;i<CAP;i++) out.push(pts[Math.floor(i*step)]);
      pts=out;
    }
    const cv=await j(API+"/api/curve");
    // 理想阶梯曲线：每段从上一段档位水平延伸到本段上界
    const bands=(cv.bands||[]).filter(b=>b.level>0);
    const ideal=[];
    let prev=null;
    bands.forEach(b=>{
      if(prev!==null&&prev!==b.level) ideal.push({x:b.upto,y:prev});
      ideal.push({x:b.upto,y:b.level});
      prev=b.level;
    });
    if(prev!==null) ideal.push({x:105,y:prev});
    ideal.sort((a,b)=>a.x-b.x);
    if(ch3){ch3.data.datasets[0].data=pts;ch3.data.datasets[1].data=ideal;ch3.update('none');return;}
    ch3=new Chart(document.getElementById('ch3'),{type:'scatter',
      data:{datasets:[
        {label:'实测采样',data:pts,backgroundColor:'rgba(88,166,255,.45)',
         pointRadius:1.5,borderWidth:0},
        {label:'设定曲线（阶梯）',data:ideal,type:'line',borderColor:'#3fb550',
         backgroundColor:'transparent',borderWidth:2,borderDash:[5,4],
         pointRadius:0,showLine:true}]},
      // 结构：plugins 与 scales 是 options 的【兄弟】。旧版把 scales 写进了 plugins，
      // Chart.js 会忽略 options.plugins.scales —— 轴标题/35..105 的范围全部不生效。
      options:{responsive:true,maintainAspectRatio:false,
        plugins:{legend:{labels:{color:'#8b949e',boxWidth:12}},
          tooltip:{callbacks:{label:c=>c.datasetIndex===1
            ?`曲线 ≤${c.parsed.x}°C → ${c.parsed.y}%`
            :`实测 ${c.parsed.x}°C → ${c.parsed.y}%`}}},
        scales:{x:{title:{display:true,text:'CPU 温度 °C',color:'#8b949e'},
            ticks:{color:'#8b949e'},grid:{color:'#21262d'},min:35,max:105},
          y:{title:{display:true,text:'风扇档位 %',color:'#8b949e'},
            ticks:{color:'#8b949e'},grid:{color:'#21262d'},min:0,max:105}}}});
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

const ED_KEYS=[
  ['EMERG','应急温度 °C','达到即 100% 满速'],
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
    const r=await j(API+"/api/params");
    ED={params:{...r.params}, src:r.params};
    applyIV(r.params&&r.params.IV);   // 运维刚改过 IV？编辑器打开时同步阈值
    document.getElementById('ed-src').textContent=r.conf;
    renderEditor();
    document.getElementById('editor').style.display='';
    document.getElementById('editor').scrollIntoView({behavior:'smooth'});
  }catch(e){ setConn("打开参数编辑器失败: "+why(e)); }   // 编辑器还没弹出来，只能走状态条
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
      if(window.CURVE) renderCurve(r);
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
