// Shared helpers for the results pages (styling follows ball-classifier-web).
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const qs = new URLSearchParams(location.search);

async function getJson(url) {
  const r = await fetch(url, { headers: { Accept: 'application/json' } });
  const body = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(body.error || r.statusText);
  return body;
}

function setStatus(msg, type = '') {
  const el = document.getElementById('status');
  if (!el) return;
  el.textContent = msg;
  el.className = `status ${type}`;
}

// Subtype colours: MD-ALL's own palette (MDALL:::subtypeCol), so the site matches
// MD-ALL's Shiny app and published figures. One fixed palette for every page.
const SUBTYPE_COLORS = {
  'BCL2/MYC': '#4EEE94', 'CDX2/UBTF': '#E6BEFF', 'DUX4': '#666666', 'ETV6::RUNX1': '#EEC900', 'HLF': '#87CEEB',
  'Hyperdiploid': '#3E9F32', 'iAMP21': '#8470FF', 'IKZF1 N159Y': '#CCCC33', 'KMT2A': '#1F78B5',
  'Low hypodiploid': '#1E90FF', 'MEF2D': '#66C2A6', 'NUTM1': '#000000', 'PAX5 P80R': '#FF4500',
  'PAX5::ETV6': '#808000', 'PAX5alt': '#FFA620', 'Ph': '#CD00CD', 'TCF3::PBX1': '#8B6508',
  'ZEB2/CEBP': '#D27B1C', 'ZNF384': '#A8DD00',
};
let COLORS = {};
function setSubtypes(list) {
  COLORS = {};
  (list || []).forEach(s => { COLORS[s] = SUBTYPE_COLORS[s] || '#94A3B8'; });
}
const colorOf = s => COLORS[s] || '#94A3B8';
const swatch = s => `<span class="swatch" style="background:${colorOf(s)}"></span>`;

function agreementPill(a) {
  if (a === 'concordant') return '<span class="pill ok">concordant</span>';
  if (a === 'discordant') return '<span class="pill warn">needs review</span>';
  if (a === 'unclassified') return '<span class="pill">unclassified</span>';
  return '<span class="pill">not classified</span>';
}
const callText = s => s.gep_call || (s.agreement === 'discordant' ? `${s.phenograph?.call} / ${s.svm?.call}` : '—');
const fmtDate = iso => iso ? new Date(iso).toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' }) : '—';
const fmtNum = (n, d = 2) => (n === null || n === undefined || n === '' || Number.isNaN(Number(n))) ? '—'
  : Number(n).toLocaleString(undefined, { maximumFractionDigits: d });
// "1.00 (11/11 runs)" from a method's score and MD-ALL label such as "Ph,10(0.91)|KMT2A,1(0.09)".
function scoreText(m) {
  if (!m || m.score === null || m.score === undefined) return '—';
  const parts = String(m.label || '').split('|').map(x => Number((x.match(/,(\d+)\(/) || [])[1])).filter(Number.isFinite);
  const total = parts.reduce((a, b) => a + b, 0);
  return `${Number(m.score).toFixed(2)}${total ? ` (${parts[0]}/${total} runs)` : ''}`;
}
const sampleParams = (c, s) => `center=${encodeURIComponent(c)}&sample=${encodeURIComponent(s)}`;

// Plotly styling from ball-classifier-web.
const PLOT_FONT = "'DM Mono', monospace";
function plotLayout(extra = {}) {
  return Object.assign({
    paper_bgcolor: '#ffffff', plot_bgcolor: '#f7f8fc',
    font: { family: PLOT_FONT, color: '#4a5568', size: 14 },
    margin: { l: 60, r: 20, t: 20, b: 50 },
    xaxis: { gridcolor: 'rgba(30,80,160,0.07)', zeroline: false, linecolor: 'rgba(30,80,160,0.15)', tickfont: { color: '#718096' } },
    yaxis: { gridcolor: 'rgba(30,80,160,0.07)', zeroline: false, linecolor: 'rgba(30,80,160,0.15)', tickfont: { color: '#718096' } },
    hoverlabel: { bgcolor: '#ffffff', bordercolor: 'rgba(30,80,160,0.18)', font: { family: PLOT_FONT, color: '#1a202c', size: 14 } },
    legend: { font: { size: 13 } },
  }, extra);
}
const plotConfig = { responsive: true, displaylogo: false, modeBarButtonsToRemove: ['select2d', 'lasso2d', 'autoScale2d'] };

// Footer shared by every page.
document.addEventListener('DOMContentLoaded', () => {
  const f = document.getElementById('footer');
  if (!f) return;
  f.className = 'site-footer';
  f.innerHTML = `
    <p class="footer-contact">Have questions or feature requests? Contact <strong>Venkata Yellapantula</strong>
      (<span data-contact data-user="y.venkatad" data-domain="gmail.com"><noscript>y.venkatad [at] gmail [dot] com</noscript></span>).</p>`;
  const s = document.createElement('script'); s.src = '/contact.js'; document.body.appendChild(s);
});
