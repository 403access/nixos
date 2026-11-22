import test from 'node:test';
import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { redactCommand, Runner } from '../src/runner.js';
import { parseJsonOutput, safeJoin, shQuote } from '../src/util.js';

const exec = promisify(execFile);

test('shQuote round-trips through a shell', async () => {
  const values = ["simple", "with space", "it's", 'a$b`c', ''];
  for (const value of values) {
    const { stdout } = await exec('sh', ['-c', `printf %s ${shQuote(value)}`]);
    assert.equal(stdout, value);
  }
});

test('safeJoin rejects escapes', () => {
  assert.equal(safeJoin('/tmp/root', 'a/b'), '/tmp/root/a/b');
  assert.throws(() => safeJoin('/tmp/root', '../etc/passwd'), /escapes/);
  assert.throws(() => safeJoin('/tmp/root', '/etc/passwd'), /escapes/);
});

test('redactCommand hides password arguments', () => {
  const line = redactCommand(['tool', '--password', 'hunter2', '--user', 'x']);
  assert.ok(!line.includes('hunter2'));
  assert.ok(line.includes('[redacted]'));
});

test('parseJsonOutput tolerates a prefix', () => {
  assert.deepEqual(parseJsonOutput('warning\n{"a":1}\n'), { a: 1 });
  assert.deepEqual(parseJsonOutput('[1,2,3]'), [1, 2, 3]);
});

test('wrapHost uses ssh with quoted remote argv', () => {
  const config = {
    host: 'nixos@example',
    strictHostKey: 'accept-new',
    sudo: true,
    dryRun: false,
  };
  const runner = new Runner(config);
  const wrapped = runner.wrapHost(['echo', 'hello world']);
  assert.equal(wrapped[0], 'ssh');
  assert.ok(wrapped.includes('nixos@example'));
  assert.ok(wrapped[wrapped.length - 1].includes("'hello world'"));
});

test('dry-run runner never spawns', async () => {
  const runner = new Runner({ host: 'nixos@example', dryRun: true, strictHostKey: 'accept-new', sudo: true });
  const result = await runner.runHost(['virsh', 'domstate', 'win11-stock']);
  assert.equal(result.ok, true);
  assert.match(result.output, /dry-run/);
});