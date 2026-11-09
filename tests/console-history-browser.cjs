// SPDX-License-Identifier: Apache-2.0
const { chromium } = require('playwright');
const assert = require('node:assert/strict');
const { execFileSync } = require('node:child_process');
const executablePath = 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe';
async function login(browser) {
	const page = await browser.newPage({ viewport: { width: 1440, height: 1000 } });
	await page.goto('http://192.168.1.1/cgi-bin/luci/');
	await page.locator('[name=luci_username]').fill('root');
	await page.getByRole('button', { name: '登录' }).click();
	await page.locator('#ow-console').waitFor();
	return page;
}
async function history(page) {
	return page.evaluate(async () => (await L.require('rpc')).declare({ object: 'console-traffic', method: 'history', params: ['seconds'], reject: true })(300));
}
(async () => {
	let browser = await chromium.launch({ headless: true, executablePath });
	let page = await login(browser);
	let before = await history(page);
	const saved = before.samples.find(row => row.upload !== null && row.time >= before.last_sample - 40 && row.time <= before.last_sample - 15);
	assert.ok(saved, 'no persisted samples');
	assert.equal(await page.locator('.ow-error').isVisible(), false);
	await browser.close();
	// No browser process remains during this interval.
	await new Promise(resolve => setTimeout(resolve, 12000));
	browser = await chromium.launch({ headless: true, executablePath });
	try {
		page = await login(browser);
		const after = await history(page);
		assert.ok(after.last_sample >= before.last_sample + 10, 'collector stopped with browser closed');
		assert.deepEqual(after.samples.find(row => row.time === saved.time), saved, 'old history lost on reload');
		execFileSync('ssh', ['-o','BatchMode=yes','-o','ConnectTimeout=5','-o','StrictHostKeyChecking=accept-new','-o','UserKnownHostsFile=NUL','root@192.168.1.1','/etc/init.d/console-traffic restart'], { stdio: 'pipe' });
		assert.deepEqual((await history(page)).samples.find(row => row.time === saved.time), saved, 'old history lost on collector restart');
		await page.locator('#ow-history-period').selectOption('1296000');
		await page.waitForFunction(() => Array.from(document.querySelectorAll('.ow-line-chart .ow-axis')).some(node => /\d{2}\/\d{2}/.test(node.textContent)));
		assert.equal(await page.locator('#ow-history-period').inputValue(), '1296000');
		await page.screenshot({ path: 'tmp/console-qa/history-fifteen-days.png', animations: 'disabled', fullPage: true });
		await page.setViewportSize({ width: 375, height: 1000 });
		assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1), 'mobile history selector overflows');
		console.log('Passed: browser closed for 12s while collection continued; reload and collector restart preserved data; 15-day chart selected.');
	} finally { await browser.close(); }
})().catch(e => { console.error(e); process.exitCode = 1; });
