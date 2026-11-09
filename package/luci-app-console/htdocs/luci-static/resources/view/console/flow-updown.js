// SPDX-License-Identifier: Apache-2.0
'use strict';
'require view';
'require ui';
'require console.flow as flow';

// 上下行分离：上行（内网→外网新建连接）与下行（外网→内网）分别指定线路，并可各自限速。

function lineWithEmpty(page, current) {
	const values = [['', '不指定（保持原线路）']];
	for (const line of page.draft.lines || [])
		values.push([line.id, line.name + '（' + line.interface + '）' + (line.enabled ? '' : ' · 已停用')]);
	const select = flow.option(values, current || '');
	if (current && !values.some(([value]) => value === current))
		select.append(E('option', { value: current, selected: true }, current + '（已移除）'));
	return select;
}

return flow.createView({
	title: '上下行分离',
	intro: '把上行（内网发起的外网连接）与下行（外网发起、回程到内网）分别绑定到不同线路，也可以只对其中一个方向限速。',
	footnote: '上下行分离按连接方向打标，回程包沿用同一线路；两个方向都不指定时本页不产生任何规则。限速为丢包式，不做队列整形。',

	build(page) {
		const draft = page.draft;
		const updown = draft.updown;
		const output = [flow.lineGuide(page), flow.shapingNote(page)];
		const enabled = E('input', { type: 'checkbox', checked: updown.enabled || null, change: event => { updown.enabled = event.target.checked; page.markDirty(); page.paintStatus(); } });
		const upload = lineWithEmpty(page, updown.upload);
		upload.addEventListener('change', () => { updown.upload = upload.value; page.markDirty(); });
		const download = lineWithEmpty(page, updown.download);
		download.addEventListener('change', () => { updown.download = download.value; page.markDirty(); });
		const upRate = flow.mbpsInput(updown.uploadKbps, '上行限速，0 表示不限速');
		upRate.addEventListener('input', () => { updown.uploadKbps = flow.kbpsOf(upRate); page.markDirty(); });
		const downRate = flow.mbpsInput(updown.downloadKbps, '下行限速，0 表示不限速');
		downRate.addEventListener('input', () => { updown.downloadKbps = flow.kbpsOf(downRate); page.markDirty(); });

		output.push(flow.panel('上下行分离', [
			flow.field('启用', E('label', { class: 'flow-switch' }, [ enabled, '保存后按下方两个方向分别打标' ])),
			flow.field('上行线路', upload, '内网主动发起的外网连接使用该线路；不指定时沿用分流结果。'),
			flow.field('上行限速', E('div', { class: 'flow-inline' }, [ upRate, flow.node('span', 'flow-note', 'Mbps') ]), '超过速率的报文直接丢弃，单位是比特率。'),
			flow.field('下行线路', download, '外网返回内网的下行流量使用该线路；下载型业务通常指定到带宽更大的线路。'),
			flow.field('下行限速', E('div', { class: 'flow-inline' }, [ downRate, flow.node('span', 'flow-note', 'Mbps') ]), '超过速率的报文直接丢弃，单位是比特率。')
		]));

		const summary = E('div');
		const paintSummary = () => summary.replaceChildren(
			flow.node('p', 'flow-note', '上行：' + (updown.upload ? flow.lineLabel(draft, updown.upload) : '不指定') + ' · ' + flow.formatKbps(updown.uploadKbps)),
			flow.node('p', 'flow-note', '下行：' + (updown.download ? flow.lineLabel(draft, updown.download) : '不指定') + ' · ' + flow.formatKbps(updown.downloadKbps)),
			flow.node('p', 'flow-note', updown.enabled ? '本页规则将随「保存并应用」立即生效。' : '本页未启用，保存后不会产生任何规则。'));
		paintSummary();
		output.push(flow.panel('当前草稿', [summary]));

		page.paintSummary = paintSummary;
		return output;
	},

	paint() { if (this.paintSummary) this.paintSummary(); }
});
