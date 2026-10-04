// Golden hashes for ScriptletTests.testInjectedCodeIsByteIdenticalToDesktop:
// the code @ghostery/adblocker (desktop's engine) injects for a sample of rules.
//
//   node scripts/adblock/scriptlet-vectors.mjs <adblocker dist/esm dir> <dir with scriptlets.json + resources.json> \
//        Freedom/FreedomTests/Fixtures/adblock-scriptlet-vectors.json
//
// e.g. ../../freedom-browser/node_modules/@ghostery/adblocker/dist/esm and the
// adblock service's out/. Rerun whenever resources.json is re-pinned.
import { readFileSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { resolve } from 'node:path';
const G = resolve(process.argv[2]) + '/';
const { default: Resources } = await import(G + 'resources.js');
const { default: CosmeticFilter } = await import(G + 'filters/cosmetic.js');
const dir = process.argv[3];
const text = readFileSync(dir + '/resources.json', 'utf8');
const res = Resources.parse(text, { checksum: 'x' });
const rules = JSON.parse(readFileSync(dir + '/scriptlets.json', 'utf8')).rules;
const sha = (s) => createHash('sha256').update(s, 'utf8').digest('hex');
// Ghostery's own getScript, fed the service's (name, args) instead of a parsed line.
const base = CosmeticFilter.parse('example.com##+js(noop)');
function ghosteryScript(name, args) {
  const f = Object.create(Object.getPrototypeOf(base));
  Object.assign(f, base);
  f.parseScript = () => ({ name, args });
  return f.getScript(res.getScriptlet.bind(res));
}
const pick = [];
const hosts = ['m.youtube.com', 'www.youtube.com', 'www.reddit.com', 't-online.de'];
for (const r of rules) {
  if (r.exception || r.parent_domains) continue;
  if (r.domains.some((d) => hosts.some((h) => h === d || h.endsWith('.' + d)))) pick.push(r);
}
// Every distinct scriptlet/surrogate name at least once, plus edge-case args.
const seen = new Set(pick.map((r) => r.kind + r.scriptlet));
for (const r of rules) {
  if (r.exception) continue;
  const k = r.kind + r.scriptlet;
  if (!seen.has(k)) { seen.add(k); pick.push(r); }
}
const tricky = rules.filter((r) => !r.exception && (r.args.length > 10 || r.args.some((a) => /[$`\\%]/.test(a))));
pick.push(...tricky.slice(0, 60));
const synthetic = [
  { kind: 'scriptlet', scriptlet: 'set-constant', args: ['a', "$&b$'c$`d$$e$1"] },
  { kind: 'scriptlet', scriptlet: 'set-constant', args: ['x\\y', '${z}', '%2C'] },
  { kind: 'scriptlet', scriptlet: 'set-constant', args: ['1','2','3','4','5','6','7','8','9','10','11'] },
];
// Real list rules are referenced by a hash of their content only, so no filter
// data lands in the repo; the test finds them in the bundled scriptlets.json.
const ruleKey = (r) => sha([r.kind, r.scriptlet, ...r.args].join('\u0000'));
const vectors = [];
for (const r of pick) {
  const script = ghosteryScript(r.scriptlet, r.args);
  if (script === undefined) continue;
  vectors.push({ rule: ruleKey(r), sha256: sha(script) });
}
const syntheticVectors = synthetic.map((r) => ({ ...r, sha256: sha(ghosteryScript(r.scriptlet, r.args)) }));
const out = { resources_sha256: createHash('sha256').update(readFileSync(dir + '/resources.json')).digest('hex'),
  generator: '@ghostery/adblocker 2.18.2 CosmeticFilter.getScript + Resources.getScriptlet',
  rule_key: 'sha256 of [kind, scriptlet, ...args] joined with U+0000',
  vectors, synthetic: syntheticVectors };
writeFileSync(process.argv[4], JSON.stringify(out, null, 1) + '\n');
console.log('vectors', vectors.length, 'from', pick.length + synthetic.length);
