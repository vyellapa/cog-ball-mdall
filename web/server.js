/**
 * COG B-ALL MD-ALL results browser (read-only).
 *
 * Serves results synced from every center into RESULTS_ROOT:
 *
 *   RESULTS_ROOT/<center>/<sample>/mdall/<sample>.mdall.json      (02-classify)
 *   RESULTS_ROOT/<center>/<sample>/mdall/<sample>.vst.tsv.gz
 *   RESULTS_ROOT/<center>/<sample>/counts/<sample>.counts_qc.json  (01-counts, optional)
 *   RESULTS_ROOT/<center>/<sample>/counts/<sample>.versions.json
 *
 * Nothing is written to RESULTS_ROOT; mount it read-only. The fixed MD-ALL
 * reference assets (UMAP, reference expression) come from REF_DIR, which the
 * image copies out of the mdall image of the same version.
 */
const express = require('express');
const fs = require('fs');
const path = require('path');
const zlib = require('zlib');
const crypto = require('crypto');

const PORT = Number(process.env.PORT || 3000);
const RESULTS_ROOT = path.resolve(process.env.RESULTS_ROOT || '/data/results');
const REF_DIR = path.resolve(process.env.REF_DIR || '/opt/cog-ball/ref');
const RESCAN_SECONDS = Number(process.env.RESCAN_SECONDS || 60);
const APP_PASSWORD = process.env.APP_PASSWORD || '';
const APP_USER = process.env.APP_USER || 'admin';
const VERSION = process.env.COG_BALL_VERSION || 'dev';

const ID_RE = /^[A-Za-z0-9][A-Za-z0-9._-]*$/;
const DOWNLOADABLE = {
  mdall: ['.mdall.json', '.mdall.tsv', '.predictions.tsv', '.vst.tsv.gz', '.mdall.log'],
  counts: ['.htseq.dux4patched.tsv', '.htseq.tsv', '.counts_qc.json', '.versions.json', '.star.Log.final.out',
           '.rnaseqc.metrics.tsv', '.genebody.tsv'],
};

const app = express();
app.disable('x-powered-by');
app.set('trust proxy', 1);

// ── Reference assets ─────────────────────────────────────────────────────────
function readTsv(file) {
  const [header, ...lines] = fs.readFileSync(file, 'utf8').trim().split(/\r?\n/);
  const cols = header.split('\t');
  return lines.map(l => Object.fromEntries(l.split('\t').map((v, i) => [cols[i], v])));
}

const ref = (() => {
  const meta = JSON.parse(fs.readFileSync(path.join(REF_DIR, 'ref_meta.json'), 'utf8'));
  const samples = readTsv(path.join(REF_DIR, 'ref_samples.tsv')).map(r => ({
    id: r.sample_id, subtype: r.subtype, detail: r.subtype_detail,
    x: Number(r.umap_1), y: Number(r.umap_2),
  }));
  const genes = readTsv(path.join(REF_DIR, 'ref_genes.tsv'));
  const byId = new Map(), bySymbol = new Map();
  for (const g of genes) {
    const row = Number(g.row);
    byId.set(g.gene_id.toUpperCase(), row);
    if (g.gene_name && !bySymbol.has(g.gene_name.toUpperCase())) bySymbol.set(g.gene_name.toUpperCase(), row);
  }
  let colors = {};
  try { colors = JSON.parse(fs.readFileSync(path.join(REF_DIR, 'subtype_colors.json'), 'utf8')); } catch {}
  const fd = fs.openSync(path.join(REF_DIR, 'ref_vst.f32'), 'r');
  const subtypes = [...new Set(samples.map(r => r.subtype))].sort();
  return { meta, samples, genes, byId, bySymbol, colors, fd, subtypes };
})();

function refRow(row) {
  const n = ref.meta.n_samples;
  const buf = Buffer.alloc(n * 4);
  fs.readSync(ref.fd, buf, 0, buf.length, row * n * 4);
  const out = new Array(n);
  for (let i = 0; i < n; i++) out[i] = Math.round(buf.readFloatLE(i * 4) * 1000) / 1000;
  return out;
}

// ── Results index ────────────────────────────────────────────────────────────
let index = { samples: [], byKey: new Map(), scannedAt: null, errors: [] };
const jsonCache = new Map(); // path -> { mtimeMs, data }

function readJsonCached(file) {
  let st;
  try { st = fs.statSync(file); } catch { return null; }
  const hit = jsonCache.get(file);
  if (hit && hit.mtimeMs === st.mtimeMs) return hit.data;
  const data = JSON.parse(fs.readFileSync(file, 'utf8'));
  jsonCache.set(file, { mtimeMs: st.mtimeMs, data });
  return data;
}

