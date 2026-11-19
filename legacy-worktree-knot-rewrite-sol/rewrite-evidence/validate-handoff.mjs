import assert from 'node:assert/strict';
import { readFile, access } from 'node:fs/promises';

const root = new URL('../', import.meta.url);
const audit = await readFile(new URL('REWRITE_AUDIT.md', root), 'utf8');
const plan = await readFile(new URL('REWRITE_PLAN.md', root), 'utf8');
const baseline = await readFile(new URL('BASELINE.md', import.meta.url), 'utf8');
const results = JSON.parse(await readFile(new URL('results.json', import.meta.url), 'utf8'));
const findingRows = [...audit.matchAll(/^\| (F\d{2}) \|/gm)].map(match => match[1]);
const testRows = [...plan.matchAll(/^\| (T\d{2}) \|(.+)$/gm)];
const expected = (prefix, count) => Array.from({ length: count }, (_, i) => prefix + String(i + 1).padStart(2, '0'));
assert.deepEqual(findingRows, expected('F', 30), 'Finding inventory changed or duplicated');
assert.deepEqual(testRows.map(match => match[1]), expected('T', 28), 'Test inventory changed or duplicated');
const covered = new Set(testRows.flatMap(match => match[2].match(/F\d{2}/g) || []));
assert.deepEqual([...covered].sort(), expected('F', 30), 'Each finding must map to a verification case');
assert.deepEqual(results.map(result => result.id), expected('R', 10), 'Missing baseline observation');
assert.deepEqual([...audit.matchAll(/^\| (R\d{2}) \|/gm)].map(match => match[1]), expected('R', 10));
for (const [name, content, base] of [
  ['audit', audit, root], ['plan', plan, root], ['baseline', baseline, new URL('./', import.meta.url)],
]) {
  assert.equal((content.match(/^```/gm) || []).length % 2, 0, `${name}: unmatched code fence`);
  assert(!content.includes('TODO'), `${name}: unresolved TODO`);
  for (const match of content.matchAll(/\[[^\]\n]+\]\(([^)\n]+)\)/g)) {
    const target = match[1];
    if (/^[a-z]+:/i.test(target) || target.startsWith('#')) continue;
    await access(new URL(target.split('#')[0], base));
  }
}
await access(new URL('Characterization.swift', import.meta.url));
await access(new URL('run-baseline.sh', import.meta.url));
console.log('Handoff structure verified: 30 findings, 28 verification cases, 10 baseline observations, local links and code fences.');
console.log('This verifies documentation structure, not implementation completion.');
