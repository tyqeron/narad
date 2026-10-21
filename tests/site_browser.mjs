// Run against a generated site; all feedback navigation is intercepted.
const {chromium} = await import(process.env.NARAD_PLAYWRIGHT_MODULE || 'playwright-core');
import assert from 'node:assert/strict';
const browser=await chromium.launch({executablePath:process.env.NARAD_CHROME || '/usr/bin/google-chrome',headless:true,args:['--no-sandbox']});
const page=await browser.newPage({viewport:{width:1440,height:1000}});
const errors=[]; page.on('pageerror',e=>errors.push(e.message));
page.on('response',r=>{if(r.url().startsWith('http://127.0.0.1:8765/') && r.status()>=400) errors.push(`${r.status()} ${r.url()}`);});
const base=process.env.NARAD_SITE_PREVIEW || 'http://127.0.0.1:8765/narad/';
await page.goto(base);
const screenshots = process.env.NARAD_SITE_SCREENSHOTS;
if (screenshots) await page.screenshot({path:screenshots+'/desktop.png',fullPage:true});
assert.equal(await page.locator('h1').count(),1);
assert.ok(await page.locator('nav a[aria-current=page]').textContent()==='Overview');
await page.goto(base+'docs/');
await page.locator('#doc-search').fill('camera');
await page.waitForFunction(()=>document.querySelectorAll('#search-results li').length>0);
assert.match(await page.locator('#search-status').textContent(),/matching document/);
await page.locator('#doc-search').fill('zzzz-no-match-123456');
await page.waitForFunction(()=>document.querySelector('#search-status').textContent.startsWith('No documents'));
await page.goto(base+'docs/prd/');
if (screenshots) await page.screenshot({path:screenshots+'/docs.png',fullPage:false});
assert.ok(await page.locator('.toc a').count()>2);
await page.goto(base+'feedback/');
await page.locator('[name=title]').fill('Synthetic website test');
await page.locator('[name=message]').fill('Generated feedback draft. No issue should be submitted.');
await page.route('https://github.com/**',async route=>route.fulfill({status:200,contentType:'text/plain',body:'Intercepted test draft'}));
await page.getByRole('button',{name:'Continue to GitHub'}).click();
await page.waitForURL('https://github.com/**');
const draft=new URL(page.url()); assert.equal(draft.pathname,'/tyqeron/narad/issues/new');
assert.match(draft.searchParams.get('title'),/Synthetic website test/);
assert.match(draft.searchParams.get('body'),/Generated feedback draft/);
console.log('PASS full-text search, no-results state and intercepted GitHub feedback draft');
for (const width of [390,360,320]) {
 await page.setViewportSize({width,height:844});
 for (const route of ['', 'docs/','docs/prd/','feedback/','donate/','collaborators/']) {
  await page.goto(base+route);
  const sizes=await page.evaluate(()=>({page:document.documentElement.scrollWidth,viewport:innerWidth}));
  assert.ok(sizes.page<=sizes.viewport,`${width}px ${route} overflows: ${JSON.stringify(sizes)}`);
  if (screenshots && width===390 && route==='') await page.screenshot({path:screenshots+'/mobile.png',fullPage:true});
 }
}
await page.goto(base);await page.getByRole('button',{name:'Toggle navigation'}).click();
assert.equal(await page.getByRole('button',{name:'Toggle navigation'}).getAttribute('aria-expanded'),'true');
await page.getByRole('navigation',{name:'Main navigation'}).getByRole('link',{name:'Collaborators'}).click();
await page.waitForURL('**/collaborators/');
assert.ok(await page.getByRole('heading',{name:'Thank you for building Narad.'}).isVisible());
assert.deepEqual(errors,[]);
console.log('PASS 320/360/390px layouts, mobile menu, collaborator page, no JavaScript errors');
await browser.close();