const listDirs = dir => {
  try {
    return fs.readdirSync(dir, { withFileTypes: true })
      .filter(e => e.isDirectory() && ID_RE.test(e.name) && e.name !== 'pipeline_info')
      .map(e => e.name);
  } catch { return []; }
};

function summarise(center, sample) {
  const base = path.join(RESULTS_ROOT, center, sample);
  const md = readJsonCached(path.join(base, 'mdall', `${sample}.mdall.json`));
  const qc = readJsonCached(path.join(base, 'counts', `${sample}.counts_qc.json`));
  const ver = readJsonCached(path.join(base, 'counts', `${sample}.versions.json`));
  if (!md && !qc) return null;
  const call = md?.call || {};
  return {
    key: `${center}/${sample}`,
    center, sample,
    status: md ? 'classified' : 'counts only',
    gep_call: call.gep_call ?? null,
    agreement: call.agreement ?? null,
    phenograph: call.phenograph || null,
    svm: call.svm || null,
    feature_genes: md?.feature_genes || {},
    // Older results may hold a single gene as a plain string (jsonlite auto_unbox).
    high_expression: [].concat(md?.high_expression ?? []),
    umap: md?.umap || null,
    imputed: md?.input?.imputed ?? null,
    classified_at: md?.created_at || null,
    pipeline_version: md?.provenance?.pipeline_version || ver?.pipeline_version || null,
    unique_pct: qc?.star?.uniquely_mapped_pct ?? null,
    assigned_reads: qc?.htseq?.assigned_reads ?? null,
    exonic_rate: qc?.rnaseqc?.['Exonic Rate'] ?? null,
    rrna_rate: qc?.rnaseqc?.['rRNA Rate'] ?? null,
    mapping_rate: qc?.rnaseqc?.['Mapping Rate'] ?? null,
    median_3prime_bias: qc?.rnaseqc?.["Median 3' bias"] ?? null,
  };
}

function scan() {
  const samples = [], errors = [];
  for (const center of listDirs(RESULTS_ROOT)) {
    for (const sample of listDirs(path.join(RESULTS_ROOT, center))) {
      try {
        const s = summarise(center, sample);
        if (s) samples.push(s);
      } catch (err) {
        errors.push({ key: `${center}/${sample}`, error: err.message });
      }
    }
  }
  samples.sort((a, b) => a.center.localeCompare(b.center) || a.sample.localeCompare(b.sample));
  index = { samples, byKey: new Map(samples.map(s => [s.key, s])), scannedAt: new Date().toISOString(), errors };
  if (errors.length) console.warn(`Scan: ${errors.length} unreadable result(s)`, errors.slice(0, 5));
}

// Gene-search values for a sample's VST file, cached (small LRU). Keyed by the file's
// mtime and size as well as the sample, so a re-synced result is read afresh.
const vstCache = new Map();
function sampleVst(center, sample) {
  const file = path.join(RESULTS_ROOT, center, sample, 'mdall', `${sample}.vst.tsv.gz`);
  const st = fs.statSync(file);
  const key = `${center}/${sample}@${st.mtimeMs}:${st.size}`;
  if (vstCache.has(key)) { const v = vstCache.get(key); vstCache.delete(key); vstCache.set(key, v); return v; }
  for (const k of vstCache.keys()) if (k.startsWith(`${center}/${sample}@`)) vstCache.delete(k);
  const text = zlib.gunzipSync(fs.readFileSync(file)).toString('utf8');
  const map = new Map();
  for (const line of text.split('\n').slice(1)) {
    const [f, v] = line.split('\t');
    if (f) map.set(f, Number(v));
  }
  vstCache.set(key, map);
  if (vstCache.size > 25) vstCache.delete(vstCache.keys().next().value);
  return map;
}

// ── Auth (optional) ──────────────────────────────────────────────────────────
app.get('/healthz', (req, res) => res.json({ ok: true, version: VERSION, samples: index.samples.length }));

