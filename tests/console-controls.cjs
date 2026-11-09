// SPDX-License-Identifier: Apache-2.0
// Inspect installed pages and safe UI interactions; never save/apply/delete/reboot.
const { chromium } = require('playwright');
const assert = require('node:assert/strict');
const fs = require('node:fs');
(async () => {
	const base = process.env.CONSOLE_LIVE_BASE || 'http://192.168.1.1';
	const browser = await chromium.launch({ headless: true, executablePath: process.env.CONSOLE_BROWSER_EXECUTABLE || 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe' });
	const page = await browser.newPage({ viewport: { width: 1440, height: 1000 } });
	const errors = [], report = [];
	page.on('pageerror', e => errors.push(e.message));
	try {
		await page.goto(base + '/cgi-bin/luci/');
		await page.locator('[name=luci_username]').fill(process.env.CONSOLE_LIVE_USER || 'root');
		await page.locator('[name=luci_password]').fill(process.env.CONSOLE_LIVE_PASSWORD || '');
		await page.getByRole('button', { name: '登录' }).click();
		await page.locator('.console-sidebar a').first().waitFor();
		const urls = new Set(await page.locator('.console-sidebar a').evaluateAll(xs => xs.map(x => x.href)));
		for (const url of urls) {
			const response = await page.goto(url);
			assert.ok(response.ok(), url);
			await page.locator('.console-sidebar a').first().waitFor();
			await page.waitForFunction(() => !document.querySelector('#view .spinning'));
			for (const href of await page.locator('#tabmenu a').evaluateAll(xs => xs.map(x => x.href))) urls.add(href);
			const controls = await page.locator('.btn, .cbi-button').evaluateAll(xs => xs.filter(x => x.getClientRects().length).map(x => {
				const s = getComputedStyle(x); return { text: x.textContent.trim().slice(0, 40) || x.value, radius: s.borderRadius, height: x.getBoundingClientRect().height, background: s.backgroundImage };
			}));
			for (const c of controls) {
				assert.equal(c.radius, '4px', url + ': radius ' + c.text);
				assert.ok(c.height >= 33, url + ': height ' + c.text + '=' + c.height);
				assert.ok(!c.background.includes('gradient'), url + ': gradient ' + c.text);
			}
			report.push({ url, controls: controls.length });
		}
		fs.writeFileSync('tmp/console-qa/controls-report.json', JSON.stringify(report, null, 2));
		console.log('Inspected ' + report.length + ' pages.');
		await page.goto(base + '/cgi-bin/luci/admin/network/network');
		await page.getByRole('button', { name: '编辑配置', exact: true }).click();
		await page.locator('#modal_overlay').waitFor({ state: 'visible' });
		const tabs = page.locator('#modal_overlay .cbi-tabmenu a');
		for (let i = 0; i < await tabs.count(); i++) if (await tabs.nth(i).isVisible()) await tabs.nth(i).click();
		await page.screenshot({ path: 'tmp/console-qa/unified-interface-modal.png', animations: 'disabled' });
		await page.goto(base + '/cgi-bin/luci/admin/network/dhcp');
		const dhcpTabs = page.locator('.cbi-tabmenu a');
		for (let i = 0; i < await dhcpTabs.count(); i++) if (await dhcpTabs.nth(i).isVisible()) await dhcpTabs.nth(i).click();
		await page.screenshot({ path: 'tmp/console-qa/unified-dhcp.png', animations: 'disabled' });
		await page.setViewportSize({ width: 375, height: 812 });
		await page.goto(base + '/cgi-bin/luci/admin/network/network');
		await page.getByRole('button', { name: '编辑配置', exact: true }).click();
		await page.locator('#modal_overlay').waitFor({ state: 'visible' });
		await page.screenshot({ path: 'tmp/console-qa/unified-modal-mobile.png', animations: 'disabled' });
		assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1), 'mobile overflow');
		assert.deepEqual(errors, []);
		fs.writeFileSync('tmp/console-qa/controls-report.json', JSON.stringify(report, null, 2));
		console.log('Passed: ' + report.length + ' installed pages, ' + report.reduce((sum, row) => sum + row.controls, 0) + ' visible buttons, interface modal tabs, DHCP tabs and mobile modal.');
	} finally { await browser.close(); }
})().catch(e => { console.error(e); process.exitCode = 1; });
