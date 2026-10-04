'use strict';
const vscode = require('vscode');
const net = require('node:net');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const { randomUUID } = require('node:crypto');
const { createNavigator } = require('./navigation');

function activate(context) {
  const zh = vscode.env.language.toLowerCase().startsWith('zh');
  const labels = { disconnected: zh ? 'Claudio：未连接' : 'Claudio: disconnected',
    connected: zh ? 'Claudio：已连接' : 'Claudio: connected',
    unsupported: zh ? 'Claudio：版本不支持' : 'Claudio: unsupported version' };
  const status = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Right, -100);
  status.text = labels.disconnected; status.tooltip = zh ? '本地会话定位' : 'Local session navigation'; status.show();
  let connection, navigator, retry, stopped = false, connecting = false;
  const update = () => navigator?.register();
  context.subscriptions.push(status, vscode.window.onDidOpenTerminal(update),
    vscode.window.onDidCloseTerminal(update), { dispose() {
      stopped = true; clearTimeout(retry); navigator?.dispose(); connection?.destroy();
    } });
  async function connect() {
    if (stopped || connecting || connection) return;
    connecting = true;
    try {
      if (process.platform !== 'darwin' || vscode.env.remoteName) return;
      const descriptorPath = path.join(os.homedir(), '.claudio', 'ide-navigation.json');
      const stat = await fs.lstat(descriptorPath);
      if (!stat.isFile() || stat.uid !== process.getuid() || (stat.mode & 0o777) !== 0o600 || stat.size > 4096) return;
      const descriptor = JSON.parse(await fs.readFile(descriptorPath, 'utf8'));
      if (descriptor.schema !== 1 || typeof descriptor.epoch !== 'string' || typeof descriptor.socketPath !== 'string') return;
      const parent = await fs.lstat(path.dirname(descriptor.socketPath));
      const socketStat = await fs.lstat(descriptor.socketPath);
      if (!parent.isDirectory() || parent.uid !== process.getuid() || (parent.mode & 0o777) !== 0o700 ||
          !socketStat.isSocket() || socketStat.uid !== process.getuid() || socketStat.ino !== descriptor.socketInode) return;
      const commands = await vscode.commands.getCommands(true);
      const supported = commands.includes('workbench.action.focusWindow');
      const instance = randomUUID().toUpperCase();
      const socket = net.createConnection(descriptor.socketPath);
      connection = socket;
      const send = value => { if (socket.writable) socket.write(JSON.stringify(value) + '\n'); };
      navigator = createNavigator(vscode, instance, descriptor.epoch, send, supported);
      let buffer = '';
      socket.on('connect', () => { status.text = labels.disconnected; update(); });
      socket.on('data', data => {
        buffer += data.toString('utf8');
        if (Buffer.byteLength(buffer) > 8192) { socket.destroy(); return; }
        let end;
        while ((end = buffer.indexOf('\n')) >= 0) {
          const line = buffer.slice(0, end); buffer = buffer.slice(end + 1);
          try {
            const message = JSON.parse(line);
            if (message.type === 'registered' && message.schema === 1 && message.epoch === descriptor.epoch && message.instance === instance) {
              status.text = message.supported === true ? labels.connected : labels.unsupported;
            } else { void navigator?.handle(message); }
          } catch { socket.destroy(); }
        }
      });
      socket.on('error', () => socket.destroy());
      socket.on('close', () => {
        navigator?.dispose(); navigator = undefined; connection = undefined;
        status.text = labels.disconnected; schedule();
      });
    } catch { /* No user paths or terminal identities in logs. */ }
    finally { connecting = false; if (!connection) schedule(); }
  }
  function schedule() { clearTimeout(retry); if (!stopped) retry = setTimeout(connect, 2000); }
  void connect();
}
module.exports = { activate };
