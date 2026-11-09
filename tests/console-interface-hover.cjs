const {chromium}=require('playwright');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
(async()=>{
 const out=path.resolve(__dirname,'../.stage/interface-hover'); fs.mkdirSync(out,{recursive:true});
 const browser=await chromium.launch({headless:true,executablePath:'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe'});
 const context=await browser.newContext({viewport:{width:1440,height:1000}});
 const page=await context.newPage(),errors=[]; page.on('pageerror',e=>errors.push(e.message));
 page.setDefaultTimeout(10000);
 try {
  await page.goto(process.argv[2] || 'http://127.0.0.1:8788/');
  const login=page.locator('[name=luci_username]:visible');
  if(await login.count()){ await login.fill('root'); await page.locator('button[type=submit]:visible').click(); }
  await page.locator('#ow-console').waitFor();
  const wan=page.locator('.ow-port').filter({has:page.locator('.ow-port-name',{hasText:/^wan$/})});
  await wan.hover();
  let dialog=page.locator('.ow-port-details:not([hidden])'); await dialog.waitFor();
  for(const label of ['接口状态','物理链路','协商速率','实时接收 / 发送','IPv4 地址','IPv6 地址','默认网关','接口 DNS','MAC / MTU','接收 / 发送错误']) assert.ok((await dialog.innerText()).includes(label),label);
  await dialog.hover(); assert.ok(await dialog.isVisible(),'panel remains hoverable');
  const oldTime=await page.locator('.ow-updated').first().innerText();
  await page.waitForFunction(old=>document.querySelector('.ow-updated')?.textContent!==old,oldTime,{timeout:10000});
  assert.ok(await dialog.isVisible(),'poll refresh preserves the open panel');
  await page.screenshot({path:path.join(out,'desktop-hover.png')});
  await page.keyboard.press('Escape'); assert.equal(await dialog.count(),0);
  await page.keyboard.press('Tab'); await wan.focus(); await page.locator('.ow-port-details:not([hidden])').waitFor();
  await page.keyboard.press('Escape'); assert.equal(await dialog.count(),0);
  await page.mouse.move(0,0); await page.locator('.ow-updated').count();
  const lan=page.locator('.ow-port').filter({has:page.locator('.ow-port-name',{hasText:/^lan$/})});
  await lan.hover(); dialog=page.locator('.ow-port-details:not([hidden])'); await dialog.waitFor();
  assert.ok((await dialog.innerText()).includes('成员网口'));
  await page.screenshot({path:path.join(out,'lan-hover.png')});
  await page.keyboard.press('Escape');
  await page.setViewportSize({width:375,height:812});
  await wan.click(); dialog=page.locator('.ow-port-details:not([hidden])'); await dialog.waitFor();
  const box=await dialog.boundingBox(); assert.ok(box.x>=0 && box.x+box.width<=375 && box.y>=0 && box.y+box.height<=812,JSON.stringify(box));
  await dialog.locator('.ow-port-settings').scrollIntoViewIfNeeded();
  await page.screenshot({path:path.join(out,'mobile-details.png')});
  await dialog.getByRole('button',{name:'关闭接口详情'}).click(); assert.equal(await dialog.count(),0);
  assert.deepEqual(errors,[]); console.log(JSON.stringify({desktopHover:true,panelHover:true,pollRefresh:true,keyboardFocus:true,escapeDismiss:true,mobileBounds:true,errors}));
 } catch(error) {
  await page.screenshot({path:path.join(out,'failure.png'),fullPage:true});
  console.error(JSON.stringify(await page.locator('.ow-port,.ow-interfaces-card,.ow-graphs-card').evaluateAll(nodes=>nodes.map(n=>({class:n.className,rect:JSON.stringify(n.getBoundingClientRect().toJSON())})))));
  throw error;
 } finally {await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
