'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { createNavigator } = require('../src/navigation');
const instance = '11111111-1111-1111-1111-111111111111';
const request = '22222222-2222-2222-2222-222222222222';
function fixture({ supported = true, windowInstance = instance, shell = 55 } = {}) {
  let resolveFocus, commands = 0, shows = 0, now = 100;
  const terminal = { processId: Promise.resolve(shell), show() { shows++; vscode.window.activeTerminal = terminal; } };
  const vscode = { window: { terminals: [terminal], state: { focused: false } }, commands: {
    executeCommand(command) { assert.equal(command, 'workbench.action.focusWindow'); commands++;
      return new Promise(resolve => { resolveFocus = () => { vscode.window.state.focused = true; resolve(); }; }); } } };
  const sent = [];
  const navigator = createNavigator(vscode, windowInstance, 'epoch', value => sent.push(value), supported, () => now);
  const message = { type: 'navigate', schema: 1, epoch: 'epoch', instance: windowInstance, request, shell, remainingMs: 3000 };
  return { navigator, vscode, sent, terminal, message, focus: () => resolveFocus(),
    expire() { now += 3001; }, get commands() { return commands; }, get shows() { return shows; } };
}
test('unique shell, window focus and selected terminal confirmed', async () => {
  const f = fixture(); await f.navigator.register(); const p = f.navigator.handle(f.message);
  f.focus(); await p; assert.equal(f.shows, 1); assert.equal(f.sent.at(-1).outcome, 'confirmed');
});
test('double dispatch is single flight', async () => {
  const f = fixture(); await f.navigator.register(); const p = f.navigator.handle(f.message);
  await f.navigator.handle(f.message); assert.equal(f.commands, 1); f.focus(); await p;
});
for (const reason of ['cancel', 'expiry', 'closed', 'disconnect']) test(`${reason} before focus reply forbids late terminal selection`, async () => {
  const f = fixture(); await f.navigator.register(); const p = f.navigator.handle(f.message);
  if (reason === 'cancel') await f.navigator.handle({ ...f.message, type: 'cancel' });
  if (reason === 'expiry') f.expire();
  if (reason === 'closed') { f.vscode.window.terminals = []; await f.navigator.register(); }
  if (reason === 'disconnect') f.navigator.dispose();
  f.focus(); await p; assert.equal(f.shows, 0); assert.notEqual(f.sent.at(-1).outcome, 'confirmed');
});
test('unsupported, arbitrary instructions, wrong window and unknown PID never dispatch', async () => {
  const f = fixture(); await f.navigator.register();
  for (const message of [{ ...f.message, type: 'execute', command: 'anything' }, { ...f.message, instance: request },
    { ...f.message, shell: 99 }, { ...f.message, remainingMs: 4000 }]) await f.navigator.handle(message);
  assert.equal(f.commands, 0);
  const unsupported = fixture({ supported: false }); await unsupported.navigator.register();
  await unsupported.navigator.handle(unsupported.message); assert.equal(unsupported.commands, 0);
});
test('duplicate shell PID is ambiguous even if terminal names and cwd match', async () => {
  const f = fixture(); f.vscode.window.terminals.push({ ...f.terminal }); await f.navigator.register();
  await f.navigator.handle(f.message); assert.equal(f.commands, 0);
});

test('two windows route only the registered shell and instance', async () => {
  const a = fixture(), b = fixture({ windowInstance: '33333333-3333-3333-3333-333333333333', shell: 66 });
  await a.navigator.register(); await b.navigator.register();
  await b.navigator.handle(a.message); assert.equal(b.commands, 0);
  const p = a.navigator.handle(a.message); a.focus(); await p;
  assert.equal(a.shows, 1); assert.equal(b.shows, 0);
});
test('user switching away after focus prevents terminal selection', async () => {
  const f = fixture(); await f.navigator.register(); const p = f.navigator.handle(f.message);
  f.focus(); f.vscode.window.state.focused = false; await p;
  assert.equal(f.shows, 0); assert.equal(f.sent.at(-1).outcome, 'unavailable');
});
