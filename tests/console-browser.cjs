// SPDX-License-Identifier: Apache-2.0
// Requires Playwright in NODE_PATH; uses an installed Edge on Windows by default.
const { chromium } = require('playwright');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

(async () => {
	const edge = 'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe';
	const executablePath = process.env.CONSOLE_BROWSER_EXECUTABLE || (fs.existsSync(edge) ? edge : undefined);
	const browser = await chromium.launch({ headless: true, executablePath });
	const page = await browser.newPage({ viewport: { width: 1600, height: 1120 }, reducedMotion: 'reduce' });
	const errors = [];
	page.on('pageerror', error => errors.push(error.message));
	const output = path.resolve(__dirname, '../tmp/console-qa'); fs.mkdirSync(output, { recursive: true });
	try {
		await page.goto(process.env.CONSOLE_PREVIEW_URL || 'http://127.0.0.1:8788');
		await page.waitForFunction(() => !!window.ConsolePreview);
		// The app runs inside the LuCI host theme in production, not an isolated body.
		const themeCSS = path.resolve(__dirname, '../feeds/luci/themes/luci-theme-bootstrap/htdocs/luci-static/bootstrap/cascade.css');
		if (fs.existsSync(themeCSS)) {
			await page.addStyleTag({ path: themeCSS });
			await page.evaluate(() => {
				document.head.append(document.getElementById('ow-console-css'));
				const header = document.createElement('header'); header.textContent = 'Native LuCI header';
				header.id = 'luci-host-header'; document.body.prepend(header);
			});
			const topElement = await page.evaluate(() => document.elementFromPoint(50, 25).closest('#ow-console') !== null);
			assert.equal(topElement, true, 'The console must cover the host theme header');
			assert.equal(await page.locator('.ow-topbar').evaluate(node => getComputedStyle(node).position), 'static');
		}
		await page.getByRole('button', { name: '暂停刷新' }).click();
		assert.equal(await page.getByRole('button', { name: '继续刷新' }).getAttribute('aria-pressed'), 'true');
		assert.equal(await page.locator('.ow-route-state').textContent(), '已连接');
		assert.equal(await page.locator('.ow-route-card strong').textContent(), 'OpenWrt-Gateway');
		assert.equal(await page.locator('.ow-connection-card .ow-metric-button .ow-number').textContent(), '14');
		await page.getByText('网络', { exact: true }).click();
		assert.equal(await page.getByRole('link', { name: '端口转发' }).getAttribute('href'), '/cgi-bin/luci/admin/network/firewall/forwards');
		assert.equal(await page.getByRole('link', { name: 'DNS', exact: true }).getAttribute('href'), '/cgi-bin/luci/admin/network/dns');
		await page.getByText('网络', { exact: true }).click();
		assert.ok((await page.locator('.ow-updated').textContent()).includes('示例数据'));
		await page.screenshot({ path: path.join(output, 'desktop.png') });
		for (const [ width, height ] of [ [ 1440, 1000 ], [ 1024, 900 ], [ 768, 1024 ], [ 375, 1000 ] ]) {
			await page.setViewportSize({ width, height });
			const overflow = await page.evaluate(() => ({ root: document.getElementById('ow-console').scrollWidth, workspace: document.querySelector('.ow-workspace').scrollWidth, workspaceWidth: document.querySelector('.ow-workspace').clientWidth }));
			assert.ok(overflow.root <= width + 1, 'Horizontal root overflow at ' + width + ': ' + JSON.stringify(overflow));
			assert.ok(overflow.workspace <= overflow.workspaceWidth + 1, 'Horizontal workspace overflow at ' + width + ': ' + JSON.stringify(overflow));
		}
		await page.screenshot({ path: path.join(output, 'mobile.png') });
		const menu = page.getByRole('button', { name: '展开或收起导航' });
		assert.equal(await menu.getAttribute('aria-expanded'), 'false');
		await menu.click(); assert.equal(await menu.getAttribute('aria-expanded'), 'true');
		assert.equal(await page.locator('.ow-sidebar').isVisible(), true);
		await page.keyboard.press('Escape'); assert.equal(await menu.getAttribute('aria-expanded'), 'false');
		await page.locator('button.ow-metric-button').click();
		assert.equal(await page.getByRole('dialog').isVisible(), true);
		assert.equal(await page.locator('.ow-client-table tbody tr').count(), 14);
		await page.keyboard.press('Escape'); assert.equal(await page.getByRole('dialog').count(), 0);
		await page.locator('#ow-period').selectOption('3600');
		await page.getByRole('button', { name: '立即刷新数据' }).click();
		await page.waitForFunction(() => !window.ConsolePreview.view.busy);
		assert.equal(await page.locator('#ow-period').inputValue(), '3600');
		await page.locator('#ow-line').selectOption('eth1');
		assert.equal(await page.locator('svg.ow-line-chart').count(), 1);
		await page.evaluate(() => window.ConsolePreview.setScenario('no-wifi'));
		assert.ok((await page.locator('.ow-wireless-card').textContent()).includes('未检测到无线设备'));
		assert.equal(await page.locator('.ow-wireless-card a[href]').count(), 0);
		assert.equal(await page.locator('.ow-error').isVisible(), false);
		assert.notEqual(await page.locator('.ow-interfaces-card').textContent().then(text => text.match(/DHCP 池剩余/)), null);
		for (const [ scenario, expected ] of [ [ 'wifi-rpc-error', '无线状态' ], [ 'wifi-config-error', 'wireless 配置' ], [ 'wifi-detection-error', '无线状态' ] ]) {
			await page.evaluate(value => window.ConsolePreview.setScenario(value), scenario);
			assert.ok((await page.locator('.ow-error').textContent()).includes(expected), scenario + ' must remain an error');
		}
		await page.evaluate(() => window.ConsolePreview.setScenario('offline'));
		assert.equal(await page.locator('.ow-route-state').textContent(), '未连接');
		await page.evaluate(() => window.ConsolePreview.setScenario('rpc-error'));
		assert.equal(await page.locator('.ow-route-state').textContent(), '状态未知');
		assert.equal(await page.locator('.ow-error').isVisible(), true);
		assert.ok((await page.locator('.ow-error').textContent()).includes('网卡计数'));
		await page.evaluate(() => window.ConsolePreview.setScenario('no-accounting'));
		assert.ok((await page.locator('.ow-protocol-card').textContent()).includes('计数不可用'));
		await page.evaluate(() => window.ConsolePreview.setScenario('xss'));
		assert.ok((await page.locator('.ow-route-card strong').textContent()).includes('<img'));
		assert.equal(await page.locator('.ow-route-card strong img').count(), 0);
		assert.equal(await page.evaluate(() => !!window.injected), false);
		assert.equal(await page.locator('.ow-nav-item.is-pending:not([disabled])').count(), 0);
		await page.setViewportSize({ width: 1600, height: 1120 });
		await page.evaluate(() => window.ConsolePreview.setScenario('normal'));
		assert.deepEqual(errors, []);
		console.log('Browser checks passed: 4 responsive widths, pause/refresh, navigation, terminal dialog, charts, missing Wi-Fi, offline, RPC errors and XSS.');
		console.log('Screenshots: ' + output);
	}
	finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
