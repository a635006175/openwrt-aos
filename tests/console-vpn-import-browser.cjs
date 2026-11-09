// SPDX-License-Identifier: Apache-2.0
// 浏览器验证 OpenVPN 客户端页面的 .ovpn 导入交互：选择配置文件后应显示解析摘要，
// 服务端地址、端口与协议自动带入表单，CA 证书转为只读；不执行导入，避免改动设备状态。
const { chromium } = require('playwright');
const assert = require('node:assert/strict');
const path = require('node:path');

(async () => {
	const browser = await chromium.launch({ headless: true, executablePath: 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe' });
	const page = await browser.newPage({ viewport: { width: 1200, height: 900 } });
	const errors = [];
	page.on('pageerror', e => errors.push(e.message));
	try {
		await page.goto('http://192.168.1.1/cgi-bin/luci/');
		await page.locator('[name=luci_username]').fill('root');
		await page.getByRole('button', { name: '登录' }).click();
		await page.goto('http://192.168.1.1/cgi-bin/luci/admin/vpn/console-client');
		await page.getByRole('heading', { name: 'OpenVPN 客户端' }).waitFor();

		assert.equal(await page.getByText('导入 .ovpn 配置').count(), 1);
		assert.equal(await page.locator('input[type=file]').count(), 1);
		assert.equal(await page.getByRole('button', { name: '导入并连接' }).count(), 1);
		assert.equal(await page.getByRole('button', { name: '清除导入' }).count(), 1);

		await page.locator('input[type=file]').setInputFiles(path.join(__dirname, 'fixtures', 'vpn-import-sample.ovpn'));
		await page.locator('.cbi-value-field', { hasText: 'vpn.example.com : 1194' }).waitFor({ timeout: 15000 });

		assert.equal(await page.getByLabel('服务端地址').inputValue(), 'vpn.example.com');
		assert.equal(await page.getByLabel('端口').inputValue(), '1194');
		assert.equal(await page.getByLabel('协议').inputValue(), 'udp');
		assert.equal(await page.getByLabel('CA 证书').isDisabled(), true);
		const text = await page.locator('.cbi-section').first().innerText();
		assert.match(text, /配置内已包含/);
		assert.match(text, /需要填写账号密码/);
		assert.match(text, /cipher AES-256-GCM/);
		assert.doesNotMatch(text, /script-security/);
		assert.doesNotMatch(text, /echo should be ignored/);
		assert.deepEqual(errors, []);
		console.log('Passed: .ovpn import section, parsed summary, form prefill and read-only CA.');
	} finally {
		await browser.close();
	}
})().catch(error => { console.error(error); process.exit(1); });