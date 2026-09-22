const {chromium} = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const assert = require('node:assert/strict');
const path = require('node:path');
const http = require('node:http');
(async () => {
  const server = http.createServer((_request,response) => response.end('<html><body></body></html>'));
  await new Promise(resolve => server.listen(0,'127.0.0.1',resolve));
  const browser = await chromium.launch({headless:true, channel:process.env.PLAYWRIGHT_CHANNEL || "chrome"});
  try {
    const page = await browser.newPage();
    await page.goto('http://127.0.0.1:'+server.address().port);
    await page.setContent(`<label>Name <input id="name" value="Before"></label>
      <label>Card <input id="card" autocomplete="cc-number" value="PAYMENT_NEVER_TRANSPORT"></label>
      <label>Password <input id="password" type="password" value="NEVER_TRANSPORT"></label>
      <label>Trip <select id="trip"><option>Round trip</option><option>One way</option></select></label>
      <button id="send">Send</button><div style="height:2000px">Visible evidence</div>`);
    await page.evaluate(() => {
      globalThis.chrome = {runtime:{id:'test-extension',onMessage:{addListener(fn){globalThis.receive=fn;}}}};
      globalThis.request = object => new Promise(resolve => receive(object,{id:'test-extension'},resolve));
    });
    await page.addScriptTag({path:path.join(__dirname,'../extension/content.js')});
    await page.evaluate(() => request({type:'bind',contextID:'context',documentID:'document'}));
    const request = (type,payload) => page.evaluate(({type,payload}) => globalThis.request({type,payload,
      contextID:'context',documentID:'document',expiresAt:Date.now()+2000}),{type,payload});
    let observed = await request('observe');
    assert.equal(observed.ok,true);
    assert(!JSON.stringify(observed).includes('NEVER_TRANSPORT'));
    assert(!observed.payload.targets.some(t => t.label === 'Card'));
    assert(!observed.payload.targets.some(t => t.label.includes('Password')));
    const name = observed.payload.targets.find(t => t.label === 'Name');
    assert(name);
    let result = await request('execute',{snapshotID:observed.payload.id,action:{operation:'setValue',targetID:name.id,value:'After'}});
    assert.equal(result.payload.status,'verified');
    assert.equal(await page.locator('#name').inputValue(),'After');
    assert.equal((await request('execute',{snapshotID:observed.payload.id,action:{operation:'setValue',targetID:name.id,value:'Replay'}})).ok,false);
    observed = await request('observe');
    await page.locator('#name').fill('User changed this');
    result = await request('execute',{snapshotID:observed.payload.id,action:{operation:'setValue',targetID:name.id,value:'Stale'}});
    assert.equal(result.ok,false);
    assert.equal(await page.locator('#name').inputValue(),'User changed this');
    observed = await request('observe');
    const option = observed.payload.targets.find(t => t.label.endsWith('→ One way'));
    result = await request('execute',{snapshotID:observed.payload.id,action:{operation:'select',targetID:option.id}});
    assert.equal(result.payload.status,'verified');
    assert.equal(await page.locator('#trip').inputValue(),'One way');
    await page.locator('#send').evaluate(node => node.onclick = () => {
      const menu = document.createElement('button'); menu.textContent = 'Dynamic next option'; document.body.prepend(menu);
      node.setAttribute('aria-expanded','true');
    });
    observed = await request('observe');
    result = await request('execute',{snapshotID:observed.payload.id,action:{operation:'press',targetID:observed.payload.targets.find(t => t.label === 'Send').id}});
    assert.equal(result.payload.status,'transitionObserved');
    observed = await request('observe');
    assert(observed.payload.targets.some(t => t.label === 'Dynamic next option'));
    await page.locator('#name').evaluate(node => {node.value='x'.repeat(2100);node.focus();node.select();});
    observed = await request('observe');
    const longField = observed.payload.targets.find(t => t.label === 'Name');
    assert.equal(longField.valueIsComplete,false);
    assert.equal(longField.selectedText,null);
    await page.locator('#password').evaluate(node => Object.defineProperty(node,'value',{get(){throw Error('Secure value read');}}));
    observed = await request('observe');
    assert.equal(observed.ok,true);
    await page.locator('#send').evaluate(node => node.remove());
    result = await request('execute',{snapshotID:observed.payload.id,action:{operation:'press',targetID:observed.payload.targets.find(t => t.label === 'Send').id}});
    assert.equal(result.ok,false);
    observed = await request('observe');
    await page.locator('#name').evaluate(node => {
      const r=node.getBoundingClientRect(); const cover=document.createElement('div');
      Object.assign(cover.style,{position:'fixed',left:r.left+'px',top:r.top+'px',width:r.width+'px',height:r.height+'px',zIndex:9999,background:'red'});
      document.body.append(cover);
    });
    result = await request('execute',{snapshotID:observed.payload.id,action:{operation:'setValue',targetID:name.id,value:'Covered'}});
    assert.equal(result.ok,false);
    const expired = await page.evaluate(() => request({type:'observe',contextID:'context',documentID:'document',expiresAt:0}));
    assert.equal(expired.ok,false);
    const wrongDocument = await page.evaluate(() => request({type:'observe',contextID:'context',documentID:'wrong',expiresAt:Date.now()+1000}));
    assert.equal(wrongDocument.ok,false);
    await page.evaluate(() => window.scrollTo(0,600));
    observed = await request('observe');
    result = await request('execute',{snapshotID:observed.payload.id,action:{operation:'scroll',targetID:'scroll:down',value:'up'}});
    assert.equal(result.payload.status,'verified');
    assert(await page.evaluate(() => scrollY) < 600);
    console.log('PASS: secure values, exact fill, consume-once, stale value, select, removed target, occlusion, expiry, document identity, dynamic transition, long selection omission, secure getter exclusion, payment exclusion, scroll argument direction');
  } finally { await browser.close(); server.close(); }
})().catch(error => { console.error(error); process.exitCode=1; });
