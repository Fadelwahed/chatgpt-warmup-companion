import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

const reference = JSON.parse(fs.readFileSync(new URL('./fixtures/timezone-reference.json', import.meta.url), 'utf8'));
test('A03 dated independent Gaza reference covers DST gaps, repeats and all three admission hours', () => {
  const [major, minor] = process.versions.node.split('.').map(Number);
  assert.equal(major, 22); assert.ok(minor >= 19);
  assert.ok(process.versions.icu); assert.ok(process.versions.tz);
  assert.equal(reference.reference.localVersion, '2026f');
  assert.equal(reference.reference.networkUsed, false);
  const formatter = new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Gaza', hourCycle: 'h23',
    year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', second: '2-digit', timeZoneName: 'longOffset' });
  for (const fixture of reference.expected) {
    const p = Object.fromEntries(formatter.formatToParts(Date.parse(fixture.instant)).filter(p => p.type !== 'literal').map(p => [p.type, p.value]));
    const local = `${p.year}-${p.month}-${p.day}T${p.hour}:${p.minute}:${p.second}${p.timeZoneName.slice(3)}`;
    assert.equal(local, fixture.local, fixture.instant);
  }
});
