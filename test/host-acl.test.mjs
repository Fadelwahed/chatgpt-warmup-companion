import test from 'node:test';
import assert from 'node:assert/strict';
import { hostServices } from '../runtime.mjs';

const target = '/synthetic/target';
const root = '/synthetic/root';
const line = (mode, marker = '') => `${mode}${marker}  1 user staff 42 Nov 12 12:34 ${target}`;

function classify(output) {
  const calls = [];
  const services = hostServices(root, (file, args) => {
    calls.push([file, args]);
    if (output instanceof Error) throw output;
    return output;
  });
  const result = services.acl(target);
  assert.deepEqual(calls, [['/bin/ls', ['-lde', target]]]);
  return result;
}

for (const mode of ['-rw-------', 'drwx------']) {
  test(`accepts plain and xattr-only ${mode}`, () => {
    for (const marker of ['', '@']) assert.equal(classify(`${line(mode, marker)}\n`), true);
    assert.equal(classify(line(mode, '@')), true);
  });
  test(`rejects ACL indicators and entries for ${mode}`, () => {
    assert.equal(classify(`${line(mode, '+')}\n`), false);
    assert.equal(classify(`${line(mode, '@')}\n 0: user:someone deny read\n`), false);
    assert.equal(classify(`${line(mode, '@')}\n 0: user:someone allow read\n`), false);
    assert.equal(classify(`${line(mode)}\n 0: group:staff allow read\n`), false);
  });
}

test('rejects malformed, ambiguous, multiline output and command errors', () => {
  for (const output of [
    '', 'garbage', 'abcdefghij rest', '-rw-------@',
    '-rw-------  1 user staff invalid Nov 12 12:34 /synthetic/target',
    '-rw-------  1 user staff 42 Nov 12 /synthetic/target',
    '-rw-------?  1 user staff 42 Nov 12 12:34 /synthetic/target',
    `${line('-rw-------')}\n\n`, `${line('-rw-------')}\nextra`,
    `${line('-rw-------')}\r\n`, new Error('synthetic failure'),
  ]) assert.equal(classify(output), false);
});
