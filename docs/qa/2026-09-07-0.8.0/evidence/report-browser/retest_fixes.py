import hashlib,json,tempfile
from pathlib import Path
from playwright.sync_api import sync_playwright
root=Path(__file__).resolve().parents[2]
out=Path(tempfile.mkdtemp(prefix='macparakeet-report-browser-focused-'))/'run-02'
out.mkdir(exist_ok=False)
data=json.loads((root/'evidence.json').read_text())
result={'assertions':[],'bounds':[],'errors':[],'http_requests':[],
        'source_sha256':{f:hashlib.sha256((root/f).read_bytes()).hexdigest() for f in ['index.html','evidence.json']}}
def check(name,actual,expected=True):
 row={'name':name,'actual':actual,'expected':expected,'passed':actual==expected}
 result['assertions'].append(row)
 print(('PASS' if row['passed'] else 'FAIL')+': '+name,flush=True)
def expected(status):
 return [c['title'] for c in data['checks'] if status=='all' or c['status']==status]
def rendered(page): return page.locator('#check-list .check-title').all_text_contents()
def collect(page):
 page.on('pageerror',lambda e:result['errors'].append(str(e)))
 page.on('request',lambda r:result['http_requests'].append(r.url) if r.url.startswith(('http:','https:')) else None)
with sync_playwright() as p:
 with p.chromium.launch_persistent_context(str(out/'fresh-profile'),executable_path='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',headless=True,viewport={'width':1440,'height':1000},accept_downloads=True,args=['--no-first-run','--no-default-browser-check','--disable-background-networking','--disable-component-update','--disable-sync','--disable-extensions']) as context:
  context.set_offline(True)
  page=context.pages[0]
  collect(page)
  page.goto((root/'index.html').as_uri(),wait_until='load')
  check('fresh page renders all unchanged records',rendered(page),expected('all'))
  for width in [1440,768,390,320]:
   page.set_viewport_size({'width':width,'height':1000 if width==1440 else 844})
   page.evaluate('scrollTo(0,0)')
   bounds=page.evaluate('''()=>({width:innerWidth,documentWidth:document.documentElement.scrollWidth,
    topbar:document.querySelector('.topbar').getBoundingClientRect().toJSON(),
    meta:document.querySelector('.top-meta').getBoundingClientRect().toJSON()})''')
   result['bounds'].append(bounds)
   check(f'header metadata fits vertically at {width}px',bounds['meta']['top']>=0 and bounds['meta']['bottom']<=bounds['topbar']['bottom'])
   check(f'no horizontal overflow at {width}px',bounds['documentWidth']<=width)
   if width in [1440,390,320]: page.screenshot(path=str(out/f'overview-{width}.png'))
  page.set_viewport_size({'width':1440,'height':1000})
  page.locator('[data-status="failed"]').click()
  check('Failed still filters historical failure records',rendered(page),expected('failed'))
  page.locator('#evidence-file').set_input_files(str(root/'evidence.json'))
  page.locator('#load-notice').filter(has_text='Loaded evidence.json.').wait_for()
  check('evidence reload preserves active Failed state',page.locator('[aria-pressed="true"][data-status]').get_attribute('data-status'),'failed')
  check('evidence reload preserves Failed rows',rendered(page),expected('failed'))
  with page.expect_download() as event: page.locator('#save-html').click()
  snapshot_dir=out/'saved-report'
  snapshot_dir.mkdir()
  for item in root.iterdir():
   if item.name!='index.html': (snapshot_dir/item.name).symlink_to(item,target_is_directory=item.is_dir())
  event.value.save_as(str(snapshot_dir/'index.html'))
  saved=context.new_page()
  collect(saved)
  saved.goto((snapshot_dir/'index.html').as_uri(),wait_until='load')
  check('reopened saved snapshot starts with All selected',saved.locator('[aria-pressed="true"][data-status]').get_attribute('data-status'),'all')
  check('reopened saved snapshot shows all records',rendered(saved),expected('all'))
  check('snapshot status selection is unambiguous',saved.locator('[aria-pressed="true"][data-status]').count(),1)
  saved.evaluate("document.querySelector('#coverage').scrollIntoView({block:'start'})")
  saved.screenshot(path=str(out/'saved-snapshot-consistent.png'))
  for status in ['failed','passed','unverified','all']:
   saved.locator(f'[data-status="{status}"]').click()
   check(f'reopened snapshot {status} filter',rendered(saved),expected(status))
   check(f'reopened snapshot {status} selected state',saved.locator('[aria-pressed="true"][data-status]').get_attribute('data-status'),status)
  check('saved evidence semantic identity',json.loads(saved.locator('#evidence-data').text_content()),data)
  saved.close()
check('no JavaScript exceptions',result['errors'],[])
check('no external page requests',result['http_requests'],[])
result['source_unchanged']={f:hashlib.sha256((root/f).read_bytes()).hexdigest()==h for f,h in result['source_sha256'].items()}
result['passed']=all(row['passed'] for row in result['assertions']) and all(result['source_unchanged'].values())
(out/'results.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps({'passed':result['passed'],'assertions':len(result['assertions']),'output':str(out)}),flush=True)
raise SystemExit(0 if result['passed'] else 1)
