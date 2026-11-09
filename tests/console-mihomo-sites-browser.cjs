// SPDX-License-Identifier: Apache-2.0
// Live configured router; sends four HTTPS HEAD probes through current rules.
const { chromium } = require('playwright');
const assert = require('node:assert/strict');
(async () => {
	const browser = await chromium.launch({ headless: true, executablePath: process.env.CONSOLE_BROWSER_EXECUTABLE || 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe' });
	const page = await browser.newPage({ viewport: { width: 1440, height: 1000 } });
	const errors = []; page.on('pageerror', error => errors.push(error.message));
	try {
		await page.goto('http://192.168.1.1/cgi-bin/luci/admin/vpn/console-mihomo');
		if (await page.locator('[name=luci_username]').count()) { await page.locator('[name=luci_username]').fill('root'); await page.getByRole('button', { name: '登录' }).click(); }
		await page.getByRole('heading', { name: '网站连通性测试', exact: true }).waitFor();
		const getState = () => page.evaluate(async () => { const rpc = await L.require('rpc'); return rpc.declare({ object: 'console-mihomo', method: 'status', reject: true })(); });
		const initial = await getState(); assert.equal(initial.running, true);
		for (const name of ['GitHub', 'Google（谷歌）', 'ChatGPT', 'YouTube']) {
			assert.equal(await page.getByRole('link', { name, exact: true }).getAttribute('target'), '_blank');
		}
		const rejected = await page.evaluate(async () => { const rpc = await L.require('rpc'); return rpc.declare({ object: 'console-mihomo', method: 'site_test', params: ['id'], reject: true })('https://invalid.example/'); });
		assert.ok(rejected.error);
		await page.getByRole('button', { name: '测试全部网站', exact: true }).click();
		await page.getByText('全部网站测试已完成。', { exact: true }).waitFor({ timeout: 60000 });
		const state = await getState();
		for (const id of ['github', 'google', 'chatgpt', 'youtube']) {
			const r = state.siteTests[id]; assert.ok(r && r.testedAt);
			const label = await page.locator('[data-site-result=' + id + ']').innerText();
			assert.notEqual(label, '未测试');
			if ([401, 403, 429].includes(r.code)) { assert.match(label, /访问受限/); assert.doesNotMatch(label, /可访问/); }
			if (r.delay != null) assert.ok(Number.isInteger(r.delay) && r.delay >= 0);
		}
		assert.equal(state.mode, initial.mode); assert.equal(state.transparent, initial.transparent);
		assert.deepEqual(state.groups.filter(g => g.type === 'Selector').map(g => [g.name, g.now]), initial.groups.filter(g => g.type === 'Selector').map(g => [g.name, g.now]));
		console.log(JSON.stringify(state.siteTests, null, 2));
		await page.locator('.cbi-section').filter({ has: page.getByRole('heading', { name: '网站连通性测试', exact: true }) }).screenshot({ path: 'tmp/mihomo-sites-desktop.png' });
		await page.reload(); await page.getByRole('heading', { name: '网站连通性测试', exact: true }).waitFor();
		for (const id of ['github', 'google', 'chatgpt', 'youtube']) assert.notEqual(await page.locator('[data-site-result=' + id + ']').innerText(), '未测试');
		await page.setViewportSize({ width: 375, height: 812 });
		assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth), false);
		await page.locator('.cbi-section').filter({ has: page.getByRole('heading', { name: '网站连通性测试', exact: true }) }).screenshot({ path: 'tmp/mihomo-sites-mobile.png' });
		assert.deepEqual(errors, []);
		console.log('Passed: four links, actual route probes, restricted response labeling, cached results, unchanged node and mode, desktop/mobile layout.');
	} finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
