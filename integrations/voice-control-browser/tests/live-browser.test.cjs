// Explicit opt-in, synthetic local fixture only. Uses real extension/native-host/socket/Jev.
const {chromium} = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const {spawn,execFileSync} = require('node:child_process');
const assert = require('node:assert/strict');
const root = path.resolve(__dirname,'../../..');
(async () => {
  if (process.env.MACPARAKEET_BROWSER_FIXTURE_QUALIFICATION !== '1' || !process.env.JEV_API_KEY) throw Error('Explicit fixture opt-in and Jev key required');
  const harness = process.env.BROWSER_QUALIFICATION_BINARY;
  const host = process.env.BROWSER_HOST_BINARY || path.join(root,'.build/debug/macparakeet-browser-host');
  if (!harness || !fs.existsSync(harness) || !fs.existsSync(host)) throw Error('Build qualification harness and native host first');
  const pairing = path.join(os.homedir(),'Library/Application Support/MacParakeet/VoiceControlBrowser/pairing.json');
  if (fs.existsSync(pairing)) throw Error('Existing user pairing must be preserved; this fresh-pair fixture cannot run');
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(),'macparakeet-browser-proof-'));
  const profile = path.join(temporary,'profile');
  const html = fs.readFileSync(path.join(__dirname,'flight-fixture.html'));
  const server = http.createServer((_request,response) => {response.setHeader('Content-Type','text/html');response.end(html);});
  await new Promise(resolve => server.listen(0,'127.0.0.1',resolve));
  let context, child, installed = false, installedPairing, ownedSocket, fixtureVideo, fixtureVideoPath, output = '';
  try {
    const extension = path.join(temporary,'extension');
    fs.cpSync(path.join(__dirname,'../extension'),extension,{recursive:true});
    // Programmatic headless popup interaction does not confer activeTab's real user gesture.
    // Grant only the synthetic loopback fixture in this disposable test manifest.
    const manifest = JSON.parse(fs.readFileSync(path.join(extension,'manifest.json')));
    manifest.host_permissions = ['http://127.0.0.1/*'];
    fs.writeFileSync(path.join(extension,'manifest.json'),JSON.stringify(manifest));
    const options = {headless:process.env.BROWSER_HEADED !== '1',args:[`--disable-extensions-except=${extension}`,`--load-extension=${extension}`],viewport:{width:1280,height:1000},recordVideo:{dir:path.join(temporary,'video'),size:{width:1280,height:1000}}};
    if (process.env.CHROMIUM_EXECUTABLE) options.executablePath = process.env.CHROMIUM_EXECUTABLE;
    else options.channel = 'chromium';
    context = await chromium.launchPersistentContext(profile,options);
    const worker = context.serviceWorkers()[0] || await context.waitForEvent('serviceworker');
    const extensionID = new URL(worker.url()).host;
    execFileSync('python3',[path.join(__dirname,'../install.py'),'--extension-id',extensionID,'--host',host,'--browser','chrome-for-testing','--user-data-dir',profile],{stdio:'pipe'});
    installed = true; installedPairing = fs.readFileSync(pairing);
    child = spawn(harness,[],{env:process.env,stdio:['ignore','pipe','pipe']});
    child.stdout.on('data',data => {output += data; process.stdout.write(data);});
    child.stderr.on('data',() => {}); // No accidental error dumps of runtime state.
    const waitFor = async (predicate,ms) => {const end=Date.now()+ms;while(!predicate()){if(Date.now()>end)throw Error('Timed out waiting for fixture');await new Promise(resolve=>setTimeout(resolve,50));}};
    await waitFor(()=>output.includes('BRIDGE_READY'),10000);
    const socketPath = path.join(path.dirname(pairing),'bridge.sock');
    ownedSocket = fs.statSync(socketPath);
    const page = await context.newPage(); fixtureVideo = page.video();
    await page.goto('http://127.0.0.1:'+server.address().port);
    fixtureVideoPath = await fixtureVideo.path();
    const popup = await context.newPage();
    await popup.goto(`chrome-extension://${extensionID}/popup.html`);
    await page.bringToFront();
    await worker.evaluate(async () => {
      const tabs=await chrome.tabs.query({url:'http://127.0.0.1/*'});
      await chrome.tabs.update(tabs[0].id,{active:true});
      await chrome.windows.update(tabs[0].windowId,{focused:true});
    });
    await popup.evaluate(()=>document.getElementById('connect').click());
    await popup.waitForFunction(() => document.getElementById('status').textContent.length > 0,{timeout:10000});
    const connectionStatus = await popup.locator('#status').innerText();
    console.log('CONNECTION '+connectionStatus);
    assert.equal(connectionStatus,'Tab connected.');
    await waitFor(()=>output.includes('PRE_NAV_READY'),10000);
    await page.goto('http://127.0.0.1:'+server.address().port+'/same-origin-navigation');
    await waitFor(()=>output.includes('NAVIGATION_VERIFIED'),10000);
    await waitFor(()=>output.includes('RUNNER_COMPLETED') || output.includes('RUNNER_STOPPED') || output.includes('UNEXPECTED_CONFIRMATION'),80000);
    await page.screenshot({path:path.join(temporary,'final-page.png'),fullPage:true});
    fs.writeFileSync(path.join(temporary,'runtime.txt'),output);
    assert(output.includes('RUNNER_COMPLETED'),'Runner did not complete fixture');
    const result = await page.locator('#results').innerText();
    assert(result.includes('One way') && result.includes('Zürich') && result.includes('London') && result.includes('20 September'),result);
    const artifact = process.env.BROWSER_PROOF_SCREENSHOT || path.join(temporary,'browser-proof.png');
    await page.screenshot({path:artifact,fullPage:true});
    fs.writeFileSync(path.join(temporary,'evidence.json'),JSON.stringify({
      input:'typed goal',speech:false,api:'live Jev',model:'jev-1.13.0',transport:'extension-native-host-unix-socket',
      fixtureOnlyAutomaticConfirmations:true,testManifestLoopbackPermission:true,sameOriginRebind:true,staleDocumentRejected:true,
      decisionMilliseconds:[...output.matchAll(/JEV_MS (\d+)/g)].map(match=>Number(match[1])),
      goalMilliseconds:Number(output.match(/GOAL_MS (\d+)/)?.[1]),observedResult:result,screenshot:artifact
    },null,2));
    await page.waitForTimeout(2500);
    console.log('PASS real native messaging + production Swift adapter/runner + live Jev + dynamic browser goal');
    console.log('Screenshot: '+artifact);
  } finally {
    child?.kill('SIGTERM');
    await context?.close(); server.close();
    if (fixtureVideoPath && fs.existsSync(fixtureVideoPath)) {
      const videoPath = process.env.BROWSER_PROOF_VIDEO || path.join(temporary,'browser-proof.webm');
      try { fs.copyFileSync(fixtureVideoPath,videoPath); console.log('Video: '+videoPath); } catch { console.log('Video remains in fixture artifact directory.'); }
    }
    if (installed) {
      // Only this invocation's fresh pairing, never a pre-existing user file.
      if (fs.existsSync(pairing) && fs.readFileSync(pairing).equals(installedPairing)) fs.rmSync(pairing);
      const socket = path.join(path.dirname(pairing),'bridge.sock');
      if (ownedSocket && fs.existsSync(socket)) { const current=fs.statSync(socket); if (current.ino === ownedSocket.ino && current.dev === ownedSocket.dev) fs.rmSync(socket); }
    }
    // Preserve disposable profile/log artifacts for inspection; they contain synthetic data only.
    console.log('Fixture artifacts: '+temporary);
  }
})().catch(error=>{console.error(error.message);process.exitCode=1;});
