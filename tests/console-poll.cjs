// SPDX-License-Identifier: Apache-2.0
// Live lifecycle regression: let LuCI start its poller before mounting the view.
const { chromium } = require('playwright');
const assert = require('node:assert/strict');
(async () => {
	const browser = await chromium.launch({ headless: true, executablePath: 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe' });
	const page = await browser.newPage({ viewport: { width: 1440, height: 1000 } });
	const errors = []; page.on('pageerror', e => errors.push(e.message));
	try {
		await page.goto('http://192.168.1.1/cgi-bin/luci/');
		await page.locator('[name=luci_username]').fill('root');
		await page.getByRole('button', { name: '登录' }).click();
		await page.locator('#ow-console').waitFor();
		async function assertFirstFrame() {
			assert.ok((await page.locator('.ow-rate-value').allTextContents()).every(value => value !== '—'), 'first frame has no WAN rates');
			assert.ok(!(await page.locator('.ow-telemetry').nth(1).innerText()).includes('—'), 'first frame has no CPU reading');
			assert.match(await page.locator('.ow-connection-card .ow-metric-button .ow-number').innerText(), /^\d+$/);
		}
		await assertFirstFrame();
		await page.reload();
		await page.locator('#ow-console').waitFor();
		await assertFirstFrame();
		console.log('First frame has current values on initial login and browser refresh.');
		for (let i = 0; i < 3; i++) {
			const before = await page.locator('.ow-updated').innerText();
			await page.waitForFunction(previous => document.querySelector('.ow-updated').innerText !== previous, before, { timeout: 12000 });
			console.log('Automatic sample:', await page.locator('.ow-updated').innerText());
		}
		const rates = await page.locator('.ow-rate-value').allTextContents();
		assert.ok(rates.every(value => value !== '—'), 'WAN rate never sampled');
		assert.match(await page.locator('.ow-connection-card .ow-metric-button .ow-number').innerText(), /^\d+$/);
		assert.equal(await page.locator('.ow-telemetry-row').isVisible(), true);
		assert.ok(!(await page.locator('.ow-telemetry').nth(1).innerText()).includes('—'), 'CPU never sampled');
		assert.equal(await page.locator('.ow-error').isVisible(), false);
		console.log('Rates:', rates, 'Telemetry:', await page.locator('.ow-telemetry-row').innerText());
		await page.screenshot({ path: 'tmp/console-qa/overview-live-data.png', animations: 'disabled', fullPage: true });
		assert.deepEqual(errors, []);
	} finally { await browser.close(); }
})().catch(e => { console.error(e); process.exitCode = 1; });
