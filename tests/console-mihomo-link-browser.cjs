// SPDX-License-Identifier: Apache-2.0
// Run only against an unconfigured Mihomo test router; requires Playwright in NODE_PATH.
const { chromium } = require('playwright');
const assert = require('node:assert/strict');
const { execFileSync } = require('node:child_process');
const { writeFileSync } = require('node:fs');
const ssh = command => execFileSync('ssh', ['-o', 'BatchMode=yes', 'root@192.168.1.1', command], { encoding: 'utf8' });
const fixture = '/www/console-mihomo-link-qa.yaml';
const url = 'http://192.168.1.1/console-mihomo-link-qa.yaml';
(async () => {
	assert.equal(JSON.parse(ssh('ubus call console-mihomo status')).configured, false, 'requires no existing config');
	writeFileSync('tmp/mihomo-link-qa.yaml', 'proxies:\n  - name: link-qa\n    type: socks5\n    server: 127.0.0.1\n    port: 9\nproxy-groups:\n  - name: link-select\n    type: select\n    proxies: [DIRECT, link-qa]\nrules:\n  - MATCH,DIRECT\n');
	execFileSync('scp', ['-q', '-O', 'tmp/mihomo-link-qa.yaml', 'root@192.168.1.1:' + fixture]);
	ssh('head -c 2097153 /dev/zero > /www/console-mihomo-link-qa.large');
	const b = await chromium.launch({ headless: true, executablePath: process.env.CONSOLE_BROWSER_EXECUTABLE || 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe' });
	const p = await b.newPage({ viewport: { width: 1440, height: 1100 } });
	const errors = []; p.on('pageerror', e => errors.push(e.message));
	try {
		await p.goto('http://192.168.1.1/cgi-bin/luci/admin/vpn/console-mihomo');
		if (await p.locator('[name=luci_username]').count()) { await p.locator('[name=luci_username]').fill('root'); await p.getByRole('button', { name: '登录' }).click(); }
		await p.getByRole('heading', { name: 'Clash / Mihomo', exact: true }).waitFor();
		const rpc = async value => p.evaluate(async url => { const r = await L.require('rpc'); return r.declare({ object: 'console-mihomo', method: 'fetch_config', params: ['url'], reject: true })(url); }, value);
		for (const invalid of ['file:///etc/passwd', 'ftp://example.com/sub', 'https://example.com/\nignored']) assert.ok((await rpc(invalid)).error);
		assert.match((await rpc('http://192.168.1.1/console-mihomo-link-qa.large')).error, /2 MB/);
		await p.getByLabel('配置链接', { exact: true }).fill(url + '?token=test%27quoted');
		await p.getByRole('button', { name: '从链接导入', exact: true }).click();
		await p.getByText('链接配置已下载、校验并保存，可启动服务。', { exact: true }).waitFor();
		assert.equal(await p.getByLabel('配置链接', { exact: true }).inputValue(), '');
		const hash = ssh('sha256sum /etc/console-mihomo/config.json').split(' ')[0];
		await p.getByLabel('配置链接', { exact: true }).fill(url + '.missing');
		await p.getByRole('button', { name: '从链接导入', exact: true }).click();
		await p.getByText(/路由器下载失败或超时/).first().waitFor();
		assert.equal(ssh('sha256sum /etc/console-mihomo/config.json').split(' ')[0], hash);
		await p.getByLabel('下载方式', { exact: true }).selectOption('browser');
		await p.getByLabel('配置链接', { exact: true }).fill(url);
		await p.getByRole('button', { name: '从链接导入', exact: true }).click();
		await p.getByText('链接配置已下载、校验并保存，可启动服务。', { exact: true }).waitFor();
		assert.equal(ssh('sha256sum /etc/console-mihomo/config.json').split(' ')[0], hash);
		await p.screenshot({ path: 'tmp/mihomo-link-desktop.png', fullPage: true });
		await p.setViewportSize({ width: 375, height: 812 }); await p.evaluate(() => scrollTo(0, 0));
		assert.equal(await p.evaluate(() => document.documentElement.scrollWidth > innerWidth), false);
		await p.screenshot({ path: 'tmp/mihomo-link-mobile.png', fullPage: true });
		assert.deepEqual(errors, []);
		console.log('Passed: router link download and import, browser download and import, URL validation, 2 MB limit, failed download preserves config, URL cleared, mobile layout.');
	} finally {
		await b.close();
		ssh('rm -f /www/console-mihomo-link-qa.yaml /www/console-mihomo-link-qa.large /etc/console-mihomo/config.json /etc/console-mihomo/config.previous.json /etc/console-mihomo/candidate.json');
	}
})().catch(e => { console.error(e); process.exitCode = 1; });