if (APP_PASSWORD) {
  const COOKIE = 'cogball_session';
  const token = crypto.createHmac('sha256', APP_PASSWORD).update(`cog-ball:${APP_USER}`).digest('hex');
  const eq = (a, b) => { const x = Buffer.from(String(a)), y = Buffer.from(String(b)); return x.length === y.length && crypto.timingSafeEqual(x, y); };
  const ok = (u, p) => eq(u, APP_USER) && eq(p, APP_PASSWORD);
  const cookie = req => ((req.headers.cookie || '').match(new RegExp(`(?:^|;\\s*)${COOKIE}=([^;]+)`)) || [])[1] || '';
  const page = (err = '') => `<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>Sign In</title>
<link href="https://fonts.googleapis.com/css2?family=DM+Mono:wght@400;500&family=Syne:wght@400;600;700;800&family=DM+Sans:wght@300;400;500&display=swap" rel="stylesheet">
<link rel="stylesheet" href="/app.css"></head><body class="login">
<form method="post" action="/login" class="card login-card">
<span class="topbar-title">B-ALL MD-ALL Classifier</span><div class="eyebrow">COG results portal</div>
<label>User<input type="text" name="user" autocomplete="username"></label>
<label>Password<input type="password" name="password" autofocus autocomplete="current-password"></label>
<button type="submit" class="btn btn-primary">Sign in</button>${err ? `<p class="error">${err}</p>` : ''}</form></body></html>`;
  app.get('/app.css', (req, res) => res.sendFile(path.join(__dirname, 'public', 'app.css')));
  app.get('/login', (req, res) => res.type('html').send(page()));
  app.post('/login', express.urlencoded({ extended: false }), (req, res) => {
    if (!ok(req.body.user, req.body.password)) return res.status(401).type('html').send(page('Wrong user or password.'));
    const secure = req.secure ? '; Secure' : '';
    res.set('Set-Cookie', `${COOKIE}=${token}; Path=/; HttpOnly; SameSite=Lax; Max-Age=43200${secure}`);
    res.redirect('/');
  });
  app.get('/logout', (req, res) => { res.set('Set-Cookie', `${COOKIE}=; Path=/; Max-Age=0`); res.redirect('/login'); });
  app.use((req, res, next) => {
    if (eq(cookie(req), token)) return next();
    const h = req.headers.authorization || '';
    if (h.startsWith('Basic ')) {
      const [u, ...p] = Buffer.from(h.slice(6), 'base64').toString().split(':');
      if (ok(u, p.join(':'))) return next();
    }
    if (req.method === 'GET' && (req.headers.accept || '').includes('text/html')) return res.redirect('/login');
    res.set('WWW-Authenticate', 'Basic realm="COG B-ALL"').status(401).json({ error: 'Authentication required' });
  });
}

// ── Static ───────────────────────────────────────────────────────────────────
app.use(express.static(path.join(__dirname, 'public'), { extensions: ['html'] }));
app.get('/vendor/plotly.min.js', (req, res) =>
  res.sendFile(require.resolve('plotly.js-dist-min/plotly.min.js'), { maxAge: '7d' }));

// ── API ──────────────────────────────────────────────────────────────────────
const findSample = (req, res) => {
  const { center, sample } = req.params;
  if (!ID_RE.test(center) || !ID_RE.test(sample)) { res.status(400).json({ error: 'Invalid id' }); return null; }
  const s = index.byKey.get(`${center}/${sample}`);
  if (!s) { res.status(404).json({ error: 'Sample not found' }); return null; }
  return s;
};

app.get('/api/summary', (req, res) => {
  const centers = {};
  for (const s of index.samples) {
    const c = centers[s.center] ||= { id: s.center, samples: 0, classified: 0, concordant: 0, review: 0, last_classified: null };
    c.samples++;
    if (s.status === 'classified') c.classified++;
    if (s.agreement === 'concordant') c.concordant++;
    if (s.agreement === 'discordant') c.review++;
    if (s.classified_at && (!c.last_classified || s.classified_at > c.last_classified)) c.last_classified = s.classified_at;
  }
  res.json({ version: VERSION, scanned_at: index.scannedAt, centers: Object.values(centers),
             samples: index.samples, subtypes: ref.subtypes, scan_errors: index.errors.length });
});

app.get('/api/sample/:center/:sample', (req, res) => {
  const s = findSample(req, res); if (!s) return;
  const base = path.join(RESULTS_ROOT, s.center, s.sample);
  const files = {};
  for (const [sub, exts] of Object.entries(DOWNLOADABLE)) {
    files[sub] = exts.map(e => `${s.sample}${e}`).filter(f => fs.existsSync(path.join(base, sub, f)));
  }
  res.json({
    summary: s,
    mdall: readJsonCached(path.join(base, 'mdall', `${s.sample}.mdall.json`)),
    qc: readJsonCached(path.join(base, 'counts', `${s.sample}.counts_qc.json`)),
    versions: readJsonCached(path.join(base, 'counts', `${s.sample}.versions.json`)),
    files, subtypes: ref.subtypes,
  });
});

