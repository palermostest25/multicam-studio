/* Run against an isolated Studio instance with a 90s test movie that contains
   three loud sections (4–12s, 40–50s, 76–85s), with quieter audio elsewhere.
   Requires Playwright: MULTICAM_TEST_SOURCE=/absolute/fixture.MOV
   MULTICAM_TEST_OUTPUT=/absolute/exports node tests/browser_highlights.cjs
   Optional MULTICAM_TEST_URL (default localhost:8776), MULTICAM_TEST_EVIDENCE. */
const assert = require('node:assert/strict');
const {chromium} = require('playwright');
const fs = require('node:fs');
(async()=>{
  assert(process.env.MULTICAM_TEST_SOURCE && process.env.MULTICAM_TEST_OUTPUT, 'Set the fixture and output folder environment variables');
  const browser=await chromium.launch({headless:true});
  try {
    const page=await browser.newPage({viewport:{width:1440,height:1000}});
    const errors=[],posts=[];
    page.on('pageerror',e=>errors.push(e.message));
    page.on('request',r=>{if(r.method()==='POST')posts.push(r.url());});
    await page.goto(process.env.MULTICAM_TEST_URL||'http://127.0.0.1:8776');
    await page.waitForFunction(()=>document.querySelector('#server-status')?.textContent?.includes('Ready')||!document.querySelector('#plan-button').disabled);
    await page.locator('[data-page="effects"]').click();
    const countBefore=posts.length;
    for(let cycle=0;cycle<4;cycle++)for(const style of ['none','warm','cool','mono','vintage','vivid']){
      await page.locator(`[name="colour-style"][value="${style}"]`).check();
      assert.equal(await page.locator('#effects-style').inputValue(),style);
      await page.locator('#effects-brightness').fill('0.02');
    }
    await page.locator('[name="colour-style"][value="none"]').check();
    await page.locator('[name="colour-style"][value="none"]').focus();
    await page.keyboard.press('ArrowRight');
    assert.equal(await page.locator('#effects-style').inputValue(),'warm');
    assert.equal(posts.length,countBefore,'Choosing a style must not start a job');
    await page.locator('[data-page="highlights"]').click();
    await page.locator('#highlight-source').fill(process.env.MULTICAM_TEST_SOURCE);
    await page.locator('#highlight-output').fill(process.env.MULTICAM_TEST_OUTPUT);
    await page.locator('#highlight-name').fill('browser-batch-'+Date.now());
    await page.locator('#highlight-length').fill('6');
    await page.locator('#highlight-find').click();
    await page.waitForFunction(()=>document.querySelectorAll('.energy-row').length>=4);
    const shortCount=await page.locator('.energy-row').count();
    await page.locator('#highlight-length').fill('15');
    assert(await page.locator('#export-highlights').isDisabled(),'Changed length must invalidate the old plan');
    await page.locator('#highlight-find').click();
    await page.waitForFunction(()=>document.querySelectorAll('.energy-row').length===3);
    assert(shortCount>3,'Shorter requested lengths should produce more pieces');
    await page.locator('#highlight-select-none').click();
    assert(await page.locator('#export-highlights').isDisabled());
    await page.locator('#highlight-select-all').click();
    await page.locator('.energy-row input').nth(1).uncheck();
    await page.getByRole('button',{name:'Review highlight 3',exact:true}).click();
    assert(Number(await page.locator('#highlight-wave-host input[type="number"]').first().inputValue())>65,'Late recording sections must be reviewable');
    assert.match(await page.locator('#export-highlights').textContent(),/2 selected/);
    await page.locator('#export-highlights').click();
    await page.waitForFunction(()=>document.querySelector('#highlight-result h3')?.textContent==='2 of 2 clips exported',{},{timeout:90000});
    assert.equal(await page.locator('.batch-result-row').count(),2);
    if(process.env.MULTICAM_TEST_EVIDENCE){fs.mkdirSync(process.env.MULTICAM_TEST_EVIDENCE,{recursive:true});await page.screenshot({path:process.env.MULTICAM_TEST_EVIDENCE+'/highlights-desktop.png',fullPage:true});}
    await page.locator('.batch-result-row button').first().click();
    assert((await page.locator('#effects-source').inputValue()).includes('browser-batch-'));
    await page.locator('#effects-output').fill(process.env.MULTICAM_TEST_OUTPUT);
    await page.locator('#effects-name').fill('browser-style-'+Date.now());
    await page.locator('[name="colour-style"][value="warm"]').check();
    await page.locator('#preview-effects').click();
    await page.waitForFunction(()=>document.querySelector('#effects-result h3')?.textContent==='Preview ready',{},{timeout:90000});
    assert(!(await page.locator('#effects-video').isHidden()));
    assert(await page.locator('#error-banner').isHidden());
    if(process.env.MULTICAM_TEST_EVIDENCE)await page.screenshot({path:process.env.MULTICAM_TEST_EVIDENCE+'/effects-desktop.png',fullPage:true});
    await page.setViewportSize({width:390,height:844});
    await page.locator('[name="colour-style"][value="vintage"]').check();
    assert.equal(await page.locator('#effects-style').inputValue(),'vintage');
    assert(await page.evaluate(()=>document.documentElement.scrollWidth<=window.innerWidth),'Mobile page must not overflow horizontally');
    await page.evaluate(()=>window.scrollTo(0,450));
    assert.equal(Math.round(await page.locator('.studio-tabs').evaluate(el=>el.getBoundingClientRect().top)),0);
    if(process.env.MULTICAM_TEST_EVIDENCE)await page.screenshot({path:process.env.MULTICAM_TEST_EVIDENCE+'/effects-mobile.png',fullPage:true});
    assert.deepEqual(errors,[]);
    console.log(JSON.stringify({status:'passed',style_changes:26,short_clip_count:shortCount,long_clip_count:3,exported_clips:2,effects_preview:true,mobile:true,errors},null,2));
  }finally{await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
