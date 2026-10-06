import { checkTempOrder, dbOf, esc, fmtTemp, rpmOf } from "/pfan-core.js";

const API="";   // 同源：反代 /pfan -> 8789，用相对路径即可
const TOKEN="__PFAN_TOKEN__";   // 由服务端注入；跨站页面读不到（同源策略）
// 0 已移除：实测 _FSL 0 在 s0i3 下 = 风扇停转（2026-10-06），不允许从 UI 停扇
const LV=[25,30,40,50,60,70,80,85,90,95,100];
let ch1,ch2,cur=25,lastLvl=null;

async function j(u,o){
  o=o||{};
  if((o.method||"GET").toUpperCase()==="POST"){
    o.headers=Object.assign({},o.headers,{"X-Pfan-Token":TOKEN});
  }
  const r=await fetch(u,o);return r.json();
}

function paint(d){
  cur=d.level; curLevel=d.level;
  document.getElementById("c-temp").innerHTML=fmtTemp(d.temp)+'<span class="u">°C</span>';
  document.getElementById("c-temp-bar").style.width=Math.min(100,(d.temp||0)/1.0)+"%";
  document.getElementById("c-temp-bar").style.background=d.temp>78?"#f85149":d.temp>65?"#d29922":"#1f6feb";
  document.getElementById("c-lvl").innerHTML=(d.level==null?"--":d.level)+'<span class="u">%</span>';
  document.getElementById("c-lvl-bar").style.width=(d.level||0)+"%";
  document.getElementById("c-ec").innerHTML=(d.ec76==null?"--":d.ec76)+'<span class="u">%</span>';
  document.getElementById("c-rpm").innerHTML=(d.rpm==null?"--":d.rpm)+'<span class="u">rpm</span>';
  const ecd=document.getElementById("c-ec");
  ecd.className="v "+(d.ec76>d.level+8?"warn":d.ec76<d.level-8?"warn":"ok");
  document.getElementById("c-ec-note").textContent =
    d.ec76==null?"EC 未响应":(d.ec76>d.level+5?"固件自行加速降温":"与设定一致");
  document.getElementById("c-rpm-note").textContent = d.fps?
    ("官方表 "+d.fps[0]+"rpm / "+d.fps[1]+"mdB"):"—";
  LV.forEach(v=>{const b=document.getElementById("lv"+v);if(b)b.classList.toggle("on",v===d.level)});
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
      '<br>用上面的档位按钮直接挑，看门狗在此模式下<b>不接管</b>，温控责任在你。'+
      '<br>想回到自动曲线，点「交还 pfand 守护」（s0i3 按钮）。';
  } else if(cv!=="auto"){
    note.innerHTML='<b style="color:#d29922">当前 '+cv+' 曲线生效中</b> —— 已释放设定值(_FSL=0)并停守护，'+
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
  LV.forEach(v=>{const b=document.createElement("button");
    b.id="lv"+v;b.textContent=v;b.onclick=()=>setLvl(v);box.appendChild(b)});
}
let MODE="daemon";
let GUARD_TEMP=82;
async function setCurve(n){
  const d=await j(API+"/api/profile",{method:"POST",headers:{"Content-Type":"application/json"},
    body:JSON.stringify({profile:n})});
  paint(d);
}
async function setLvl(v){
  // 守护模式下先接管，否则 10 秒内会被自动改回
  if(MODE!=="manual"){
    await j(API+"/api/now",{method:"POST",headers:{"Content-Type":"application/json"},
      body:JSON.stringify({hold:true})});
    MODE="manual";
  }
  const d=await j(API+"/api/now",{method:"POST",headers:{"Content-Type":"application/json"},
    body:JSON.stringify({level:v})});
  paint(d);
}
async function setHold(){
  const d=await j(API+"/api/now",{method:"POST",headers:{"Content-Type":"application/json"},
    body:JSON.stringify({hold:true})});
  MODE="manual"; paint(d);
}
async function setAuto(){
  const d=await j(API+"/api/now",{method:"POST",headers:{"Content-Type":"application/json"},
    body:JSON.stringify({auto:true})});
  MODE="daemon"; paint(d);
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
}

async function renderCurve(cv){
  const cur=(typeof curLevel!=='undefined')?curLevel:null;
  const tb=document.querySelector('#cvtbl tbody');
  if(tb){
    tb.innerHTML=(cv.bands||[]).map(b=>{
      const act = cur!=null && Math.abs(cur-b.level)<=6 ? ' class="hi"' : '';
      const mark=cur!=null&&Math.abs(cur-b.level)<=6?'◀ 现在':'';
      return `<tr${act}><td>${b.emerg?'≥':'≤'}${b.upto}°C</td><td><b>${b.level}%</b></td>
        <td class="mono">${b.rpm}</td><td class="mono">${b.db}</td><td>${mark}</td></tr>`;
    }).join('');
  }
  const p=(cv&&cv.params)||{};
  const pn=document.getElementById('cvparams');
  if(pn) pn.innerHTML =
    `微调 ±<b>${p.TRIM??'-'}</b>（${p.GAIN??'-'}/°C，只快升慢降）· 上限 <b>${p.CAP??'-'}%</b> · `+
    `应急 <b>${p.EMERG??'-'}°C</b>→100%，回落 ${p.EMERG_REL??'-'}°C 才解除 · `+
    `死区 ${p.HYST??'-'}°C · 驻留 ${p.DWELL??'-'}s · 输出死区 ${p.DEAD??'-'} · 采样 ${p.IV??'-'}s`;

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
        '<span class="tag" style="background:#5a1d1d;color:#f85149">'+ (window.GUARD_TEMP||82) +'°C 自动回退</span>';
    } else if(cv2==="auto"){
      note.innerHTML='当前由 <b>固件曲线</b>接管（固件会按自己的温度曲线自行提速，'+
        '外部设定值可能被顶到 58~73%）。要精确控制请切 s0i3。';
    } else {
      note.innerHTML='<b>'+cv2+'</b>';
    }
  }
  drawScatter();
}

