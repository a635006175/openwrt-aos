// SPDX-License-Identifier: Apache-2.0
import { readfile, open, mkdir, chmod, rename, unlink, stat, popen, rmdir, lsdir } from 'fs';
import { cursor } from 'uci';
import { lanDevices, networkConfig, vpnProxyEnabled, firewall as syncFirewall } from 'console.mihomo-network';
import { targets, classify } from 'console.mihomo-sites';
import { job as delayJob, start as startBatch } from 'console.mihomo-delay';
import { PATH as POLICY_PATH, policy as sourcePolicy, validate as validateSourcePolicy, devices as sourceDevices } from 'console.mihomo-policy';
const root = '/etc/console-mihomo';
function fail(s) { die(s + '\n'); }
function quote(s) { return "'" + replace('' + s, /'/g, "'\\''") + "'"; }
function write(path, value) {
	const f = open(path + '.new', 'w');
	if (!f) fail('无法创建配置文件');
	chmod(path + '.new', 0600);
	const n = f.write(value); f.close();
	if (n == false || !rename(path + '.new', path)) fail('无法保存配置文件');
}
function api(path, method, body, timeout) {
	const secret = trim(readfile(root + '/secret') || '');
	if (!secret) return null;
	let cmd = '/bin/uclient-fetch -q -Y off -T ' + (timeout || 2) + ' -O - --header=' + quote('Authorization: Bearer ' + secret);
	if (method) {
		write(root + '/api-body.json', sprintf('%J', body));
		cmd += ' --method=' + quote(method) + ' --header=' + quote('Content-Type: application/json') + ' --body-file=' + quote(root + '/api-body.json');
	}
	const p = popen(cmd + ' ' + quote('http://127.0.0.1:9097' + path) + ' 2>/dev/null', 'r');
	if (!p) return null;
	const out = p.read('all'), rc = p.close();
	if (method) unlink(root + '/api-body.json');
	if (rc != 0) return null;
	try { return length(out) ? json(out) : { ok: true }; } catch (e) { return null; }
}
function lanAddress() {
	const c = cursor(); c.load('network');
	let ip = c.get('network', 'lan', 'ipaddr');
	if (type(ip) == 'array') ip = ip[0];
	return split(ip || '127.0.0.1', '/')[0];
}
function state() {
	const version = api('/version'), config = api('/configs');
	let saved = {}; try { saved = json(readfile(root + '/config.json') || '{}'); } catch (e) {}
	const p = api('/proxies'), groups = [], nodes = [], ruleGroups = [];
	let delays = {}; try { delays = json(readfile('/var/run/console-mihomo-delay.json') || '{}'); } catch (e) {}
	let siteTests = {}; try { siteTests = json(readfile('/var/run/console-mihomo-sites.json') || '{}'); } catch (e) {}
	for (let name, proxy in (p?.proxies || {})) {
		if (type(proxy.all) == 'array') push(groups, { name, type: proxy.type, now: proxy.now, all: proxy.all });
		else if (index(['DIRECT', 'REJECT', 'REJECT-DROP', 'PASS', 'PASS-RULE', 'COMPATIBLE'], name) < 0)
			push(nodes, { name, type: proxy.type, measurement: delays[name] });
	}
	for (let rule in (saved.rules || [])) {
		const parts = split(rule, ',');
		const target = trim(parts[length(parts) - (parts[length(parts) - 1] == 'no-resolve' ? 2 : 1)] || '');
		if (index(ruleGroups, target) < 0 && length(filter(groups, g => g.name == target))) push(ruleGroups, target);
	}
	return { installed: !!stat('/usr/bin/mihomo'), configured: !!stat(root + '/config.json'), enabled: !!stat(root + '/enabled'),
		running: !!version?.version, version: version?.version || '', mode: config?.mode || saved.mode || 'rule',
		transparent: !!version?.version && !!config?.tun?.enable && !!stat('/var/run/console-mihomo-transparent'),
		sourcePolicy:sourcePolicy(),sourceDevices:sourceDevices(),delayJob:delayJob(),lanDevices: saved.tun?.['include-interface'] || [], vpnProxyEnabled:vpnProxyEnabled(),
		address: saved['bind-address'] || lanAddress(), port: saved['mixed-port'] || 7890, groups, nodes, ruleGroups, siteTests };
}
function normalize(input, mode) {
	if (type(input) != 'object' || type(input) == 'array') fail('请导入 Clash / Mihomo YAML 或 JSON 配置');
	if (index(['rule', 'global', 'direct'], mode) < 0) fail('运行模式无效');
	const out = {};
	for (let key in ['proxies', 'proxy-groups', 'proxy-providers', 'rule-providers', 'rules', 'sub-rules', 'hosts', 'geox-url', 'geodata-mode'])
		if (input[key] != null) out[key] = input[key];
	for (let kind in ['proxy-providers', 'rule-providers']) {
		if (out[kind] != null && type(out[kind]) != 'object') fail('订阅集合格式无效');
		for (let name, provider in (out[kind] || {})) {
			if (!match(name, /^[A-Za-z0-9_-]{1,80}$/) || type(provider) != 'object') fail('订阅集合名称仅支持字母、数字、下划线和连字符');
			provider.path = './providers/' + kind + '-' + name + '.yaml';
		}
	}
	if (!length(out.proxies || []) && !length(keys(out['proxy-providers'] || {}))) fail('配置中没有代理节点或代理订阅集合');
	out['mixed-port'] = 7890; out['allow-lan'] = true; out['bind-address'] = lanAddress();
	out['external-controller'] = '127.0.0.1:9097'; out.secret = trim(readfile(root + '/secret') || '');
	out.mode = mode; out['log-level'] = 'warning'; out['find-process-mode'] = 'off';
	networkConfig(out, lanDevices());
	out.profile = { 'store-selected': true }; out.rules ??= ['MATCH,DIRECT'];
	return out;
}
function locked(fn) {
	mkdir(root, 0700); chmod(root, 0700);
	if (!mkdir('/var/lock/console-mihomo.lock', 0700)) fail('另一个操作正在执行，请稍后重试');
	try { const result = fn(); rmdir('/var/lock/console-mihomo.lock'); return result; }
	catch (e) { rmdir('/var/lock/console-mihomo.lock'); die(e); }
}
function setSourcePolicy(input){return locked(()=>{
	if(stat(root+'/enabled')&&!stat('/var/run/console-mihomo-transparent'))fail('Clash正在准备或尚未就绪，请稍后应用来源策略');
 const previous=readfile(POLICY_PATH),old=sourcePolicy(),next=validateSourcePolicy(input);if(next.revision!=old.revision)fail('来源策略已被其他页面修改，请刷新后重试');next.revision=old.revision+1;
 try{write(POLICY_PATH,sprintf('%J',next));if(stat('/var/run/console-mihomo-transparent'))syncFirewall(true);return {ok:true,policy:next};}
 catch(e){if(previous!=null)write(POLICY_PATH,previous);else unlink(POLICY_PATH);if(stat(root+'/enabled'))try{syncFirewall(true);}catch(ignored){}die(e);}
});}
function setVpnProxy(enabled){
	if(type(enabled)!='bool')fail('OpenVPN代理开关必须是布尔值');
	return locked(()=>{
		const path=root+'/vpn-proxy.json',old=readfile(path),original=readfile(root+'/config.json'),running=!!stat(root+'/enabled');
		try{
			if(original){const config=networkConfig(json(original),lanDevices(),enabled);write(root+'/vpn-candidate.json',sprintf('%J',config));
				if(system('/usr/bin/timeout 5 /usr/bin/mihomo -t -d /etc/console-mihomo -f /etc/console-mihomo/vpn-candidate.json >/tmp/console-mihomo-vpn-check.log 2>&1')!=0)fail('代理配置校验失败，保留原设置');
			}
			write(path,sprintf('%J',{enabled}));if(original&&!rename(root+'/vpn-candidate.json',root+'/config.json'))fail('无法保存代理配置');
			if(running){
				if(system(['/etc/init.d/console-mihomo','restart'])!=0)fail('重启Clash失败');
				let ready=false;for(let i=0;i<8;i++){system(['/bin/sleep','1']);let marker={};try{marker=json(readfile('/var/run/console-mihomo-transparent')||'{}');}catch(e){}if(marker.devices&&((index(marker.devices,'cvpns')>=0)==enabled)){ready=true;break;}}
				if(!ready)fail('Clash未及时就绪，已恢复原设置');
			}
			return {ok:true};
		}catch(e){unlink(root+'/vpn-candidate.json');if(old!=null)write(path,old);else unlink(path);if(original!=null)write(root+'/config.json',original);if(running)system(['/etc/init.d/console-mihomo','restart']);die(e);}
	});
}
function save(text, mode) {
	return locked(() => {
		if (type(text) != 'string' || length(text) > 2097152) fail('配置文件最大支持 2 MB');
		if (stat(root + '/enabled')) fail('请先停止服务，再导入新配置');
		if (!stat(root + '/secret')) {
			const p = popen('head -c 32 /dev/urandom | hexdump -v -e \'1/1 "%02x"\'', 'r');
			const secret = p.read('all'); p.close(); if (length(secret) != 64) fail('生成控制密钥失败'); write(root + '/secret', secret);
		}
		let input; try { input = json(text); } catch (e) { fail('配置解析失败'); }
		const config = normalize(input, mode);
		mkdir(root + '/providers', 0700);
		write(root + '/candidate.json', sprintf('%J', config));
		// Keep validation below LuCI's 20-second request limit. First-time
		// GEOIP/GEOSITE downloads must not block rpcd indefinitely.
		if (system(['/usr/bin/timeout', '10', '/usr/bin/mihomo', '-t', '-d', root, '-f', root + '/candidate.json']) != 0) {
			unlink(root + '/candidate.json'); fail('配置校验失败或超过 10 秒，原配置已保留。请检查节点和规则；若首次使用 GEOIP / GEOSITE 或外部规则，请先准备对应资源后重试。');
		}
		if (stat(root + '/config.json')) write(root + '/config.previous.json', readfile(root + '/config.json'));
		if (!rename(root + '/candidate.json', root + '/config.json')) fail('替换配置失败');
		unlink('/var/run/console-mihomo-delay.json');
		unlink('/var/run/console-mihomo-sites.json');
		return { ok: true };
	});
}
function action(action) {
	return locked(() => {
		if (action == 'start') {
			if (!stat(root + '/config.json')) fail('请先导入有效配置');
			write(root + '/enabled', '1\n');
			unlink('/var/run/console-mihomo-sites.json');
			if (system(['/etc/init.d/console-mihomo', 'enable']) != 0 || system(['/etc/init.d/console-mihomo', 'restart']) != 0) fail('启动服务失败');
		} else if (action == 'stop') {
			unlink(root + '/enabled'); system(['/etc/init.d/console-mihomo', 'disable']);
			if (system(['/etc/init.d/console-mihomo', 'stop']) != 0) fail('停止服务失败');
		} else fail('操作无效');
		return { ok: true };
	});
}
// 清除所有已载入的配置与节点：停止服务 → 撤掉透明代理规则 → 删除配置与订阅缓存。
// 保留 secret（控制密钥）、geoip.metadb（地理库，非用户配置）、source-policy.json、
// vpn-proxy.json 与 providers 目录本身。
// dns.nft / forward.nft 归 console-mihomo-network 管理，这里不写，撤规则靠 network stop。
function clearConfig() {
	return locked(() => {
		const wasRunning = !!stat(root + '/enabled');
		if (wasRunning) {
			unlink(root + '/enabled');
			system(['/etc/init.d/console-mihomo', 'disable']);
			// stop 会经 trap 调用 console-mihomo-network stop 撤掉 nft 规则与策略路由
			system(['/etc/init.d/console-mihomo', 'stop']);
		}
		// 兜底：即使服务未运行过，也清掉可能残留的透明代理防火墙规则
		system(['/usr/libexec/console-mihomo-network', 'stop']);
		unlink('/var/run/console-mihomo-transparent');

		for (let name in ['config.json', 'config.previous.json', 'candidate.json', 'vpn-candidate.json',
			'lan-devices.json', 'api-body.json', 'cache.db']) unlink(root + '/' + name);
		unlink('/var/run/console-mihomo-sites.json');
		unlink('/var/run/console-mihomo-delay.json');

		// 订阅集合缓存：只清 providers 下的 yaml / YAML / yml / YML，保留目录本身
		for (let entry in (lsdir(root + '/providers') || [])) {
			if (match(entry, /\.yaml$|\.yml$|\.YAML$|\.YML$/)) unlink(root + '/providers/' + entry);
		}

		system(['/sbin/fw4', 'reload']);
		return { ok: true, stopped: wasRunning };
	});
}
function encodeName(group) {
	let encoded = '';
	for (let i = 0; i < length(group); i++) {
		const c = substr(group, i, 1);
		encoded += match(c, /^[A-Za-z0-9_.~-]$/) ? c : sprintf('%%%02X', ord(group, i));
	}
	return encoded;
}
function selectProxy(group, name) {
	return locked(() => {
		const s = state(), found = filter(s.groups, g => g.name == group && g.type == 'Selector')[0];
		if (!found || index(found.all, name) < 0) fail('代理组或节点不存在');
		const path = '/proxies/' + encodeName(group);
		if (!api(path, 'PUT', { name })) fail('切换节点失败');
		if (api(path)?.now != name) fail('内核尚未确认节点切换，请刷新后重试');
		unlink('/var/run/console-mihomo-sites.json');
		return { ok: true, selected: name };
	});
}
function startDelayBatch(){return locked(()=>{const s=state();if(!s.running)fail('请先启动Clash服务');return startBatch(map(s.nodes,n=>n.name));});}
function measureDelay(name) {
	return locked(() => {
		if(delayJob()?.running)fail('后台批量测速正在进行，请等待完成');
		const p = api('/proxies/' + encodeName(name));
		if (!p || type(p.all) == 'array' || index(['DIRECT', 'REJECT', 'REJECT-DROP', 'PASS', 'PASS-RULE', 'COMPATIBLE'], name) >= 0) fail('请选择实际代理节点进行测速');
		const result = api('/proxies/' + encodeName(name) + '/delay?timeout=4000&expected=204&url=https%3A%2F%2Fwww.gstatic.com%2Fgenerate_204', null, null, 6);
		const measurement = { testedAt: time(), delay: type(result?.delay) == 'int' && result.delay >= 0 ? result.delay : null };
		let delays = {}; try { delays = json(readfile('/var/run/console-mihomo-delay.json') || '{}'); } catch (e) {}
		delays[name] = measurement; write('/var/run/console-mihomo-delay.json', sprintf('%J', delays));
		return { ok: true, name, measurement };
	});
}
function setMode(mode) {
	return locked(() => {
		if (index(['rule', 'global', 'direct'], mode) < 0) fail('运行模式无效');
		const config = json(readfile(root + '/config.json')); config.mode = mode;
		// uclient-fetch supports PUT, but not PATCH, on the target firmware.
		if (!api('/configs?force=true', 'PUT', { payload: sprintf('%J', config) })) fail('更新运行模式失败，请确认内核正在运行');
		write(root + '/config.json', sprintf('%J', config)); unlink('/var/run/console-mihomo-sites.json'); return { ok: true };
	});
}
function testSite(id) {
	return locked(() => {
		const target = filter(targets, t => t.id == id)[0];
		if (!target) fail('不支持的测试站点');
		const s = state(); if (!s.running) fail('请先启动 Clash 服务');
		if (!stat('/usr/bin/curl')) fail('网站测试需要安装 curl');
		// Always use the local mixed proxy, so current mode and routing rules
		// apply even though root-originated traffic bypasses transparent TUN.
		const command = 'timeout 10 /usr/bin/curl --head --location --max-redirs 3 --connect-timeout 4 --max-time 8 ' +
			'--noproxy ' + quote('') + ' --proxy ' + quote('http://' + s.address + ':' + s.port) +
			' --proto =https --proto-redir =https --user-agent ' + quote('Mozilla/5.0 (compatible; OpenWrt-Console-Test/1.0)') +
			' --silent --output /dev/null --write-out ' + quote('{"code":"%{http_code}","ttfb":%{time_starttransfer},"total":%{time_total}}') + ' ' + quote(target.url) + ' 2>/dev/null';
		const p = popen(command, 'r'); if (!p) fail('无法启动网站测试');
		const text = p.read('all'), exitCode = p.close();
		let response = {}; try { response = json(text); } catch (e) {}
		const code = int(response.code || 0), status = classify(code, exitCode);
		const result = { id, status, code, delay: code && response.ttfb >= 0 ? int(response.ttfb * 1000) : null,
			elapsed: response.total != null ? int(response.total * 1000) : null, testedAt: time(), mode: s.mode,
			selection: map(filter(s.groups, g => g.type == 'Selector'), g => ({ group: g.name, node: g.now })) };
		let saved = {}; try { saved = json(readfile('/var/run/console-mihomo-sites.json') || '{}'); } catch (e) {}
		saved[id] = result; write('/var/run/console-mihomo-sites.json', sprintf('%J', saved));
		return { ok: true, result };
	});
}
function fetchConfig(url) {
	if (type(url) != 'string' || length(url) > 4096 || !match(url, /^https?:\/\/[^/?#]+/)) fail('请输入有效的 HTTP 或 HTTPS 配置链接');
	for (let i = 0; i < length(url); i++) if (ord(url, i) <= 32 || ord(url, i) == 127) fail('请输入有效的 HTTP 或 HTTPS 配置链接');
	// Bound both response size and total download time. Never log subscription URLs.
	const command = 'umask 077; f=$(mktemp /tmp/console-mihomo-download.XXXXXX) || exit 1; ' +
		'trap \'rm -f "$f"\' EXIT HUP INT TERM; ' +
		'(ulimit -f 4097; timeout 12 /bin/uclient-fetch -q -Y off -T 10 -U ' + quote('Clash.Meta/console-mihomo') +
		' -O "$f" ' + quote(url) + ') 2>/dev/null; rc=$?; head -c 2097153 "$f"; exit "$rc"';
	const p = popen(command, 'r');
	if (!p) fail('无法开始下载配置');
	const text = p.read('all'), rc = p.close();
	if (length(text) > 2097152) fail('配置文件最大支持 2 MB');
	if (rc != 0 || !length(text)) fail('路由器下载失败或超时，请尝试浏览器下载，或在电脑下载后上传文件');
	return { ok: true, config: text };
}
export { state, save, action, selectProxy, setMode, normalize, fetchConfig, measureDelay, encodeName, testSite, setVpnProxy, startDelayBatch, setSourcePolicy, clearConfig };
