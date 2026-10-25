// Run with: node --test test/gene_search_checks.js (no npm dependencies needed).
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const vm = require('node:vm');

function page() {
  const elements = new Map(), pending = new Map(), plots = [], urls = [];
  const element = id => {
    if (!elements.has(id)) elements.set(id, {
      value: '', style: {}, textContent: '', innerHTML: '', className: '', addEventListener() {},
    });
    return elements.get(id);
  };
  const response = (body, ok = true) => ({ ok, statusText: 'Request failed', json: async () => body });
  const context = vm.createContext({
    URLSearchParams, console, setTimeout, clearTimeout,
    location: { search: '?center=TEST&sample=S' },
    document: { getElementById: element, querySelectorAll: () => [], addEventListener() {} },
    window: { innerWidth: 1000 },
    history: { replaceState(_state, _title, url) { urls.push(url); } },
    Plotly: { newPlot(_element, _traces, layout) { plots.push(layout.title.text); } },
    fetch: url => {
      if (url.startsWith('/api/sample/')) return Promise.resolve(response({ mdall: { call: { gep_call: 'Ph' } } }));
      return new Promise(resolve => pending.set(url.split('/').pop(), (body, ok) => resolve(response(body, ok))));
    },
  });
  const publicDir = path.join(__dirname, '../web/public');
  vm.runInContext(fs.readFileSync(path.join(publicDir, 'common.js'), 'utf8'), context);
  const html = fs.readFileSync(path.join(publicDir, 'gene-search.html'), 'utf8');
  vm.runInContext(html.match(/<script>([\s\S]*?)<\/script>/)[1], context);
  return {
    element, pending, plots, urls,
    search(gene) {
      element('gene-input').value = gene;
      return vm.runInContext('searchGene()', context);
    },
  };
}

const expression = gene => ({
  gene_name: gene, gene_id: gene, sample_value: 4, subtypes: ['Ph'], reference: { Ph: [3, 5] },
});

test('a slower old response cannot replace the latest gene plot or URL', async () => {
  const p = page();
  const old = p.search('CRLF2'), latest = p.search('NUTM1');
  p.pending.get('NUTM1')(expression('NUTM1'));
  await latest;
  const status = p.element('status').textContent;
  p.pending.get('CRLF2')(expression('CRLF2'));
  await old;
  assert.equal(p.plots.length, 1);
  assert.match(p.plots[0], /NUTM1/);
  assert.equal(p.element('gene-input').value, 'NUTM1');
  assert.match(p.urls.at(-1), /gene=NUTM1$/);
  assert.equal(p.element('status').textContent, status);
});

test('an old failed request cannot replace the latest success status', async () => {
  const p = page();
  const old = p.search('CRLF2'), latest = p.search('NUTM1');
  p.pending.get('NUTM1')(expression('NUTM1'));
  await latest;
  p.pending.get('CRLF2')({ error: 'Old request failed' }, false);
  await old;
  assert.match(p.element('status').textContent, /Showing NUTM1/);
  assert.equal(p.element('status').className, 'status loaded');
});

test('a latest failure stays visible even if an older request later succeeds', async () => {
  const p = page();
  const old = p.search('CRLF2'), latest = p.search('NUTM1');
  p.pending.get('NUTM1')({ error: 'Latest request failed' }, false);
  await latest;
  p.pending.get('CRLF2')(expression('CRLF2'));
  await old;
  assert.equal(p.plots.length, 0);
  assert.equal(p.urls.length, 0);
  assert.equal(p.element('status').textContent, 'Latest request failed');
});

test('an empty new search invalidates the previous pending response', async () => {
  const p = page();
  const old = p.search('CRLF2');
  await p.search('');
  p.pending.get('CRLF2')(expression('CRLF2'));
  await old;
  assert.equal(p.plots.length, 0);
  assert.equal(p.element('status').textContent, 'Enter a gene name first.');
});

test('a normal search still displays a missing measurement', async () => {
  const p = page();
  const search = p.search('NUTM1');
  p.pending.get('NUTM1')({ ...expression('NUTM1'), sample_value: null });
  await search;
  assert.equal(p.plots.length, 1);
  assert.match(p.element('status').textContent, /not measured/);
  assert.equal(p.element('overall-percentile').innerHTML, '');
});
