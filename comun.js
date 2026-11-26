/* EcoFab Lab: datos y utilidades compartidas entre registro, panel y QR */
const BINS = {
  A:{id:"A",name:"PLA",full:"PLA",hex:"#2563C9",where:"Bajo el mesón de las impresoras FDM",operator:false,physical:true},
  B:{id:"B",name:"Resina endurecida",full:"Resina endurecida (curada)",hex:"#B07805",where:"Junto a la impresora de resina",operator:false},
  C:{id:"C",name:"Resina líquida y alcohol",full:"Resina líquida y alcohol de lavado",hex:"#B92B4B",where:"Gabinete cerrado, solo operador",operator:true},
  D:{id:"D",name:"Corte láser",full:"Residuos de cortadora láser",hex:"#7A5A30",where:"Al costado de la cortadora láser",operator:false}
};
const IDS = ["A","B","C","D"];
const MATERIALS = [
  {key:"pla",bin:"A",label:"PLA",desc:"Piezas, soportes y sobrantes de filamento"},
  {key:"cur",bin:"B",label:"Resina endurecida",desc:"Piezas o soportes ya curados con luz UV"},
  {key:"liq",bin:"C",label:"Resina líquida o alcohol",desc:"Resina sin curar o alcohol de lavado"},
  {key:"las",bin:"D",label:"Corte láser",desc:"Recortes de MDF, madera, cuero, acrílico"}
];
const LASER_SUB = ["MDF","Madera","Cuero","Acrílico","Cartón"];
const ORIGINS = {print:["Impresión fallida","Soportes","Sobrante","Prueba de calibración"],laser:["Recortes","Pieza fallida","Prueba de corte"]};
const MACHINES = {pla:["Creality FDM 1","Creality FDM 2","Creality FDM 3","Impresora multimaterial"],cur:["Creality Halot Mage 8K"],liq:["Creality Halot Mage 8K","Estación de lavado y curado"],las:["Cortadora láser"]};
const SIZES = [{k:"s",label:"Pequeño",sub:"cabe en la mano",g:30},{k:"m",label:"Mediano",sub:"una bolsa chica",g:120},{k:"l",label:"Grande",sub:"varias piezas",g:400}];

const $ = s => document.querySelector(s);
const matOf = k => MATERIALS.find(m => m.key === k);
const fmt = (n,d=1) => Number(n||0).toLocaleString("es-CL",{maximumFractionDigits:d,minimumFractionDigits:0});
const esc = s => String(s ?? "").replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;","\"":"&quot;","'":"&#39;"}[c]));
const hhmm = ts => new Date(ts).toLocaleTimeString("es-CL",{hour:"2-digit",minute:"2-digit"});
function dayTime(ts){const d=new Date(ts),t=new Date();return (d.toDateString()===t.toDateString()?"Hoy":d.toLocaleDateString("es-CL",{day:"numeric",month:"short"}))+", "+hhmm(ts)}
function ago(ts){const s=Math.max(0,Math.round((Date.now()-new Date(ts).getTime())/1000));if(s<60)return `hace ${s} s`;const m=Math.round(s/60);if(m<60)return `hace ${m} min`;const h=Math.round(m/60);return h<24?`hace ${h} h`:dayTime(ts)}
function statusOf(p){return p>=95?{k:"full",t:"Listo para retiro"}:p>=80?{k:"warn",t:"Casi lleno"}:{k:"ok",t:"Disponible"}}
let toastT;
function toast(t){const el=$("#toast");if(!el)return;el.textContent=t;el.classList.add("on");clearTimeout(toastT);toastT=setTimeout(()=>el.classList.remove("on"),4200)}
function lsGet(k){try{const r=localStorage.getItem(k);return r?JSON.parse(r):null}catch(e){return null}}
function lsSet(k,v){try{v==null?localStorage.removeItem(k):localStorage.setItem(k,JSON.stringify(v))}catch(e){}}

function crearCliente(){
  const c = window.ECOFAB_CONFIG || {};
  if(!window.supabase || !c.SUPABASE_URL || c.SUPABASE_URL.includes("TU-PROYECTO")){
    document.body.insertAdjacentHTML("afterbegin",`<p class="note danger" style="margin:16px">Falta configurar Supabase en config.js.</p>`);
    return null;
  }
  return window.supabase.createClient(c.SUPABASE_URL, c.SUPABASE_ANON_KEY);
}
