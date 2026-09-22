#!/usr/bin/env python3
"""Headless, offline local report checks using an installed Playwright package."""
import collections
import copy
import datetime
import hashlib
import importlib.metadata
import json
from pathlib import Path
import sys
import tempfile
from urllib.parse import unquote, urlparse
from playwright.sync_api import sync_playwright

REPORT = Path(__file__).resolve().parents[2]
BASE = Path(tempfile.mkdtemp(prefix='macparakeet-report-browser-'))
RUN = BASE / (sys.argv[1] if len(sys.argv) > 1 else 'run-01')
RUN.mkdir(parents=True, exist_ok=False)
DATA = json.loads((REPORT / 'evidence.json').read_text())
HASHES = {name: hashlib.sha256((REPORT / name).read_bytes()).hexdigest()
          for name in ['index.html', 'evidence.json']}
RESULT = {'started_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
          'source_sha256': HASHES, 'playwright': importlib.metadata.version('playwright'),
          'page_url': (REPORT / 'index.html').as_uri(), 'assertions': [],
          'page_errors': [], 'console_errors': [], 'http_requests': [], 'screenshots': []}


def check(name, actual, expected=True):
    ok = actual == expected
    RESULT['assertions'].append({'name': name, 'passed': ok, 'actual': actual, 'expected': expected})
    print(('PASS' if ok else 'FAIL') + ': ' + name, flush=True)
    return ok


def titles(page):
    return page.locator('#check-list .check-title').all_text_contents()


def screenshot(page, name):
    page.screenshot(path=str(RUN / name), animations='disabled')
    RESULT['screenshots'].append(name)


def overflow(page):
    return page.evaluate('''() => ({width: innerWidth, documentWidth: document.documentElement.scrollWidth,
      bodyWidth: document.body.scrollWidth, offenders: [...document.querySelectorAll('body *')]
      .filter(e => e.getClientRects().length && getComputedStyle(e).visibility !== 'hidden')
      .map(e => ({tag:e.tagName, id:e.id, cls:String(e.className), x:e.getBoundingClientRect().x,
                 right:e.getBoundingClientRect().right}))
      .filter(e => e.x < -1 || e.right > innerWidth + 1).slice(0,15)})''')


def expected_titles(status='all', area='all', query=''):
    query = query.strip().lower()
    return [c['title'] for c in DATA['checks'] if (status == 'all' or c['status'] == status)
            and (area == 'all' or c['area'] == area)
            and query in ' '.join(str(c.get(k,'')) for k in ['title','area','observed','expected','phase','id']).lower()]

