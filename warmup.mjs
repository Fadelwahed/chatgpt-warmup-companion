import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { runCommand, hostServices } from './runtime.mjs';

export const engineVersion = '1.2.5-offline';
const scriptPath = fileURLToPath(import.meta.url);
const MAX_OUTPUT = 1024 * 1024;
const commands = ['setup', 'list', 'enroll', 'maintain', 'run', 'tick', 'status', 'history', 'timing', 'schedule', 'remove'];
const ENGINE_MODULES = ['chatgpt-probe.mjs', 'router-reader.mjs', 'runtime.mjs', 'warmup.mjs'];
let engineBuildValue;
// SHA-256 over the engine module names and bytes, in a fixed order. The native app binds to
// this value, so any replaced module disables its controls until an explicit rebind.
function engineBuild() {
  if (engineBuildValue !== undefined) return engineBuildValue;
  try {
    const digest = createHash('sha256');
    for (const name of ENGINE_MODULES) {
      const bytes = fs.readFileSync(path.join(path.dirname(scriptPath), name));
      digest.update(`${name}\0${bytes.length}\0`).update(bytes);
    }
    engineBuildValue = `sha256:${digest.digest('hex')}`;
  } catch { engineBuildValue = null; }
  return engineBuildValue;
}
const invalid = (value = 'unknown') => {
  const command = commands.includes(value) ? value : 'unknown';
  return { exitCode: 2, json: { protocolVersion: 1, engineVersion, command, outcome: 'blocked', reason: 'invalid_invocation', installationId: null, observedAt: new Date().toISOString(), ...(command === 'run' ? { selected: 0, attempted: 0, results: [] } : {}) } };
};

// One shape for a schedule edit, shared by the mutation and by read-only `schedule inspect`.
function parseEdit(action, input, allowPreview) {
  const args = [...input];
  const preview = allowPreview && args.at(-1) === '--preview';
  if (preview) args.pop();
  if (action === 'weekdays') {
    if (args.length !== 1) return null;
    const days = args[0] === 'all' ? [1, 2, 3, 4, 5, 6, 7] : /^[1-7](?:,[1-7]){0,6}$/.test(args[0]) ? args[0].split(',').map(Number) : null;
    if (!days || new Set(days).size !== days.length) return null;
    return { action, days: days.sort((a, b) => a - b), today: false, preview };
  }
  if (!['add', 'remove', 'move'].includes(action)) return null;
  const today = args.at(-1) === '--today';
  if (today) args.pop();
  if (args.length !== (action === 'move' ? 2 : 1) || args.some(arg => !/^\d\d:\d\d$/.test(arg))) return null;
  return { action, time: args[0], target: args[1], today, preview };
}

function parseCommand(argv) {
  const [first, ...rest] = argv;
  if (!commands.includes(first)) return null;
  if (first === 'schedule') {
    const [action, ...args] = rest;
    if (action === 'enable') return args.length ? null : { name: first, action };
    if (action === 'disable') {
      const now = args.length === 1 && args[0] === '--now';
      return !args.length || now ? { name: first, action, now } : null;
    }
    if (action === 'inspect') {
      if (!args.length) return { name: first, action };
      if (args.length === 2 && args[0] === '--slot') return /^\d{4}-\d\d-\d\dT\d\d:\d\d$/.test(args[1]) ? { name: first, action, slot: args[1] } : null;
      const proposal = parseEdit(args[0], args.slice(1), false);
      return proposal ? { name: first, action, proposal } : null;
    }
    if (action === 'exclude' || action === 'include') {
      return args.length === 2 && args.every(arg => /^\d{4}-\d\d-\d\d$/.test(arg)) ? { name: first, action, start: args[0], end: args[1] } : null;
    }
    if (action === 'accounts') {
      if (args.length === 1 && args[0] === 'all') return { name: first, action, all: true };
      if (args.length === 2 && ['--add', '--remove'].includes(args[0]) && /^[A-Za-z0-9_-]{1,100}$/.test(args[1])) {
        return { name: first, action, all: false, [args[0].slice(2)]: args[1] };
      }
      if (args[0] !== '--only' || args.length > 1001 || args.slice(1).some(id => !/^[A-Za-z0-9_-]{1,100}$/.test(id))) return null;
      return { name: first, action, all: false, only: args.slice(1) };
    }
    if (action === 'undo') return args.length ? null : { name: first, action };
    if (action === 'cap') {
      if (args.length !== 2 || !/^[A-Za-z0-9_-]{1,100}$/.test(args[0]) || !(args[1] === 'off' || /^[1-9]\d{0,1}$/.test(args[1]))) return null;
      return { name: first, action, account: args[0], count: args[1] === 'off' ? null : Number(args[1]) };
    }
    const edit = parseEdit(action, args, true);
    return edit ? { name: first, ...edit } : null;
  }
  if (first === 'history') {
    const options = {};
    for (let i = 0; i < rest.length; i += 2) {
      const key = rest[i], value = rest[i + 1];
      if (key === '--account' && /^[A-Za-z0-9_-]{1,100}$/.test(value ?? '') && !options.account) options.account = value;
      else if (key === '--since' && typeof value === 'string' && /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{3})?Z$/.test(value) &&
        Number.isFinite(Date.parse(value)) && new Date(value).toISOString().replace(/\.000Z$/, 'Z') === value.replace(/\.000Z$/, 'Z') && !options.since) options.since = value;
      else return null;
    }
    return { name: first, ...options };
  }
  const allowSlotOverlap = first === 'run' && rest.includes('--allow-slot-overlap');
  if (allowSlotOverlap) rest.splice(rest.indexOf('--allow-slot-overlap'), 1);
  if (rest.includes('--allow-slot-overlap')) return null;
  // `--overlap-at EPOCH_MS` scopes the override to one admission instant; it needs the override.
  // parse() has already checked that the value directly follows the flag in the original argv.
  let overlapAt;
  const atIndex = rest.indexOf('--overlap-at');
  if (atIndex >= 0) {
    overlapAt = Number(rest[atIndex + 1]);
    if (!allowSlotOverlap || !validOverlapAt(rest[atIndex + 1])) return null;
    rest.splice(atIndex, 2);
    if (rest.includes('--overlap-at')) return null;
  }
  const overlap = overlapAt === undefined ? { allowSlotOverlap } : { allowSlotOverlap, overlapAt };
  if (['enroll', 'run', 'timing'].includes(first)) {
    if (!rest.length && first !== 'enroll') return { name: first, ...overlap };
    if (rest.length !== 2 || rest[0] !== '--account' || !/^[A-Za-z0-9_-]{1,100}$/.test(rest[1])) return null;
    return { name: first, account: rest[1], ...overlap };
  }
  if (first === 'maintain') return rest.length === 2 && rest[0] === '--file' && path.isAbsolute(rest[1]) ? { name: first, file: rest[1] } : null;
  return rest.length ? null : { name: first };
}

