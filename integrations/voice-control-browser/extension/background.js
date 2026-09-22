// This worker is the only source of browser commands; web pages cannot address the host.
let port = null;
let authorization = null;
let sessionID = null;
let connectReply = null;
let connectionTimer = null;
const revoked = new Set();

function disconnect(reason) {
  const old = port; port = null; authorization = null; sessionID = null;
  revoked.clear(); clearTimeout(connectionTimer);
  if (connectReply) { connectReply({ok:false,error:typeof reason === 'string' ? reason : 'Open MacParakeet and complete browser setup first.'}); connectReply = null; }
  try { old?.disconnect(); } catch { /* already disconnected */ }
}
function reply(request, payload, ok = true) {
  if (port && request.sessionID === sessionID) {
    port.postMessage({type:'response',requestID:request.requestID,sessionID,ok,payload});
  }
}
async function authorizedTab(request) {
  if (!authorization || authorization.navigating || request.contextID !== authorization.contextID || request.sessionID !== sessionID ||
      !Number.isFinite(request.expiresAt) || Date.now() > request.expiresAt || revoked.has(request.requestID)) throw Error('Expired authorization');
  const tab = await chrome.tabs.get(authorization.tabId);
  const window = await chrome.windows.get(tab.windowId);
  if (!tab.active || !window.focused || tab.windowId !== authorization.windowId || tab.url !== authorization.url) throw Error('Tab changed');
  return {...authorization};
}
async function dispatch(request) {
  if (request.type === 'authorized') {
    if (!authorization || authorization.navigating || request.contextID !== authorization.contextID || typeof request.sessionID !== 'string') return disconnect();
    sessionID = request.sessionID; clearTimeout(connectionTimer);
    connectReply?.({ok:true}); connectReply = null; return;
  }
  if (request.type === 'revoke') {
    if (request.sessionID === sessionID && typeof request.requestID === 'string') {
      revoked.add(request.requestID);
      if (revoked.size > 512) disconnect();
    }
    return;
  }
  if (!['observe','execute'].includes(request.type) || typeof request.requestID !== 'string') return;
  let scope;
  try {
    scope = await authorizedTab(request);
    const result = await chrome.tabs.sendMessage(scope.tabId, {...request, documentID:scope.documentID}, {documentId:scope.documentID});
    reply(request, result.payload, result.ok === true);
  } catch {
    // Navigation can destroy the content-script reply after a dispatched click.
    // Report only the independently observed same-origin interface transition.
    if (scope && request.type === 'execute' && request.payload?.action?.operation === 'press') {
      try {
        const tab = await chrome.tabs.get(scope.tabId);
        if (authorization && tab.active && tab.windowId === scope.windowId && new URL(tab.url).origin === scope.origin &&
            (tab.url !== scope.url || authorization.documentID !== scope.documentID)) {
          return reply(request,{status:'transitionObserved'});
        }
      } catch { /* unknown, never retry */ }
    }
    reply(request, {}, false);
  }
}
chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  // Only the extension popup can change authorization. Content scripts/pages cannot.
  if (sender.id !== chrome.runtime.id || sender.url !== chrome.runtime.getURL('popup.html')) return;
  if (message.type === 'disconnect') { disconnect(); sendResponse({ok:true}); return; }
  if (message.type !== 'connect') return;
  (async () => {
    disconnect();
    const [tab] = await chrome.tabs.query({active:true,currentWindow:true});
    if (!tab?.id || !/^https?:\/\//.test(tab.url || '')) throw Error('Choose a regular HTTP or HTTPS page.');
    const injection = await chrome.scripting.executeScript({target:{tabId:tab.id},files:['content.js'],world:'ISOLATED'});
    const top = injection.find(frame => frame.frameId === 0);
    if (!top?.documentId) throw Error('This browser does not expose document identity.');
    const stored = await chrome.storage.local.get('profileInstance');
    const profileInstance = stored.profileInstance || crypto.randomUUID();
    if (!stored.profileInstance) await chrome.storage.local.set({profileInstance});
    authorization = {tabId:tab.id,windowId:tab.windowId,url:tab.url,documentID:top.documentId,
      profileInstance, origin:new URL(tab.url).origin,
      contextID:[profileInstance,tab.windowId,tab.id,top.documentId,crypto.randomUUID()].join(':')};
    const scope = authorization;
    await chrome.tabs.sendMessage(tab.id,{type:'bind',contextID:scope.contextID,documentID:scope.documentID},{documentId:scope.documentID});
    connectReply = sendResponse;
    port = chrome.runtime.connectNative('com.macparakeet.voice_control');
    const currentPort = port;
    port.onMessage.addListener(message => { if (port === currentPort) void dispatch(message); });
    port.onDisconnect.addListener(() => { const reason=chrome.runtime.lastError?.message; if (port === currentPort) disconnect(reason); });
    port.postMessage({type:'authorize',contextID:scope.contextID});
    connectionTimer = setTimeout(() => disconnect(), 5000);
  })().catch(error => { disconnect(); sendResponse({ok:false,error:error.message}); });
  return true;
});
chrome.tabs.onActivated.addListener(info => { if (authorization && info.tabId !== authorization.tabId) disconnect(); });
let navigationGeneration = 0;
chrome.tabs.onUpdated.addListener((id, change, tab) => {
  if (authorization?.tabId !== id) return;
  const scope = authorization;
  if (change.url && new URL(change.url).origin !== scope.origin) return disconnect();
  if (change.status === 'loading' || change.url) {
    navigationGeneration++;
    scope.navigating = true;
    port?.postMessage({type:'invalidate'});
  }
  if (change.status === 'complete' || (change.url && tab.status === 'complete')) {
    const generation = navigationGeneration;
    (async () => {
      const current = await chrome.tabs.get(id);
      if (new URL(current.url).origin !== scope.origin) return disconnect();
      const frames = await chrome.scripting.executeScript({target:{tabId:id},files:['content.js'],world:'ISOLATED'});
      const frame = frames.find(item => item.frameId === 0);
      if (authorization !== scope || generation !== navigationGeneration) return;
      if (!frame?.documentId) return disconnect();
      scope.documentID = frame.documentId; scope.url = current.url;
      scope.contextID = [scope.profileInstance,scope.windowId,id,frame.documentId,crypto.randomUUID()].join(':');
      await chrome.tabs.sendMessage(id,{type:'bind',contextID:scope.contextID,documentID:scope.documentID},{documentId:scope.documentID});
      if (authorization !== scope || generation !== navigationGeneration) return;
      scope.navigating = false;
      port?.postMessage({type:'authorize',contextID:scope.contextID});
    })().catch(() => disconnect());
  }
});
chrome.tabs.onRemoved.addListener(id => { if (authorization?.tabId === id) disconnect(); });
chrome.windows.onFocusChanged.addListener(id => {
  // Switching to MacParakeet's nonactivating controls is unnecessary; native app focus invalidates dispatch.
  if (authorization && id !== authorization.windowId) {
    // Keep the chosen tab identity, but authorizedTab requires foreground again before dispatch.
  }
});
