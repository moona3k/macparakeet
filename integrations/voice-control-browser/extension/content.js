(() => {
  if (globalThis.__macParakeetVoiceControlInstalled) return;
  globalThis.__macParakeetVoiceControlInstalled = true;
  let contextID = null, documentID = null, snapshot = null, nextID = 0;
  const nodeIDs = new WeakMap();
  const idFor = node => { if (!nodeIDs.has(node)) nodeIDs.set(node, String(++nextID)); return nodeIDs.get(node); };
  const excluded = element => element.matches('input[type=password],input[type=hidden],input[type=file]') ||
    element.closest('[data-private],[data-sensitive],[autocomplete="current-password"],[autocomplete="new-password"],[autocomplete="one-time-code"],[autocomplete^="cc-" i],[autocomplete*=" cc-" i]');
  const visible = element => !element.closest('[hidden],[inert],[aria-hidden=true]') &&
    element.checkVisibility({checkOpacity:true,checkVisibilityCSS:true}) && element.getClientRects().length > 0;
  const enabled = element => !element.matches(':disabled') && !element.closest('[aria-disabled=true]');
  const labelText = label => { const copy = label.cloneNode(true); for (const control of copy.querySelectorAll('input,textarea,select,button')) control.remove(); return copy.textContent; };
  const name = element => {
    const labelled = (element.getAttribute('aria-labelledby') || '').split(/\s+/)
      .map(id => element.getRootNode().getElementById?.(id)?.textContent || '').join(' ').trim();
    return (labelled || element.getAttribute('aria-label') || [...(element.labels || [])].map(labelText).join(' ') ||
      element.getAttribute('alt') || element.getAttribute('title') || element.getAttribute('placeholder') ||
      (element.matches('input,textarea') ? '' : element.textContent) || element.tagName.toLowerCase()).trim().slice(0,240);
  };
  const value = (element, full = false) => {
    if (excluded(element)) return null; // Never read a secure value.
    if (element.matches('input[type=checkbox],input[type=radio]')) return String(element.checked);
    if ('value' in element) return full ? String(element.value) : String(element.value).slice(0,2000);
    if (element.isContentEditable) return full ? element.textContent : element.textContent.slice(0,2000);
    return null;
  };
  const fingerprint = element => JSON.stringify([element.tagName,element.getAttribute('role'),name(element),value(element,true),
    element.getAttribute('href'),enabled(element),element.readOnly === true,element.getAttribute('aria-expanded'),element.getAttribute('aria-selected'),element.selectionStart,element.selectionEnd]);
  const selector = 'a[href],button,input,textarea,select,summary,[contenteditable=true],[role=button],[role=tab],[role=menuitem],[role=option],[role=checkbox],[role=radio],[role=switch],[role=combobox]';
  const allControls = () => {
    const result = []; const roots = [document]; let scanned = 0;
    while (roots.length && scanned < 6000) {
      const walker = document.createTreeWalker(roots.shift(),NodeFilter.SHOW_ELEMENT);
      while (scanned < 6000 && walker.nextNode()) {
        const element = walker.currentNode; scanned++;
        if (element.matches(selector)) result.push(element);
        if (element.shadowRoot) roots.push(element.shadowRoot);
      }
    }
    return {result, limited: scanned >= 6000 || roots.length > 0};
  };
  const hitTarget = element => {
    const r = element.getBoundingClientRect();
    const x = Math.max(0,r.left) + (Math.min(innerWidth,r.right)-Math.max(0,r.left))/2;
    const y = Math.max(0,r.top) + (Math.min(innerHeight,r.bottom)-Math.max(0,r.top))/2;
    if (r.width <= 0 || r.height <= 0 || x < 0 || y < 0 || x >= innerWidth || y >= innerHeight) return false;
    let hit = document.elementFromPoint(x,y);
    while (hit?.shadowRoot) { const nested = hit.shadowRoot.elementFromPoint(x,y); if (!nested || nested === hit) break; hit = nested; }
    return hit === element || element.contains(hit);
  };
  const operations = element => {
    if (element.tagName === 'SELECT') return ['select'];
    if ((element.matches('textarea,input:not([type]),input[type=text],input[type=search],input[type=email],input[type=url],input[type=tel],input[type=number]')) && !element.readOnly && element.getAttribute('aria-readonly') !== 'true') return ['setValue','insertText','press'];
    return ['press'];
  };
  function observe() {
    const {result,limited} = allControls(); const entries = new Map(); const targets = []; let editableCount = 0, omitted = false;
    for (const element of result) {
      if (targets.length >= 198) break;
      if (excluded(element) || !visible(element) || !enabled(element) || !hitTarget(element)) continue;
      const id = idFor(element), ops = operations(element);
      if (ops.includes('setValue') && ++editableCount > 24) { omitted = true; continue; }
      if (element.tagName === 'SELECT') {
        for (const option of element.options) {
          if (targets.length >= 198) break;
          if (option.disabled || option.closest('optgroup[disabled]')) continue;
          const optionID = id + ':option:' + idFor(option);
          entries.set(optionID,{element,guard:fingerprint(element),option,optionValue:option.value,operations:['select']});
          targets.push({id:optionID,label:name(element)+' → '+option.label,role:'option',value:value(element),operations:['select'],isNavigation:false,isFocused:element === document.activeElement,valueIsComplete:true,selectedText:null});
        }
      } else {
        entries.set(id,{element,guard:fingerprint(element),operations:ops});
        targets.push({id,label:name(element),role:element.getAttribute('role') || element.tagName.toLowerCase(),value:value(element),operations:ops,isNavigation:false,
          isFocused:element.getRootNode().activeElement === element,
          selectedText:typeof element.selectionStart === 'number' && element.selectionEnd - element.selectionStart <= 2000 ? element.value.slice(element.selectionStart,element.selectionEnd) : null,
          valueIsComplete:!('value' in element) || String(element.value).length <= 2000});
      }
    }
    for (const direction of ['up','down']) {
      targets.push({id:'scroll:'+direction,label:'Scroll '+direction,role:'page',value:null,operations:['scroll'],isNavigation:true,isFocused:false,valueIsComplete:true,selectedText:null});
    }
    // Read individual visible text nodes, excluding private subtrees before collecting text.
    const words = []; let length = 0, count = 0;
    const walker = document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT);
    while (count++ < 6000 && length < 4000 && walker.nextNode()) {
      const parent = walker.currentNode.parentElement;
      if (!parent || excluded(parent) || parent.closest('script,style,noscript,textarea,[contenteditable=true]') || !visible(parent)) continue;
      const text = walker.currentNode.textContent.trim();
      const rect = parent.getBoundingClientRect();
      if (rect.bottom < 0 || rect.top > innerHeight || !text) continue;
      const bounded = text.slice(0,4000-length); words.push(bounded); length += bounded.length;
    }
    const id = crypto.randomUUID();
    snapshot = {id,entries,url:location.href,scrollX,scrollY,contextID};
    return {id,contextID,applicationName:'Browser — '+document.title.slice(0,160),targets,
      summary:words.join('\n').slice(0,4000),isComplete:!limited && !omitted && count < 6000 && length < 4000 && result.length < 198 && !document.querySelector('iframe')};
  }
  const transitionState = () => JSON.stringify([
    location.href,
    [...document.querySelectorAll('[aria-expanded],[role=dialog],dialog,[role=status],[role=alert]')]
      .filter(element => !excluded(element) && visible(element))
      .slice(0,50).map(element => [idFor(element),element.getAttribute('aria-expanded'),name(element)]),
    allControls().result.filter(element => !excluded(element) && visible(element) && enabled(element) && hitTarget(element))
      .slice(0,200).map(element => [idFor(element),element.getAttribute('role'),name(element)])
  ]);
  async function execute(request) {
    const {action,snapshotID} = request.payload || {};
    if (!snapshot || snapshot.id !== String(snapshotID).toLowerCase() || snapshot.contextID !== contextID ||
        snapshot.url !== location.href || snapshot.scrollX !== scrollX || snapshot.scrollY !== scrollY) throw Error('Stale snapshot');
    const current = snapshot; snapshot = null; // Consume before the first effect; never replay.
    if (action.operation === 'scroll' && ['scroll:up','scroll:down'].includes(action.targetID)) {
      if (!['up','down'].includes(action.value)) throw Error('Unsupported scroll direction');
      const before = scrollY; window.scrollBy({top:action.value === 'up' ? -560 : 560,behavior:'instant'});
      return {status:scrollY !== before ? 'verified' : 'failed'};
    }
    const entry = current.entries.get(action.targetID), element = entry?.element;
    if (!element?.isConnected || excluded(element) || !entry.operations.includes(action.operation) ||
        !visible(element) || !enabled(element) || !hitTarget(element) || fingerprint(element) !== entry.guard) throw Error('Target changed');
    if (Date.now() > request.expiresAt) throw Error('Expired');
    if (action.operation === 'press') {
      if (element.matches('input,textarea,[contenteditable=true]')) {
        element.focus(); return {status:element.getRootNode().activeElement === element ? 'verified' : 'failed'};
      }
      const before = value(element); const beforeTransition = transitionState(); element.click();
      if (value(element) !== before) return {status:'verified'};
      for (let attempt = 0; attempt < 6; attempt++) {
        if (transitionState() !== beforeTransition) return {status:'transitionObserved'};
        await new Promise(resolve => setTimeout(resolve,60));
      }
      return {status:'unknown'};
    }
    if (action.operation === 'select') {
      if (!entry.option.isConnected || entry.option.disabled || entry.option.value !== entry.optionValue || !element.contains(entry.option)) throw Error('Option changed');
      element.value = entry.optionValue;
      element.dispatchEvent(new Event('input',{bubbles:true})); element.dispatchEvent(new Event('change',{bubbles:true}));
      return {status:element.value === entry.optionValue ? 'verified' : 'unknown'};
    }
    if (!['setValue','insertText'].includes(action.operation) || typeof action.value !== 'string' || action.value.length > 8000) throw Error('Unsupported operation');
    const before = value(element); let expected = action.value;
    if (element.isContentEditable) {
      // Preserve rich editor content rather than flattening it without a proven edit contract.
      throw Error('Rich text editing is not supported by this adapter');
    }
    element.focus();
    if (!element.isConnected || excluded(element) || !enabled(element) || element.readOnly) throw Error('Field changed while focusing');
    if (action.operation === 'insertText') {
      if (document.activeElement !== element || typeof element.selectionStart !== 'number') throw Error('No stable selection');
      expected = element.value.slice(0,element.selectionStart) + action.value + element.value.slice(element.selectionEnd);
    }
    const prototype = element.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
    const setter = Object.getOwnPropertyDescriptor(prototype,'value')?.set;
    if (!setter) throw Error('Unsupported field');
    setter.call(element,expected);
    element.dispatchEvent(new InputEvent('input',{bubbles:true,inputType:'insertText',data:action.value}));
    element.dispatchEvent(new Event('change',{bubbles:true}));
    return {status:element.value === expected ? 'verified' : element.value === before ? 'failed' : 'unknown'};
  }
  chrome.runtime.onMessage.addListener((request,sender,reply) => {
    if (sender.id !== chrome.runtime.id || sender.tab) return;
    if (request.type === 'bind') {
      contextID = request.contextID; documentID = request.documentID; snapshot = null; reply({ok:true}); return;
    }
    try {
      if (request.contextID !== contextID || request.documentID !== documentID || !Number.isFinite(request.expiresAt) || Date.now() > request.expiresAt) throw Error('Wrong context');
      if (request.type === 'execute') {
        execute(request).then(payload => reply({ok:true,payload})).catch(() => reply({ok:false,payload:{}}));
        return true;
      }
      if (request.type !== 'observe') throw Error('Unsupported command');
      reply({ok:true,payload:observe()});
    } catch { reply({ok:false,payload:{}}); }
  });
})();
