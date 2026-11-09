// SPDX-License-Identifier: Apache-2.0
// Read-only smoke test for a dedicated test router. No changes are saved or applied.
const { chromium } = require('playwright');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

(async () => {
	const base = process.env.CONSOLE_LIVE_BASE || 'http://192.168.1.1';
	const edge = 'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe';
	const browser = await chromium.launch({ headless: true, executablePath: process.env.CONSOLE_BROWSER_EXECUTABLE || (fs.existsSync(edge) ? edge : undefined) });
	const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });
	const errors = [];
	page.on('pageerror', error => errors.push(error.message));
	try {
		await page.goto(base + '/cgi-bin/luci/');
		await page.locator('[name=luci_username]').waitFor();
		await page.locator('[name=luci_username]').fill(process.env.CONSOLE_LIVE_USER || 'root');
		await page.locator('[name=luci_password]').fill(process.env.CONSOLE_LIVE_PASSWORD || '');
		await page.getByRole('button', { name: '登录' }).click();
		await page.locator('#ow-console').waitFor();
		if (process.env.CONSOLE_EXPECT_NO_WIFI === '1') {
			await page.waitForTimeout(6000);
			assert.equal(await page.locator('.ow-wireless-card').isVisible(), false);
			assert.equal(await page.locator('.ow-error').isVisible(), false);
		}
		const routes = [
			'network/network', 'network/routes', 'network/dhcp', 'network/dns', 'network/diagnostics',
			'network/firewall', 'network/firewall/forwards', 'network/firewall/rules',
			'system/system', 'system/startup', 'system/crontab', 'system/flash',
			'status/logs/syslog', 'status/logs/dmesg', 'status/realtime/bandwidth', 'status/realtime/connections'
		];
		for (const route of routes) {
			const response = await page.goto(base + '/cgi-bin/luci/admin/' + route);
			assert.ok(response.ok(), route + ': HTTP ' + response.status());
			await page.locator('.console-sidebar a').first().waitFor();
			await page.waitForFunction(() => !document.querySelector('#view .spinning'), null, { timeout: 15000 });
			assert.equal(await page.locator('.console-header').count(), 1, route + ': missing theme');
			assert.equal(await page.locator('body').innerText().then(s => /Runtime error|TypeError:|ReferenceError:/.test(s)), false, route + ': render error');
		}
		await page.goto(base + '/cgi-bin/luci/admin/network/network');
		await page.getByRole('button', { name: '编辑配置', exact: true }).click();
		await page.locator('#modal_overlay').waitFor({ state: 'visible' });
		assert.ok(await page.locator('#modal_overlay input').count() > 0, 'interface editor has no inputs');
		await page.keyboard.press('Escape');
		await page.setViewportSize({ width: 375, height: 812 });
		await page.reload();
		await page.locator('.console-sidebar a').first().waitFor({ state: 'attached' });
		await page.waitForFunction(() => !document.querySelector('#view .spinning'));
		assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1), 'mobile page overflows viewport');
		const toggle = page.getByRole('button', { name: '展开或收起导航' });
		await toggle.click();
		assert.equal(await toggle.getAttribute('aria-expanded'), 'true');
		assert.equal(await page.locator('.console-sidebar').isVisible(), true);
		await page.keyboard.press('Escape');
		assert.equal(await toggle.getAttribute('aria-expanded'), 'false');
		assert.deepEqual(errors, []);
		console.log('Live checks passed: ' + routes.length + ' pages, interface editor and mobile navigation.');
	} finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
