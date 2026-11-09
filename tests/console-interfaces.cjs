// SPDX-License-Identifier: Apache-2.0
const { chromium } = require('playwright');
const assert = require('node:assert/strict');
(async () => {
	const browser = await chromium.launch({ headless: true, executablePath: 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe' });
	const page = await browser.newPage({ viewport: { width: 1440, height: 1100 } });
	const errors = []; page.on('pageerror', e => errors.push(e.message));
	try {
		await page.goto('http://192.168.1.1/cgi-bin/luci/');
		await page.locator('[name=luci_username]').fill('root');
		await page.getByRole('button', { name: '登录' }).click();
		await page.locator('#ow-console').waitFor();
		await page.goto('http://192.168.1.1/cgi-bin/luci/admin/network/network');
		await page.locator('.cn-port').first().waitFor();
		assert.ok(await page.locator('.cn-port').count() >= 2);
		await page.locator('.cn-port').filter({ hasText: 'wan6' }).click();
		assert.ok((await page.locator('.cn-detail-heading').innerText()).includes('wan6'));
		await page.locator('.cn-port').filter({ hasText: 'lan' }).first().click();
		assert.ok((await page.locator('.cn-fields').innerText()).includes('192.168.1.1'));
		await page.getByRole('button', { name: '编辑配置', exact: true }).click();
		await page.locator('#modal_overlay').waitFor({ state: 'visible' });
		assert.ok(await page.locator('#modal_overlay input').count() > 0);
		await page.goto('http://192.168.1.1/cgi-bin/luci/admin/network/network');
		await page.locator('.cn-port').first().waitFor();
		await page.screenshot({ path: 'tmp/console-qa/interfaces-new.png', animations: 'disabled', fullPage: true });
		for (const width of [1024, 768, 375]) {
			await page.setViewportSize({ width, height: 1000 });
			assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1), 'overflow at ' + width);
		}
		await page.screenshot({ path: 'tmp/console-qa/interfaces-new-mobile.png', animations: 'disabled', fullPage: true });
		assert.deepEqual(errors, []);
		console.log('Passed: live interface selection, real addresses, native editor, 4 widths, no configuration writes.');
	} finally { await browser.close(); }
})().catch(e => { console.error(e); process.exitCode = 1; });
