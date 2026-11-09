// SPDX-License-Identifier: Apache-2.0
'use strict';
'require baseclass';
'require network';
'require uci';
'require poll';
'require ui';

function bytes(value) {
	if (!Number.isFinite(value)) return '—';
	const units = ['B', 'KB', 'MB', 'GB', 'TB']; let i = 0;
	while (value >= 1024 && i < units.length - 1) { value /= 1024; i++; }
	return value.toFixed(i ? 2 : 0) + ' ' + units[i];
}
function label(tag, cls, text) { return E(tag, { class: cls }, text); }
function field(name, value) { return E('div', { class: 'cn-field' }, [label('dt', '', name), label('dd', '', value || '—')]); }

return baseclass.extend({
	start() {
		if (this.tick) return;
		this.tick = async () => {
			const section = document.getElementById('cbi-network-interface');
			if (!section || document.hidden || this.busy) return;
			this.busy = true;
			try {
				await uci.load('firewall');
				const [nets, devices] = await Promise.all([network.getNetworks(), network.getDevices()]);
				if (!section.querySelector('.cn-interfaces')) this.mount(section);
				this.update(section, nets, devices);
			} catch (error) {
				// Keep native controls accessible if the enhanced status view fails.
				section.classList.remove('cn-native');
				const root = section.querySelector('.cn-interfaces');
				if (root) root.remove();
			} finally { this.busy = false; }
		};
		poll.add(this.tick, 5);
		this.tick();
		// 容器可能尚未由 cbi 生成；用短间隔补几帧，避免首屏等满一个 poll 周期。
		let attempts = 0;
		const kick = () => {
			if (document.getElementById('cbi-network-interface')) { this.tick(); return; }
			if (++attempts < 80) window.setTimeout(kick, 50);
		};
		if (!document.getElementById('cbi-network-interface')) window.setTimeout(kick, 50);
	},

	mount(section) {
		section.classList.add('cn-native');
		const root = E('div', { class: 'cn-interfaces' });
		section.prepend(root);
	},

	role(net) {
		for (const zone of uci.sections('firewall', 'zone')) {
			const names = Array.isArray(zone.network) ? zone.network : String(zone.network || '').split(/\s+/);
			if (names.includes(net.getName()) && ['wan', 'lan'].includes(zone.name)) return zone.name.toUpperCase();
		}
		return '其他';
	},

	action(section, name, selector) {
		const row = Array.from(section.querySelectorAll('tr[data-sid]')).find(row => row.dataset.sid === name);
		return row && row.querySelector(selector);
	},

	update(section, networks, devices) {
		const root = section.querySelector('.cn-interfaces');
		const nets = networks.filter(net => net.getName() !== 'loopback' && this.action(section, net.getName(), '.cbi-button-edit'));
		if (!nets.some(net => net.getName() === this.selected)) this.selected = nets[0] && nets[0].getName();
		const zone = role => nets.filter(net => this.role(net) === role);
		const used = new Set();
		nets.forEach(net => {
			const dev = net.getDevice();
			if (dev) { used.add(dev.getName()); (dev.getPorts() || []).forEach(port => used.add(port.getName())); }
		});
		const free = devices.filter(dev => dev.getType() === 'ethernet' && !used.has(dev.getName()) && !/[.@]/.test(dev.getName()));
		const choose = net => { this.selected = net.getName(); this.update(section, networks, devices); };
		const summary = E('div', { class: 'cn-summary' }, ['WAN', 'LAN'].map(role => E('div', {}, [label('span', 'cn-summary-label', role === 'WAN' ? '外网状态' : '内网状态'), label('strong', '', String(zone(role).filter(net => net.isUp()).length)), label('span', '', '/ ' + zone(role).length + ' 个接口已连接')])));
		const portGroup = (title, list) => E('section', { class: 'cn-port-group' }, [label('h4', '', title + ' (' + list.length + ')'), E('div', { class: 'cn-port-list' }, list.map(net => {
			const dev = net.getDevice();
			return E('button', { type: 'button', class: 'cn-port' + (net.getName() === this.selected ? ' selected' : ''), 'aria-pressed': String(net.getName() === this.selected), click: () => choose(net) }, [
				E('img', { src: L.resource('icons/' + (dev ? dev.getType() : 'ethernet') + (net.isUp() ? '' : '_disabled') + '.svg'), alt: '' }),
				label('strong', '', net.getName()), label('span', 'cn-status ' + (net.isUp() ? 'up' : 'down'), net.isUp() ? '已连接' : '未连接'), label('small', '', dev ? dev.getName() : '未绑定设备')
			]);
		}))]);
		const ports = E('div', { class: 'cn-port-groups' }, [portGroup('外网接口', zone('WAN')), portGroup('内网接口', zone('LAN'))]);
		if (zone('其他').length) ports.append(portGroup('其他接口', zone('其他')));
		const create = section.querySelector('.cbi-section-create .cbi-button');
		const heading = E('div', { class: 'cn-heading' }, [E('div', {}, [label('h2', '', '内外网设置'), label('p', '', '选择接口查看连接信息，配置接入方式与网卡绑定。')])]);
		if (create) heading.append(E('button', { type: 'button', class: 'cbi-button cbi-button-add', disabled: create.disabled || null, click: () => create.click() }, '新增接口'));
		const content = [heading, summary, E('section', { class: 'cn-panel' }, [label('h3', '', '接口状态'), ports])];
		if (free.length) content.push(E('section', { class: 'cn-panel cn-free' }, [label('h3', '', '未分配网卡 (' + free.length + ')'), label('p', '', free.map(dev => dev.getName() + ' · ' + (dev.getMAC() || '—')).join('　/　')), label('p', 'cn-help', '可通过“新增接口”选择网卡；设备与 VLAN 配置位于上方“设备”标签页。')]));
		const selected = nets.find(net => net.getName() === this.selected);
		if (selected) {
			const dev = selected.getL3Device() || selected.getDevice();
			const role = this.role(selected), name = selected.getName();
			const protocols = { static: '静态 IP（固定地址）', dhcp: 'DHCP（动态获取）', pppoe: 'PPPoE（宽带拨号）', dhcpv6: 'DHCPv6（动态获取）', none: '不配置协议' };
			const actions = E('div', { class: 'cn-actions' });
			for (const [selector, title, cls] of [['.cbi-button-edit', '编辑配置', 'cbi-button-edit'], ['.reconnect', '重新连接', 'cbi-button-neutral'], ['.down', '停止接口', 'cbi-button-neutral'], ['.cbi-button-remove', '删除接口', 'cbi-button-remove']]) {
				const target = this.action(section, name, selector);
				if (target) actions.append(E('button', { type: 'button', class: 'cbi-button ' + cls, disabled: target.disabled || null, click: () => target.click() }, title));
			}
			content.push(E('section', { class: 'cn-panel' }, [E('div', { class: 'cn-detail-heading' }, [label('h3', '', (role === 'WAN' ? '外网设置' : role === 'LAN' ? '内网设置' : '接口设置') + ' · ' + name), label('span', 'cn-status ' + (selected.isUp() ? 'up' : 'down'), selected.isUp() ? '已连接' : '未连接')]),
				E('dl', { class: 'cn-fields' }, [field('网卡绑定', selected.getDevice() ? selected.getDevice().getName() : null), field('接入方式', protocols[selected.getProtocol()] || selected.getI18n()), field('IP 地址 / 子网掩码', [selected.getIPAddr(), selected.getNetmask()].filter(Boolean).join(' / ')), field('默认网关', selected.getGatewayAddr() || selected.getGateway6Addr()), field('DNS 服务器', selected.getDNSAddrs().concat(selected.getDNS6Addrs()).join(' / ')), field('IPv6 地址', selected.getIP6Addrs().join(' / ')), field('MAC 地址', dev && dev.getMAC()), field('链路速率', dev && dev.getSpeed() > 0 ? dev.getSpeed() + ' Mbps' : null), field('累计接收 / 发送', dev ? bytes(dev.getRXBytes()) + ' / ' + bytes(dev.getTXBytes()) : null)]),
				actions, label('p', 'cn-help', '编辑配置中可设置接入方式、IP、DNS、网卡绑定、DHCP 和高级参数。配置暂存后，点击页面底部“保存并应用”生效。')
			]));
		}
		// Preserve focused controls while polling; selection changes render immediately.
		if (root.contains(document.activeElement) && this.renderedSelection === this.selected) return;
		root.replaceChildren(...content);
		this.renderedSelection = this.selected;
	}
});
