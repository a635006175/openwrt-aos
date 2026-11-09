// SPDX-License-Identifier: Apache-2.0
const { chromium } = require('playwright');
const assert = require('node:assert/strict');
(async () => {
	const browser = await chromium.launch({ headless: true, executablePath: 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe' });
	const page = await browser.newPage({ viewport: { width: 1440, height: 1000 } });
	const errors = []; page.on('pageerror', e => errors.push(e.message));
	async function hover(fraction) {
		const graph = page.locator('.ow-line-chart').first();
		await graph.scrollIntoViewIfNeeded();
		const point = await graph.evaluate((node, fraction) => {
			const p = node.createSVGPoint(); p.x = 56 + 684 * fraction; p.y = 50;
			const screen = p.matrixTransform(node.getScreenCTM()); return { x: screen.x, y: screen.y };
		}, fraction);
		await page.mouse.move(point.x, point.y);
	}
	try {
		await page.goto('http://192.168.1.1/cgi-bin/luci/');
		await page.locator('[name=luci_username]').fill('root');
		await page.getByRole('button', { name: '登录' }).click();
		await page.locator('#ow-console').waitFor();
		await hover(.65);
		assert.equal(await page.locator('.ow-chart-tooltip:visible').count(), 1);
		const timestamp = +(await page.locator('.ow-chart-tooltip').first().getAttribute('data-time'));
		const archive = await page.evaluate(async () => (await L.require('rpc')).declare({ object: 'console-traffic', method: 'history', params: ['seconds'] })(300));
		const row = archive.samples.find(row => row.time === timestamp); assert.ok(row);
		for (const [i, key] of ['upload', 'download'].entries()) {
			const text = await page.locator('.ow-chart-tip-rate').nth(i).innerText();
			assert.ok(Number.isFinite(row[key]), 'test point must contain a real sample');
			const divisor = text.includes('MB/s') ? 1048576 : 1024;
			assert.ok(text.includes((row[key] / divisor).toFixed(2)), key + ': tooltip differs from persisted sample');
		}
		await page.waitForTimeout(6000);
		assert.equal(await page.locator('.ow-chart-tooltip:visible').count(), 1, 'polling erased hover state');
		assert.equal(await page.locator('.ow-chart-tooltip').first().getAttribute('data-time'), String(timestamp));
		await page.screenshot({ path: 'tmp/console-qa/history-hover.png', fullPage: true, animations: 'disabled' });
		await page.mouse.move(5, 5);
		assert.equal(await page.locator('.ow-chart-tooltip:visible').count(), 0);
		await page.locator('.ow-line-chart').first().focus();
		await page.keyboard.press('Home');
		assert.equal(await page.locator('.ow-chart-tooltip:visible').count(), 1);
		await page.keyboard.press('Escape');
		assert.equal(await page.locator('.ow-chart-tooltip:visible').count(), 0);
		await page.locator('#ow-history-period').selectOption('1296000');
		await page.waitForFunction(() => Array.from(document.querySelectorAll('.ow-line-chart .ow-axis')).some(node => /\d{2}\/\d{2}/.test(node.textContent)));
		await hover(.25);
		for (const text of await page.locator('.ow-chart-tip-rate').allTextContents()) assert.ok(text.includes('无记录'));
		await page.setViewportSize({ width: 375, height: 1000 });
		assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1));
		assert.deepEqual(errors, []);
		console.log('Passed: linked tooltips match stored rates and timestamps, survive refresh, dismiss, support keyboard, and distinguish missing data.');
	} finally { await browser.close(); }
})().catch(e => { console.error(e); process.exitCode = 1; });