app.get('/api/reference/umap', (req, res) => {
  // no-cache = revalidate via ETag, so a new image version never serves stale reference data.
  res.set('Cache-Control', 'no-cache').json({ samples: ref.samples, subtypes: ref.subtypes, meta: ref.meta.umap });
});

app.get('/api/genes', (req, res) => {
  const q = String(req.query.q || '').trim().toUpperCase();
  if (q.length < 2) return res.json([]);
  const out = [];
  for (const g of ref.genes) {
    if ((g.gene_name && g.gene_name.toUpperCase().startsWith(q)) || g.gene_id.startsWith(q)) out.push({ id: g.gene_id, name: g.gene_name });
    if (out.length >= 15) break;
  }
  res.json(out);
});

app.get('/api/gene/:center/:sample/:gene', (req, res) => {
  const s = findSample(req, res); if (!s) return;
  const q = String(req.params.gene).trim().toUpperCase();
  const row = ref.byId.get(q) ?? ref.bySymbol.get(q);
  if (row === undefined) return res.status(404).json({ error: `Gene ${req.params.gene} is not in the MD-ALL reference.` });
  const g = ref.genes[row];
  let value = null;
  try { value = sampleVst(s.center, s.sample).get(g.gene_id) ?? null; }
  catch { return res.status(404).json({ error: 'No expression file (vst.tsv.gz) for this sample.' }); }
  const vals = refRow(row);
  const groups = {};
  ref.samples.forEach((r, i) => { (groups[r.subtype] ||= []).push(vals[i]); });
  res.json({ gene_id: g.gene_id, gene_name: g.gene_name, center: s.center, sample: s.sample,
             sample_value: value, reference: groups, subtypes: ref.subtypes });
});

app.get('/api/export.tsv', (req, res) => {
  const center = req.query.center && ID_RE.test(req.query.center) ? req.query.center : null;
  const cols = ['center', 'sample', 'status', 'gep_call', 'agreement', 'phenograph_call', 'phenograph_score',
                'svm_call', 'svm_score', 'CDX2', 'CRLF2', 'NUTM1', 'high_expression',
                'unique_pct', 'assigned_reads', 'exonic_rate', 'rrna_rate', 'mapping_rate', 'median_3prime_bias',
                'pipeline_version', 'classified_at'];
  const rows = index.samples.filter(s => !center || s.center === center).map(s => [
    s.center, s.sample, s.status, s.gep_call ?? '', s.agreement ?? '', s.phenograph?.call ?? '', s.phenograph?.score ?? '',
    s.svm?.call ?? '', s.svm?.score ?? '', s.feature_genes.CDX2 ?? '', s.feature_genes.CRLF2 ?? '', s.feature_genes.NUTM1 ?? '',
    s.high_expression.join(','), s.unique_pct ?? '', s.assigned_reads ?? '',
    s.exonic_rate ?? '', s.rrna_rate ?? '', s.mapping_rate ?? '', s.median_3prime_bias ?? '',
    s.pipeline_version ?? '', s.classified_at ?? '']);
  res.type('text/tab-separated-values')
    .set('Content-Disposition', `attachment; filename="cog-ball-mdall${center ? '-' + center : ''}.tsv"`)
    .send([cols, ...rows].map(r => r.map(v => String(v).replace(/[\t\n]/g, ' ')).join('\t')).join('\n') + '\n');
});

app.get('/files/:center/:sample/:sub/:file', (req, res) => {
  const s = findSample(req, res); if (!s) return;
  const { sub, file } = req.params;
  const allowed = (DOWNLOADABLE[sub] || []).map(e => `${s.sample}${e}`);
  if (!allowed.includes(file)) return res.status(404).send('Not found');
  const full = path.join(RESULTS_ROOT, s.center, s.sample, sub, file);
  if (!fs.existsSync(full)) return res.status(404).send('Not found');
  res.download(full);
});

app.use((req, res) => res.status(404).json({ error: 'Not found' }));

scan();
setInterval(scan, RESCAN_SECONDS * 1000).unref();
app.listen(PORT, () => {
  console.log(`COG B-ALL MD-ALL results browser ${VERSION} → http://localhost:${PORT}`);
  console.log(`  results: ${RESULTS_ROOT} (${index.samples.length} samples, rescan every ${RESCAN_SECONDS}s)`);
  console.log(`  reference: ${REF_DIR} (${ref.meta.n_genes} genes x ${ref.meta.n_samples} samples)`);
  console.log(`  auth: ${APP_PASSWORD ? `login required (user "${APP_USER}")` : 'NONE — put this behind your institution\'s login'}`);
});
