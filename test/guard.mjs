import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { syncBuiltinESMExports } from 'node:module';

const root = process.env.WARMUP_TEST_ROOT, repo = process.env.WARMUP_REPO;
if (!root || !repo || process.env.HOME !== path.join(root, 'home') || !path.isAbsolute(root) || !path.isAbsolute(repo)) throw Error('Guarded tests require an isolated runner');
const lstat = fs.lstatSync.bind(fs), realpath = fs.realpathSync.bind(fs);
if (realpath(root) !== root || realpath(repo) !== repo) throw Error('Noncanonical guard root');
const inside = (base, value) => value === base || value.startsWith(base + path.sep);
function deny() { throw Error('TEST_GUARD_DENIED'); }
const fds = new Map();
function safe(value, write = false, finalLink = false) {
  if (typeof value === 'number') return fds.has(value) && (!write || fds.get(value)) ? value : deny();
  if (value instanceof URL) value = fileURLToPath(value);
  if (Buffer.isBuffer(value)) value = value.toString();
  if (typeof value !== 'string' || !path.isAbsolute(value)) return deny();
  const target = path.resolve(value), privatePath = inside(root, target), base = privatePath ? root : repo;
  if (!privatePath && (write || !inside(repo, target) || !(target.endsWith('.mjs') || inside(path.join(repo, 'test', 'fixtures'), target)))) return deny();
  let cursor = base;
  const parts = path.relative(base, target).split(path.sep).filter(Boolean);
  for (const [index, part] of parts.entries()) {
    cursor = path.join(cursor, part);
    try { if (lstat(cursor).isSymbolicLink() && !(finalLink && index === parts.length - 1)) return deny(); }
    catch (error) { if (error.message === 'TEST_GUARD_DENIED') throw error; if (error.code === 'ENOENT') break; throw error; }
  }
  return value;
}
const writes = new Set('writeFile appendFile mkdir mkdtemp rm rmdir unlink chmod chown lchmod lchown lutimes utimes truncate createWriteStream watch watchFile'.split(' '));
const pairs = new Set('rename copyFile cp link'.split(' '));
const paths = new Set('readFile writeFile appendFile stat lstat statfs access realpath readdir opendir mkdir mkdtemp rm rmdir unlink chmod chown lchmod lchown lutimes utimes truncate readlink createReadStream createWriteStream open rename copyFile cp link exists watch watchFile'.split(' '));
const descriptors = new Set('close fstat fchmod fchown fsync fdatasync read readv write writev ftruncate futimes'.split(' '));
const writeOpen = flags => typeof flags === 'number' ? Boolean(flags & (fs.constants.O_WRONLY | fs.constants.O_RDWR | fs.constants.O_CREAT | fs.constants.O_TRUNC | fs.constants.O_APPEND)) : /[wa+]/.test(String(flags ?? 'r'));
function check(name, args) {
  if (pairs.has(name)) { safe(args[0], name !== 'copyFile' && name !== 'cp'); safe(args[1], true); }
  else if (name === 'symlink') {
    const link = safe(args[1], true), target = path.resolve(path.dirname(link), args[0]);
    if (!inside(root, target)) deny();
    safe(target);
  }
  else if (name === 'unwatchFile') deny();
  else if (paths.has(name)) safe(args[0], writes.has(name) || (name === 'open' && writeOpen(args[1])), ['lstat','readlink','unlink'].includes(name));
  else if (descriptors.has(name)) safe(args[0], !['close','fstat','fsync','fdatasync','read','readv'].includes(name));
  else deny();
}
for (const key of Object.keys(fs)) {
  if (typeof fs[key] !== 'function') continue;
  const name = key.endsWith('Sync') ? key.slice(0, -4) : key, original = fs[key].bind(fs);
  fs[key] = (...args) => {
    const ancestorOf = target => { const relative = path.relative(args[0], target); return relative === '' || relative !== '..' && !relative.startsWith(`..${path.sep}`) && !path.isAbsolute(relative); };
    const ancestorLstat = key === 'lstatSync' && typeof args[0] === 'string' && path.isAbsolute(args[0]) && path.resolve(args[0]) === args[0] && (ancestorOf(root) || ancestorOf(repo));
    if (!ancestorLstat) check(name, args);
    if (key === 'open') {
      const callback = args.at(-1);
      if (typeof callback !== 'function') deny();
      args[args.length - 1] = (error, fd) => { if (!error) fds.set(fd, writeOpen(args[1])); callback(error, fd); };
    }
    if (key === 'close') {
      const fd = args[0], callback = args.at(-1);
      if (typeof callback !== 'function') deny();
      args[args.length - 1] = (...values) => { if (!values[0]) fds.delete(fd); callback(...values); };
    }
    const result = original(...args);
    if (key === 'openSync') fds.set(result, writeOpen(args[1]));
    if (key === 'closeSync') fds.delete(args[0]);
    return result;
  };
}
for (const key of Object.keys(fs.promises)) {
  if (typeof fs.promises[key] !== 'function') continue;
  const original = fs.promises[key].bind(fs.promises);
  fs.promises[key] = (...args) => {
    check(key, args);
    if (key === 'open') return original(...args).then(handle => {
      const fd = handle.fd;
      fds.set(fd, writeOpen(args[1]));
      const close = handle.close.bind(handle);
      handle.close = async () => { await close(); fds.delete(fd); };
      for (const method of ['chmod','chown','truncate','utimes','write','writev','writeFile','appendFile']) {
        if (typeof handle[method] !== 'function') continue;
        const originalMethod = handle[method].bind(handle);
        handle[method] = (...values) => { safe(fd, true); return originalMethod(...values); };
      }
      return handle;
    });
    return original(...args);
  };
}
syncBuiltinESMExports();
for (const name of ['node:http','node:https','node:http2','node:net','node:tls','node:dns','node:dgram','node:child_process','node:worker_threads','node:inspector']) {
  const object = (await import(name)).default;
  if (!object) continue;
  for (const key of Object.keys(object)) if (typeof object[key] === 'function' && !['Socket','Server'].includes(key) && Object.getOwnPropertyDescriptor(object, key)?.writable) object[key] = deny;
  if (object.promises) for (const key of Object.keys(object.promises)) if (typeof object.promises[key] === 'function') object.promises[key] = deny;
  if (object.Socket?.prototype) for (const key of ['connect','send','bind']) if (typeof object.Socket.prototype[key] === 'function') object.Socket.prototype[key] = deny;
  if (object.Server?.prototype?.listen) object.Server.prototype.listen = deny;
  if (object.Session?.prototype?.connect) object.Session.prototype.connect = deny;
  if (name === 'node:worker_threads') object.Worker = deny;
}
syncBuiltinESMExports();
globalThis.fetch = deny;
globalThis.WebSocket = deny;
process.kill = deny;
process.chdir = deny;
process.dlopen = deny;
process.binding = deny;
process._linkedBinding = deny;
process._debugProcess = deny;
process._debugEnd = deny;
process.env.NODE_OPTIONS = '';
