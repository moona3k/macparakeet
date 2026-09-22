const status = document.getElementById('status');
for (const type of ['connect', 'disconnect']) {
  document.getElementById(type).addEventListener('click', async () => {
    try {
      const result = await chrome.runtime.sendMessage({type});
      status.textContent = result?.ok ? (type === 'connect' ? 'Tab connected.' : 'Disconnected.') : (result?.error || 'Connection failed.');
    } catch { status.textContent = 'Open MacParakeet and complete browser setup first.'; }
  });
}
