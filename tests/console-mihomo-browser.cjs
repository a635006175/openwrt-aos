// SPDX-License-Identifier: Apache-2.0
// Run only on a test router with no Mihomo config. NODE_PATH must include Playwright.
const { chromium } = require('playwright');
const assert = require('node:assert/strict');
const { execFileSync } = require('node:child_process');
const config = `proxies:
  - name: qa-local
    type: socks5
    server: 127.0.0.1
    port: 9
proxy-groups:
  - name: 测试分组
    type: select
    proxies: [DIRECT, qa-local]
rules:
  - MATCH,DIRECT
`;
(async () => {
	const b = await chromium.launch({ headless: true, executablePath: process.env.CONSOLE_BROWSER_EXECUTABLE || 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe' });
	const p = await b.newPage({ viewport: { width: 1440, height: 1000 } });
	const errors = []; p.on('pageerror', e => errors.push(e.message));
	try {
		await p.goto('http://192.168.1.1/cgi-bin/luci/admin/vpn/console-mihomo');
		if (await p.locator('[name=luci_username]').count()) {
			await p.locator('[name=luci_username]').fill('root'); await p.getByRole('button', { name: '登录' }).click();
		}
		await p.getByRole('heading', { name: 'Clash / Mihomo', exact: true }).waitFor();
		const rpc = async (method, params, values) => p.evaluate(async ({ method, params, values }) => {
			const r = await L.require('rpc'); return r.declare({ object: 'console-mihomo', method, params: params || [], reject: true })(...(values || []));
		}, { method, params, values });
		assert.equal((await rpc('status')).configured, false, 'test requires unconfigured router');
		await p.getByLabel('配置内容', { exact: true }).fill(config);
		await p.getByRole('button', { name: '校验并保存', exact: true }).click();
		await p.getByText('配置已校验并保存，可启动服务。', { exact: true }).waitFor();
		assert.equal(await p.getByLabel('配置内容', { exact: true }).inputValue(), '');
		await p.getByRole('button', { name: '启动服务', exact: true }).click();
		await p.getByText(/运行中 · Mihomo/).waitFor({ timeout: 25000 });
		await p.getByRole('combobox', { name: '测试分组', exact: true }).selectOption('qa-local');
		await p.locator('.cbi-value').filter({ has: p.getByRole('combobox', { name: '测试分组', exact: true }) }).getByRole('button', { name: '切换', exact: true }).click();
		await p.getByText('节点已切换。', { exact: true }).waitFor();
		assert.equal((await rpc('status')).groups.find(x => x.name === '测试分组').now, 'qa-local');
		assert.equal(await p.getByRole('combobox', { name: '测试分组', exact: true }).inputValue(), 'qa-local');
		await p.reload();
		await p.getByRole('combobox', { name: '测试分组', exact: true }).waitFor();
		assert.equal(await p.getByRole('combobox', { name: '测试分组', exact: true }).inputValue(), 'qa-local');
		await p.getByLabel('运行模式', { exact: true }).selectOption('direct');
		await p.getByRole('button', { name: '应用模式', exact: true }).click();
		await p.getByText('运行模式已更新。', { exact: true }).waitFor();
		assert.equal((await rpc('status')).mode, 'direct');
		const content = execFileSync('curl.exe', ['--noproxy', '', '-fsS', '--max-time', '10', '-x', 'http://192.168.1.1:7890', 'http://192.168.1.1/luci-static/resources/view/console/mihomo.js'], { encoding: 'utf8' });
		assert.match(content, /console-mihomo/);
		await p.screenshot({ path: 'tmp/mihomo-running.png', fullPage: true });
		await p.getByRole('button', { name: '停止服务', exact: true }).click();
		await p.getByText('服务已停止，开机启动已关闭。', { exact: true }).waitFor();
		const invalid = await rpc('save', ['config', 'mode'], ['{}', 'rule']); assert.ok(invalid.error);
		assert.equal((await rpc('status')).configured, true);
		await p.setViewportSize({ width: 375, height: 812 });
		await p.evaluate(() => scrollTo(0, 0));
		await p.screenshot({ path: 'tmp/mihomo-mobile.png', fullPage: true });
		assert.equal(await p.evaluate(() => document.documentElement.scrollWidth > innerWidth), false);
		assert.deepEqual(errors, []);
		console.log('Passed: YAML import, save, start, Chinese proxy group selection, mode persistence, LAN HTTP proxy, stop, invalid config preservation, mobile overflow.');
	} finally { await b.close(); }
})().catch(e => { console.error(e); process.exitCode = 1; });
