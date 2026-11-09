// SPDX-License-Identifier: Apache-2.0
const { chromium } = require('playwright');
const assert = require('node:assert/strict');
(async () => {
	const browser = await chromium.launch({ headless: true, executablePath: 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe' });
	const page = await browser.newPage({ viewport: { width: 1200, height: 900 } });
	const name = 'qa_' + Date.now();
	const errors = []; page.on('pageerror', e => errors.push(e.message));
	try {
		await page.goto('http://192.168.1.1/cgi-bin/luci/');
		await page.locator('[name=luci_username]').fill('root');
		await page.getByRole('button', { name: '登录' }).click();
		await page.locator('#ow-console').waitFor();
		await page.locator('.console-sidebar summary').filter({ hasText: 'VPN' }).click();
		await page.getByRole('link', { name: 'OpenVPN 服务端' }).click();
		await page.getByRole('heading', { name: 'OpenVPN 服务端' }).waitFor();
		assert.equal(await page.getByLabel('VPN 网段').inputValue(), '10.8.0.0/24');
		assert.equal(await page.getByLabel('服务端内网').inputValue(), '192.168.1.0/24');
		assert.equal(await page.getByRole('button', { name: '保存并启用' }).count(), 1);
		await page.getByRole('link', { name: 'OpenVPN 客户端' }).click();
		await page.getByRole('heading', { name: 'OpenVPN 客户端' }).waitFor();
		assert.equal(await page.getByLabel('服务端地址').count(), 1);
		assert.equal(await page.getByLabel('CA 证书').count(), 1);
		await page.getByRole('link', { name: 'OpenVPN 账号' }).click();
		await page.getByRole('button', { name: '新增账号' }).click();
		await page.getByLabel('账号', { exact: true }).fill(name);
		await page.getByLabel('密码', { exact: true }).fill('safe-test-only-123');
		await page.getByLabel('固定 VPN IP').fill('10.8.0.10');
		await page.getByLabel('客户端内网').fill('10.232.0.0/24');
		await page.getByRole('button', { name: '保存', exact: true }).click();
		await page.locator('tr').filter({ hasText: name }).waitFor();
		await page.locator('tr').filter({ hasText: name }).getByRole('button', { name: '编辑' }).click();
		assert.equal(await page.getByLabel('密码', { exact: true }).inputValue(), '');
		await page.getByRole('button', { name: '取消', exact: true }).click();
		await page.locator('tr').filter({ hasText: name }).getByRole('button', { name: '删除' }).click();
		await page.locator('#modal_overlay').getByRole('button', { name: '删除', exact: true }).click();
		await page.locator('tr').filter({ hasText: name }).waitFor({ state: 'detached' });
		assert.deepEqual(errors, []);
		console.log('Passed: menu, account creation, password not redisplayed, editing and deletion.');
	} finally {
		await page.evaluate(async name => {
			try { const rpc = await L.require('rpc'); await rpc.declare({ object: 'console-vpn-accounts', method: 'remove', params: ['username'] })(name); } catch {};
		}, name).catch(() => {});
		await browser.close();
	}
})().catch(e => { console.error(e); process.exitCode = 1; });
