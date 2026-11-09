// SPDX-License-Identifier: Apache-2.0
// Read-only live audit: every overview navigation target and local dashboard controls.
const {chromium}=require('playwright');const assert=require('node:assert/strict');const fs=require('node:fs');
(async()=>{const browser=await chromium.launch({headless:true,executablePath:'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe'});const page=await browser.newPage({viewport:{width:1440,height:1000},reducedMotion:'reduce'}),errors=[],results=[];page.on('pageerror',e=>errors.push({url:page.url(),error:e.message}));
try{
 await page.goto('http://192.168.1.1/cgi-bin/luci/');await page.locator('[name=luci_username]').fill('root');await page.getByRole('button',{name:'登录',exact:true}).click();await page.locator('#ow-console').waitFor();
 await page.getByRole('button',{name:'暂停刷新',exact:true}).click();await page.getByRole('button',{name:'继续刷新',exact:true}).waitFor();await page.getByRole('button',{name:'继续刷新',exact:true}).click();await page.getByRole('button',{name:'立即刷新数据',exact:true}).click();
 for(const locator of [page.locator('.ow-connection-card .ow-metric-button'),page.locator('.ow-client-types button').nth(0),page.locator('.ow-client-types button').nth(1)]){await locator.click();await page.locator('dialog[open]').waitFor();await page.getByRole('button',{name:'关闭终端列表',exact:true}).click();assert.equal(await page.locator('dialog[open]').count(),0);}
 for(const label of ['协议流量统计时段','速率历史时段','速率图线路']){const select=page.getByLabel(label,{exact:true});const options=await select.locator('option').evaluateAll(es=>es.map(e=>e.value));for(const value of options)await select.selectOption(value);}
 for(const summary of await page.locator('.console-sidebar summary').all()){await summary.click();await summary.click();}
 
 assert.equal(await page.locator('#ow-console a[href*="/admin/network/network"]').count(),0,'obsolete interface link');
 for(const a of await page.locator('.ow-wireless-card a').all())if(await a.getAttribute('aria-disabled')==='true')assert.equal(await a.getAttribute('href'),null,'unsupported wireless target disabled');
 const links=await page.locator('#ow-console a[href],.console-header a[href],.console-sidebar a[href],#maincontent .alert-message a[href]').evaluateAll(es=>es.map(e=>({url:e.href,label:e.getAttribute('aria-label')||e.textContent.trim()})));const urls=[...new Set(links.map(e=>e.url))].filter(u=>!u.includes('#')&&!u.endsWith('/logout'));
 await page.screenshot({path:'tmp/console-qa/overview-links-desktop.png',animations:'disabled',fullPage:true});
 await page.setViewportSize({width:375,height:900});await page.locator('.console-toggle').click();assert.equal(await page.locator('.console-toggle').getAttribute('aria-expanded'),'true');await page.keyboard.press('Escape');assert.equal(await page.locator('.console-toggle').getAttribute('aria-expanded'),'false');
 await page.setViewportSize({width:1440,height:1000});
 for(const url of urls){const response=await page.goto(url);await page.waitForFunction(()=>document.readyState==='complete');await page.waitForFunction(()=>!document.querySelector('#view .spinning'),{},{timeout:15000});const body=await page.locator('body').innerText();const result={url,status:response.status(),denied:/Access denied|拒绝访问|403 Forbidden|No page is registered/.test(body)};results.push(result);assert.equal(result.status,200,url);assert.equal(result.denied,false,url);}
 await page.goto('http://192.168.1.1/cgi-bin/luci/admin/console');await page.locator('#ow-console').waitFor();await page.locator('.console-logout').click();await page.locator('[name=luci_username]').waitFor();
 assert.deepEqual(errors,[]);console.log(JSON.stringify({pages:results.length,controls:'passed',logout:'passed',errors}));
}finally{fs.writeFileSync('tmp/console-qa/overview-click-audit.json',JSON.stringify({results,errors},null,2));await browser.close();}})().catch(e=>{console.error(e);process.exitCode=1;});
