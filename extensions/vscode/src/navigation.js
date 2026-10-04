'use strict';
const { performance } = require('node:perf_hooks');
const uuid = value => typeof value === 'string' && /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(value);

// No general command/URI interface. One request, one registered live terminal and one deadline.
function createNavigator(vscode, instance, epoch, send, supported, now = () => performance.now()) {
  let active;
  const terminals = new Map();
  let generation = 0;
  let disposed = false;
  async function register() {
    const revision = ++generation;
    const values = await Promise.all(vscode.window.terminals.map(async terminal => {
      try { return [await terminal.processId, terminal]; } catch { return [undefined, terminal]; }
    }));
    if (disposed || revision !== generation) return;
    terminals.clear();
    for (const [pid, terminal] of values) {
      if (Number.isInteger(pid) && pid > 1 && vscode.window.terminals.includes(terminal)) {
        if (terminals.has(pid)) terminals.set(pid, null); else terminals.set(pid, terminal);
      }
    }
    send({ type: 'register', schema: 1, epoch, instance, supported,
      shells: [...terminals.keys()].filter(pid => terminals.get(pid)).slice(0, 64) });
  }
  async function handle(message) {
    if (!message || message.epoch !== epoch || message.instance !== instance || !uuid(message.request)) return;
    if (message.type === 'cancel') { if (active?.id === message.request) active = undefined; return; }
    if (message.type !== 'navigate' || active || !supported || message.schema !== 1 ||
        !Number.isInteger(message.shell) || !Number.isInteger(message.remainingMs) ||
        message.remainingMs <= 0 || message.remainingMs > 3000) return;
    const terminal = terminals.get(message.shell);
    const request = { id: message.request, deadline: now() + message.remainingMs };
    active = request;
    const current = () => !disposed && active === request && now() < request.deadline &&
      terminals.get(message.shell) === terminal && terminal && vscode.window.terminals.includes(terminal);
    let outcome = 'unavailable';
    try {
      if (current()) {
        await vscode.commands.executeCommand('workbench.action.focusWindow');
        if (current() && vscode.window.state.focused) {
          terminal.show(false);
          // Allow the activeTerminal event to settle, without issuing another focus action.
          while (current() && vscode.window.state.focused && vscode.window.activeTerminal !== terminal) {
            await new Promise(resolve => setTimeout(resolve, 10));
          }
          if (current() && vscode.window.state.focused && vscode.window.activeTerminal === terminal) outcome = 'confirmed';
        }
      }
    } catch { /* Fixed redacted result only. */ }
    if (active === request) {
      active = undefined;
      send({ type: 'result', epoch, instance, request: request.id, shell: message.shell, outcome });
    }
  }
  return { register, handle, dispose() { disposed = true; active = undefined; terminals.clear(); ++generation; } };
}
module.exports = { createNavigator };