// ---- 散点图：温度 → 档位 ----
let ch3=null;
async function drawScatter(){
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
    options:{responsive:true,maintainAspectRatio:false,
      plugins:{legend:{labels:{color:'#8b949e',boxWidth:12}},
        tooltip:{callbacks:{label:c=>c.datasetIndex===1
          ?`曲线 ≤${c.parsed.x}°C → ${c.parsed.y}%`
          :`实测 ${c.parsed.x}°C → ${c.parsed.y}%`}},
      scales:{x:{title:{display:true,text:'CPU 温度 °C',color:'#8b949e'},
          ticks:{color:'#8b949e'},grid:{color:'#21262d'},min:35,max:105},
        y:{title:{display:true,text:'风扇档位 %',color:'#8b949e'},
          ticks:{color:'#8b949e'},grid:{color:'#21262d'},min:0,max:105}}}}});
}

async function renderEvents(){
  const e=await j(API+"/api/events?limit=40");
  const kind={curve:'曲线',mode:'模式',guard:'看门狗'};
  const col={curve:'#58a6ff',mode:'#d29922',guard:'#f85149'};
  document.querySelector('#ev tbody').innerHTML = e.length ? e.map(x=>
    `<tr><td class="mono">${new Date(x.ts*1000).toLocaleString('zh-CN',{hour12:false})}</td>
     <td style="color:${col[x.kind]||'#8b949e'}">${kind[x.kind]||x.kind}</td>
     <td>${x.msg}</td></tr>`).join('')
    : '<tr><td colspan=3 style="color:#8b949e">暂无事件</td></tr>';
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
  const r=await j(API+"/api/params");
  ED={params:{...r.params}, src:r.params};
  document.getElementById('ed-src').textContent=r.conf;
  renderEditor();
  document.getElementById('editor').style.display='';
  document.getElementById('editor').scrollIntoView({behavior:'smooth'});
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
    const rpm=Math.round((p[lk]||0)*120), db=((p[lk]||0)*0.5).toFixed(1);
    rows.push(`<tr>
      <td><input type="number" id="e_${tk}" value="${p[tk]}" min="-20" max="110" style="width:70px"></td>
      <td><input type="number" id="e_${lk}" value="${p[lk]}" min="0" max="120" style="width:70px"></td>
      <td class="mono">${rpm}</td><td class="mono">${db}</td></tr>`);
  }
  rows.push(`<tr style="background:#2d1214">
    <td><input type="number" id="e_EMERG" value="${p.EMERG}" min="60" max="105" style="width:70px"></td>
    <td><input type="number" id="e_E" value="${p.E}" min="0" max="120" style="width:70px"></td>
    <td class="mono">12000</td><td class="mono">50.0</td></tr>`);
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
  const o=readEditor();
  msg('保存中…','#8b949e');
  const r=await j(API+"/api/params",{method:'POST',
    headers:{"Content-Type":"application/json"},body:JSON.stringify({params:o})});
  if(r.ok){
    ED.src={...r.params};
    msg('✓ 已保存并重启守护','#3fb950');
    renderEditor();
    if(window.CURVE) renderCurve(r);
    setTimeout(()=>{document.getElementById('editor').style.display='none';},1200);
  } else {
    msg('✗ '+((r.errors||[]).join('；')),'#f85149');
  }
}

async function boot(){
  buildLv();
  const lv=await j(API+"/api/levels");
  window.FPS = lv.fps;   // 权威 _FPS 表，band 渲染的 rpmOf/dbOf 用它
  document.querySelector("#fps tbody").innerHTML=Object.entries(lv.fps).map(([k,v])=>
    `<tr><td>${k}%</td><td class="mono">${v[0]}</td><td class="mono">${v[1]}</td>
     <td class="mono">${(v[2]/1000).toFixed(2)}</td></tr>`).join("");
  MODE=(await j(API+"/api/mode")).mode;
  const pf=await j(API+"/api/profile");
  GUARD_TEMP=pf.guard_temp||82;
  window.CURVE=await j(API+"/api/curve");
  paint(await j(API+"/api/now"));
  renderCurve(window.CURVE||{params:{},bands:[]});
  renderEvents();
  refreshHist();
  setInterval(async()=>paint(await j(API+"/api/now")),8000);
  document.getElementById('conly')?.addEventListener('change',drawScatter);
  setInterval(refreshHist,45000);
  setInterval(()=>renderEvents(),30000);
  setInterval(()=>{if(window.CURVE)renderCurve(window.CURVE);},180000);
}
boot();
