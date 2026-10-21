/* Run with NODE_PATH pointing to Playwright and MULTICAM_AUDIO_FIXTURE pointing
   to a folder containing setup.json, A.MOV, B.MOV and three gapped WAV excerpts.
   Fixture recipe: tests/test_audio_parts.py. Use an isolated Studio instance. */
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const {chromium}=require('playwright');
(async()=>{
 const fixture=process.env.MULTICAM_AUDIO_FIXTURE;assert(fixture,'Set MULTICAM_AUDIO_FIXTURE');
 const browser=await chromium.launch({headless:true});
 try{
  const page=await browser.newPage({viewport:{width:1440,height:1000}}),errors=[];
  page.on('pageerror',error=>errors.push(error.message));
  await page.goto(process.env.MULTICAM_TEST_URL||'http://127.0.0.1:8776');
  await page.waitForFunction(()=>!document.querySelector('#plan-button').disabled);
  // Projects saved before multi-audio support must retain their timing.
  const legacy=JSON.parse(fs.readFileSync(path.join(fixture,'setup.json')));
  legacy.audio=legacy.audio_parts[0].path;delete legacy.audio_parts;delete legacy.active_audio;
  legacy.drops=[[.5,2.5]];legacy.overrides=[{path:path.join(fixture,'A.MOV'),offset:-2,drift_ppm:null}];
  legacy.shot_overrides=[{start:0,end:1,camera_id:'A'}];
  await page.locator('#settings-file').setInputFiles({name:'legacy-project.json',mimeType:'application/json',buffer:Buffer.from(JSON.stringify(legacy))});
  await page.waitForFunction(()=>document.querySelectorAll('#files-audio .file-row').length===1);
  assert.equal(await page.locator('#drops').inputValue(),'0.5–2.5');
  assert.equal(await page.locator('#sync-overrides .sync-override').first().locator('input').first().inputValue(),'-2');
  assert.equal(await page.locator('#shot-overrides .override-row').count(),1);
  await page.locator('#settings-file').setInputFiles(path.join(fixture,'setup.json'));
  await page.waitForFunction(()=>document.querySelectorAll('#files-audio .file-row').length===3);
  assert.match(await page.locator('#audio-active-label').textContent(),/excerpt1.wav/);
  await page.locator('details:has(#drops)>summary').click();
  await page.locator('details:has(#sync-overrides)>summary').click();
  const timing=page.locator('#files-audio .file-row');
  await timing.nth(1).getByRole('button',{name:'Edit timing',exact:true}).click();
  await page.locator('#drops').fill('0.5–2.5');
  await page.locator('#activities').fill('1.5');
  await page.locator('#sync-overrides .sync-override').first().locator('input').first().fill('-9');
  await timing.nth(0).getByRole('button',{name:'Edit timing',exact:true}).click();
  assert.equal(await page.locator('#drops').inputValue(),'');
  assert.equal(await page.locator('#sync-overrides .sync-override').first().locator('input').first().inputValue(),'');
  await timing.nth(1).getByRole('button',{name:'Edit timing',exact:true}).click();
  assert.equal(await page.locator('#drops').inputValue(),'0.5–2.5');
  assert.equal(await page.locator('#sync-overrides .sync-override').first().locator('input').first().inputValue(),'-9');
  await timing.nth(2).getByRole('button',{name:'Edit timing',exact:true}).click();
  await page.locator('#load-edit-wave').click();
  await page.waitForFunction(()=>!document.querySelector('#edit-wave-host .waveform-body').hidden);
  await page.locator('#override-camera').selectOption('A');
  await page.locator('#add-shot-override').click();
  assert.equal(await page.locator('#shot-overrides .override-row').count(),1);
  const downloadPromise=page.waitForEvent('download');await page.locator('#save-settings').click();
  const download=await downloadPromise,projectPath=path.join(fixture,'saved-project.json');await download.saveAs(projectPath);
  const project=JSON.parse(fs.readFileSync(projectPath));
  assert.equal(project.audio_parts.length,3);assert.equal(project.audio_parts[0].shot_overrides.length,0);
  assert.deepEqual(project.audio_parts[1].drops,[[.5,2.5]]);assert.equal(project.audio_parts[1].overrides[0].offset,-9);
  assert.equal(project.audio_parts[2].shot_overrides[0].camera_id,'A');
  await page.locator('#settings-file').setInputFiles(projectPath);
  assert.match(await page.locator('#audio-active-label').textContent(),/excerpt3.wav/);
  assert.equal(await page.locator('#shot-overrides .override-row').count(),1);
  await page.locator('#output-dir').fill(path.join(fixture,'browser-'+Date.now()));
  async function start(id){const response=page.waitForResponse(r=>r.url().endsWith('/api/jobs')&&r.request().method()==='POST');await page.locator('#'+id).click();const r=await response;const body=await r.json();assert.equal(r.status(),201,JSON.stringify(body));return body.id;}
  const plan=await start('plan-button');
  await page.waitForFunction(()=>document.querySelector('#audio-batch-results h3')?.textContent==='3/3 audio excerpts planned',{},{timeout:120000});
  await page.locator('#overwrite').check();
  const render=await start('render-button');
  await page.waitForFunction(()=>document.querySelector('#audio-batch-results h3')?.textContent==='3/3 audio excerpts exported'&&!document.querySelector('#render-button').disabled,{},{timeout:180000});
  const job=await page.evaluate(async id=>await(await fetch('/api/jobs/'+id,{headers:{'X-Multicam-Token':window.MULTICAM_TOKEN}})).json(),render);
  assert.equal(job.status,'completed',job.error);assert.equal(job.report.outputs.videos.length,3);
  for(const part of job.report.parts){assert.equal(part.report.width,3840);assert.equal(part.report.height,2160);assert(part.artifacts.some(a=>a.kind==='video'));}
  await page.locator('.audio-part-result button').nth(2).click();
  assert.match(await page.locator('#sync-table').textContent(),/-23.000/);
  assert(!(await page.locator('#output-video').isHidden()));
  const evidence=process.env.MULTICAM_TEST_EVIDENCE;
  if(evidence){fs.mkdirSync(evidence,{recursive:true});await page.evaluate(()=>window.scrollTo(0,0));await page.screenshot({path:path.join(evidence,'audio-parts-desktop.png'),fullPage:true});}
  await page.setViewportSize({width:390,height:844});
  assert(await page.evaluate(()=>document.documentElement.scrollWidth<=window.innerWidth),'Mobile must not overflow');
  assert.deepEqual(errors,[]);
  const result={status:'passed',audio_parts:3,separate_4k_exports:3,per_excerpt_timing:true,project_round_trip:true,legacy_project_timing:true,early_camera_fallback:true,plan,render,errors};
  console.log(JSON.stringify(result,null,2));
 }finally{await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