// Usage evidence is optional: when a status reply would pass the output limit, it is dropped
// (and said so) before the reply itself has to be refused.
export function fitStatusOutput(json, limit = MAX_OUTPUT) {
  if (json.command !== 'status' || !Array.isArray(json.accounts) || Buffer.byteLength(JSON.stringify(json)) <= limit) return json;
  json.accounts = json.accounts.map(account => ({ ...account, usage: null }));
  // The last batch's per-account results carry the same evidence.
  if (Array.isArray(json.lastSlotOutcome?.results)) {
    json.lastSlotOutcome = { ...json.lastSlotOutcome, results: json.lastSlotOutcome.results.map(({ usage: _usage, ...row }) => row) };
  }
  json.usageTruncated = true;
  return json;
}

const validOverlapAt = value => typeof value === 'string' && /^[1-9]\d{11,14}$/.test(value) && Number.isSafeInteger(Number(value));

function parse(argv) {
  const args = [...argv];
  // The override's instant must sit right after its flag, before any guard pair is removed.
  const overlapAt = argv.indexOf('--overlap-at');
  if (overlapAt >= 0 && !validOverlapAt(argv[overlapAt + 1])) return null;
  const guards = {};
  for (const [flag, key, pattern] of [
    ['--expected-installation-id', 'expectedInstallationId', /^[a-zA-Z0-9_-]{12,100}$/],
    ['--expected-revision', 'expectedRevision', /^(?:0|[1-9]\d{0,15})$/],
    ['--expected-local-date', 'expectedLocalDate', /^\d{4}-\d\d-\d\d$/],
  ]) {
    const index = args.indexOf(flag);
    if (index < 0) continue;
    if (index === 0 || !pattern.test(args[index + 1] ?? '') || args.lastIndexOf(flag) !== index) return null;
    const [, value] = args.splice(index, 2);
    guards[key] = key === 'expectedRevision' ? Number(value) : value;
  }
  const command = parseCommand(args);
  if (!command || (guards.expectedRevision !== undefined &&
    (command.name !== 'schedule' || command.action === 'inspect' || !Number.isSafeInteger(guards.expectedRevision)))) return null;
  if (guards.expectedLocalDate !== undefined && (command.name !== 'schedule' || !['add', 'remove', 'move', 'weekdays', 'exclude', 'include', 'undo'].includes(command.action))) return null;
  return { ...command, ...guards };
}

export async function execute(argv, services) {
  const command = parse(argv);
  if (!command) return invalid(argv[0]);
  const observedAt = new Date(services?.clock?.wall?.() ?? Date.now()).toISOString();
  let result;
  try {
    const context = services?.context;
    if (!context || !path.isAbsolute(context.root) || !path.isAbsolute(context.nodePath) || context.scriptPath !== scriptPath) throw new Error('invalid_context');
    result = await runCommand(command, context, services);
  } catch { result = { exitCode: 2, outcome: 'blocked', reason: 'invalid_context' }; }
  const json = { protocolVersion: 1, engineVersion, command: command.name, outcome: result.outcome, reason: result.reason, installationId: result.installationId ?? null, observedAt, ...Object.fromEntries(Object.entries(result).filter(([key]) => !['exitCode', 'outcome', 'reason', 'installationId'].includes(key))) };
  if (command.name === 'status' && result.outcome === 'ready') json.engineBuild = engineBuild();
  if (command.name === 'run') {
    json.selected ??= 0;
    json.attempted ??= 0;
    json.results ??= [];
  }
  fitStatusOutput(json);
  if (Buffer.byteLength(JSON.stringify(json)) > MAX_OUTPUT) return { exitCode: 2, json: { protocolVersion: 1, engineVersion, command: command.name, outcome: 'blocked', reason: 'output_capacity', installationId: result.installationId ?? null, observedAt, ...(command.name === 'run' ? { selected: result.selected ?? 0, attempted: result.attempted ?? 0, results: result.results ?? [] } : {}) } };
  return { exitCode: result.exitCode, json };
}

if (process.argv[1] && path.resolve(process.argv[1]) === scriptPath) {
  let output;
  try { output = await execute(process.argv.slice(2), hostServices(path.dirname(scriptPath))); }
  catch { output = { exitCode: 2, json: { protocolVersion: 1, engineVersion, command: commands.includes(process.argv[2]) ? process.argv[2] : 'unknown', outcome: 'blocked', reason: 'host_capabilities_unavailable', installationId: null, observedAt: new Date().toISOString() } }; }
  process.stdout.write(`${JSON.stringify(output.json)}\n`);
  process.exitCode = output.exitCode;
}
