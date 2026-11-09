// SPDX-License-Identifier: Apache-2.0
'use strict';
'require view';
'require ui';
'require console.flow as flow';

// 智能流控：为在线内网终端按 IP 公平限速，并限制 LAN 总速率。
// 本机无 tc，全部限速都是 nftables 丢包限速。

return flow.createView({
	title: '智能流控',
	intro: '为内网终端自动生成每 IP 限速规则，避免单台设备占满带宽。终端列表来自 DHCP 租约与主机信息，最多处理 maxDevices 台。',
	requiresLines: false,
	footnote: '智能流控的终端集合在生效时确定；新增终端需要重新应用一次才会被纳入。例外地址内的终端不受每 IP 限速约束。',

	build(page) {
		const draft = page.draft;
		const smart = draft.smart;
		const output = [flow.shapingNote(page)];
		const enabled = E('input', { type: 'checkbox', checked: smart.enabled || null, change: event => { smart.enabled = event.target.checked; page.markDirty(); page.paintStatus(); } });
		const perIpUp = flow.mbpsInput(smart.perIpUpKbps, '每终端上行，0 表示不限');
		perIpUp.addEventListener('input', () => { smart.perIpUpKbps = flow.kbpsOf(perIpUp); page.markDirty(); });
		const perIpDown = flow.mbpsInput(smart.perIpDownKbps, '每终端下行，0 表示不限');
		perIpDown.addEventListener('input', () => { smart.perIpDownKbps = flow.kbpsOf(perIpDown); page.markDirty(); });
		const totalUp = flow.mbpsInput(smart.totalUpKbps, '总体上行，0 表示不限');
		totalUp.addEventListener('input', () => { smart.totalUpKbps = flow.kbpsOf(totalUp); page.markDirty(); });
		const totalDown = flow.mbpsInput(smart.totalDownKbps, '总体下行，0 表示不限');
		totalDown.addEventListener('input', () => { smart.totalDownKbps = flow.kbpsOf(totalDown); page.markDirty(); });
		const maxDevices = E('input', { type: 'number', min: 1, max: 1024, value: smart.maxDevices || 256 });
		maxDevices.addEventListener('input', () => { smart.maxDevices = Math.max(1, Math.min(1024, Number(maxDevices.value) || 256)); page.markDirty(); });

		output.push(flow.panel('每终端限速', [
			flow.field('启用智能流控', E('label', { class: 'flow-switch' }, [ enabled, '为在线内网终端逐 IP 生成限速规则' ]),
				'关闭时不会生成任何每终端规则；总速率限制也同时失效。'),
			flow.field('每终端上行', E('div', { class: 'flow-inline' }, [ perIpUp, flow.node('span', 'flow-note', 'Mbps') ]), '每台终端单独的放行速率，超出部分直接丢弃。'),
			flow.field('每终端下行', E('div', { class: 'flow-inline' }, [ perIpDown, flow.node('span', 'flow-note', 'Mbps') ]), '每台终端单独的下载放行速率。'),
			flow.field('LAN 总上行', E('div', { class: 'flow-inline' }, [ totalUp, flow.node('span', 'flow-note', 'Mbps') ]), '全部内网终端的合计上行上限，填 0 表示不限制。'),
			flow.field('LAN 总下行', E('div', { class: 'flow-inline' }, [ totalDown, flow.node('span', 'flow-note', 'Mbps') ]), '全部内网终端的合计下行上限，填 0 表示不限制。'),
			flow.field('最多终端数', maxDevices, '1 到 1024。数值越大规则越多，可能影响转发性能；超过 256 时页面会提示。')
		]));

		const exempt = E('textarea', { rows: 4, placeholder: '每行一个 IPv4 地址或 CIDR，例如\n192.168.1.1\n192.168.1.0/28' });
		exempt.value = (smart.exempt || []).join('\n');
		const syncExempt = () => {
			smart.exempt = Array.from(new Set(exempt.value.split(/[\s,;]+/).map(item => item.trim()).filter(Boolean))).slice(0, 32);
			page.markDirty();
		};
		exempt.addEventListener('change', syncExempt);
		const chips = E('div', { class: 'flow-chips' });
		const paintChips = () => chips.replaceChildren(...(smart.exempt || []).map((value, index) => E('span', { class: 'flow-chip' }, [
			value, E('button', { type: 'button', 'aria-label': '移除例外 ' + value, click: () => { smart.exempt.splice(index, 1); exempt.value = smart.exempt.join('\n'); page.markDirty(); paintChips(); } }, '×')
		])));
		paintChips();
		const addButton = page.button('加入例外', () => { syncExempt(); paintChips(); }, 'cbi-button-add');
		output.push(flow.panel('例外地址', [
			flow.field('不限速地址', E('div', { class: 'flow-picker' }, [ exempt ]),
				'IPv4 地址或 CIDR，最多 32 项。适合排除 NAS、服务器等需要全速的设备。'),
			flow.field('已加入', E('div', { class: 'flow-picker' }, [ chips, E('div', { class: 'flow-inline' }, [ addButton ]) ]))
		]));

		const devices = page.devices();
		page.deviceBox = E('div', { class: 'flow-devices' });
		const paintDevices = () => {
			if (!devices.length) {
				page.deviceBox.replaceChildren(flow.node('p', 'flow-note', '暂未发现内网终端。终端来自 DHCP 租约与主机信息，需要在路由器上正常获取地址。'));
				return;
			}
			page.deviceBox.replaceChildren(...devices.slice(0, 64).map(device => E('div', { class: 'flow-device' }, [
				E('div', { class: 'flow-device-name' }, [
					flow.node('strong', '', device.hostname || device.mac || '未命名设备'),
					E('small', {}, [device.ip, device.mac ? ' · ' + device.mac : ''].join(''))
				]),
				E('div', { class: 'flow-inline' }, [
					device.up != null || device.down != null ? flow.node('span', 'flow-note', '上 ' + flow.bytes(device.up) + '/s · 下 ' + flow.bytes(device.down) + '/s') : flow.node('span', 'flow-note', '无流量数据'),
					page.button('加入例外', () => {
						if (!(smart.exempt || []).includes(device.ip) && (smart.exempt || []).length < 32) {
							smart.exempt = (smart.exempt || []).concat(device.ip);
							exempt.value = smart.exempt.join('\n');
							page.markDirty();
							paintChips();
						}
					})
				])
			])));
		};
		paintDevices();
		output.push(flow.panel('在线终端', [
			flow.node('p', 'flow-note', '列出当前识别到的内网终端，可直接加入例外。取不到的流量字段显示为「无流量数据」，不按 0 处理。'),
			page.deviceBox
		]));

		page.paintSmart = () => { paintChips(); };
		return output;
	},

	paint() { if (this.paintSmart) this.paintSmart(); }
});