browser = None
try:
    with sync_playwright() as pw:
        browser = pw.chromium.launch_persistent_context(
            user_data_dir=str(RUN / 'fresh-profile'),
            executable_path='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
            headless=True, viewport={'width':1440,'height':1000},
            accept_downloads=True,
            args=['--no-first-run','--no-default-browser-check','--disable-background-networking',
                  '--disable-component-update','--disable-sync','--disable-extensions'])
        browser.set_offline(True)
        page = browser.pages[0]
        page.on('pageerror', lambda e: RESULT['page_errors'].append(str(e)))
        page.on('console', lambda m: RESULT['console_errors'].append(m.text) if m.type == 'error' else None)
        page.on('request', lambda r: RESULT['http_requests'].append(r.url) if r.url.startswith(('http:','https:')) else None)
        RESULT['browser'] = page.evaluate('navigator.userAgent')
        page.goto(RESULT['page_url'], wait_until='load')
        page.locator('#check-list .check').first.wait_for()
        (RUN/'initial-dom.html').write_text(page.content())
        check('embedded snapshot matches evidence.json', json.loads(page.locator('#evidence-data').text_content()), DATA)
        check('all check rows render', titles(page), expected_titles())
        check('coverage count', page.locator('#coverage-count').inner_text(), f"{len(DATA['checks'])} recorded checks")
        check('candidate provenance tooltip', page.locator('#candidate-sha').get_attribute('title'), DATA['release']['candidate'])
        screenshot(page, 'desktop-overview.png')

        for status in ['all','passed','failed','unverified']:
            count = len(expected_titles(status=status))
            button = page.locator(f'[data-status="{status}"]')
            check(f'{status} badge count', int(button.locator('.count').inner_text()), count)
            button.click()
            check(f'{status} filter rows', titles(page), expected_titles(status=status))
            check(f'{status} filter pressed state', button.get_attribute('aria-pressed'), 'true')
            check(f'{status} result count', page.locator('#result-count').inner_text(), f'Showing {count} of {len(DATA["checks"])} checks')

        page.locator('[data-status="all"]').click()
        for area in sorted({c['area'] for c in DATA['checks']}):
            page.locator('#area').select_option(area)
            check(f'area filter {area}', titles(page), expected_titles(area=area))
        page.locator('#area').select_option('all')
        for query in [DATA['checks'][0]['id'], 'RECOVERY', '  vocabulary  ', 'qa-no-such-check-080-unique']:
            page.locator('#search').fill(query)
            check(f'search {query!r}', titles(page), expected_titles(query=query))
        check('empty search guidance', page.locator('#check-list .empty strong').inner_text(), 'No matching checks')
        page.locator('#search').fill('')
        first_area = DATA['checks'][0]['area']
        page.locator('#area').select_option(first_area)
        page.locator('[data-status="passed"]').click()
        page.locator('#search').fill(DATA['checks'][0]['id'])
        check('combined search/status/area', titles(page), expected_titles(status='passed', area=first_area, query=DATA['checks'][0]['id']))
        page.locator('#search').fill('')
        page.locator('#area').select_option('all')
        page.locator('[data-status="all"]').click()

        first = page.locator('#check-list details.check').first
        first.locator('summary').click()
        check('details open by click', first.get_attribute('open') is not None)
        check('detail contains exact candidate', DATA['checks'][0]['candidate'] in first.inner_text())
        screenshot(page, 'desktop-detail.png')
        first.locator('summary').press('Enter')
        check('details close by keyboard', first.get_attribute('open'), None)
        for method in page.locator('.lessons details').all():
            before = method.get_attribute('open') is not None
            method.locator('summary').click()
            check('method disclosure toggles '+method.locator('summary').inner_text(), method.get_attribute('open') is not None, not before)
            method.locator('summary').click()

        local_links = page.locator('a[href]').evaluate_all('(xs)=>xs.map(a=>({label:a.textContent.trim(),href:a.href}))')
        broken=[]
        remote=[]
        for link in local_links:
            parsed=urlparse(link['href'])
            if parsed.scheme=='file' and not Path(unquote(parsed.path)).exists(): broken.append(link)
            elif parsed.scheme in ('http','https'): remote.append(link)
        RESULT['links']=local_links
        check('all rendered local links exist', broken, [])
        check('report hyperlinks are local', remote, [])
        check('gallery count', page.locator('#gallery .media-card').count(), len(DATA['media']))
        for index, item in enumerate(DATA['media']):
            card=page.locator('#gallery .media-card').nth(index)
            card.scroll_into_view_if_needed()
            if item['kind']=='image':
                img=card.locator('img')
                img.wait_for(state='visible')
                page.wait_for_function('(img)=>img.complete', arg=img.element_handle())
                check('gallery image loads '+item['id'], img.evaluate('(i)=>i.naturalWidth>0 && i.naturalHeight>0'))
                button=card.locator('button.media-open')
                check('gallery image enabled '+item['id'], button.is_enabled())
                button.click()
                check('lightbox title '+item['id'], page.locator('#lightbox-title').inner_text(), item['title'])
                check('original gallery link '+item['id'], page.locator('#lightbox-original').get_attribute('href'), item['path'])
                check('lightbox open '+item['id'], page.locator('#lightbox').get_attribute('open') is not None)
                if index % 2: page.locator('#close-lightbox').click()
                else: page.keyboard.press('Escape')
                check('lightbox closed '+item['id'], page.locator('#lightbox').get_attribute('open'), None)
        page.locator('#visuals').scroll_into_view_if_needed()
        screenshot(page, 'desktop-gallery.png')

        RESULT['overflow']=[]
        for width in [1440,768,390,320]:
            page.set_viewport_size({'width':width,'height':1000 if width>768 else 844})
            page.evaluate('scrollTo(0,0)')
            state=overflow(page)
            RESULT['overflow'].append(state)
            check(f'no page overflow at {width}px', max(state['documentWidth'],state['bodyWidth'])<=width)
            if width==390:
                screenshot(page,'mobile-overview.png')
                first=page.locator('#check-list details.check').first
                first.locator('summary').click()
                first.scroll_into_view_if_needed()
                screenshot(page,'mobile-detail.png')
                detail_state=overflow(page)
                RESULT['overflow'].append({'state':'expanded-detail',**detail_state})
                check('no page overflow with expanded mobile detail', max(detail_state['documentWidth'],detail_state['bodyWidth'])<=width)
                first.locator('summary').click()
                page.locator('#visuals').scroll_into_view_if_needed()
                screenshot(page,'mobile-gallery.png')

        page.set_viewport_size({'width':1440,'height':1000})
        page.locator('#evidence-file').set_input_files(str(REPORT/'evidence.json'))
        page.locator('#load-notice').filter(has_text='Loaded evidence.json.').wait_for()
        check('valid offline evidence reload', page.locator('#load-notice').inner_text().startswith('Loaded evidence.json.'))
        check('valid reload rows', titles(page), expected_titles())
        invalid=RUN/'invalid-evidence.json'
        invalid.write_text('{not valid json')
        page.locator('#evidence-file').set_input_files(str(invalid))
        page.locator('#load-notice').filter(has_text='Could not load evidence:').wait_for()
        check('invalid evidence displays error', page.locator('#load-notice').inner_text().startswith('Could not load evidence:'))
        check('invalid evidence preserves rows', titles(page), expected_titles())

        # Exercise the advertised saved snapshot while a filter is selected.
        page.locator('[data-status="failed"]').click()
        with page.expect_download() as event:
            page.locator('#save-html').click()
        download=event.value
        snapshot_dir=RUN/'saved-report'
        snapshot_dir.mkdir()
        for p in REPORT.iterdir():
            if p.name!='index.html': (snapshot_dir/p.name).symlink_to(p, target_is_directory=p.is_dir())
        snapshot=snapshot_dir/'index.html'
        download.save_as(str(snapshot))
        check('snapshot filename', download.suggested_filename, f'macparakeet-{DATA["release"]["target"]}-qa.html')
        saved=browser.new_page()
        saved.on('pageerror', lambda e: RESULT['page_errors'].append('saved snapshot: '+str(e)))
        saved.goto(snapshot.as_uri(),wait_until='load')
        saved.locator('#check-list').wait_for()
        selected=saved.locator('[data-status][aria-pressed="true"]').get_attribute('data-status')
        check('saved snapshot selected filter matches visible rows', titles(saved), expected_titles(status=selected))
        check('saved snapshot embeds exact loaded evidence', json.loads(saved.locator('#evidence-data').text_content()), DATA)
        screenshot(saved,'saved-snapshot.png')
        saved.close()
        check('no JavaScript exceptions',RESULT['page_errors'],[])
        check('no browser console errors',RESULT['console_errors'],[])
        check('no external page requests',RESULT['http_requests'],[])
        browser.close()
        browser=None
except Exception as exc:
    RESULT['harness_exception']=repr(exc)
    print('HARNESS EXCEPTION: '+repr(exc),flush=True)
finally:
    if browser is not None:
        try: browser.close()
        except Exception: pass
    RESULT['source_unchanged']={name:hashlib.sha256((REPORT/name).read_bytes()).hexdigest()==sha for name,sha in HASHES.items()}
    RESULT['passed']=all(x['passed'] for x in RESULT['assertions']) and 'harness_exception' not in RESULT and all(RESULT['source_unchanged'].values())
    (RUN/'results.json').write_text(json.dumps(RESULT,indent=2)+'\n')
    print(json.dumps({'passed':RESULT['passed'],'assertions':len(RESULT['assertions']),'run':str(RUN)}),flush=True)
raise SystemExit(0 if RESULT['passed'] else 1)
