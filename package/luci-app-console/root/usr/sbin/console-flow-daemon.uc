// SPDX-License-Identifier: Apache-2.0
// console-flow 后台守护：每 60 秒巡检一次，负责三件事
//   1) 确认窗口兜底回滚 —— 正常情况下由 apply 时 fork 的延迟进程执行，这里再兜一层，
//      防止计时进程被 kill 掉后配置永久停在“待确认”；
//   2) 线路 / 拓扑变化侦测 —— 线路上下线、DHCP 续租后重建 nft 与路由表
//      （多线负载的“故障切换”就靠这一层：只剩一条可用线路时规则自动收敛）；
//   3) 域名重解析 —— dnsmasq 未编入 nftset，只能自己 nslookup 后写 interval 集合，
//      实际频率由每条规则的 ttl 决定（refreshDomains 内部跳过未到期规则）。
//
// 只有签名真的变化时才重建 nft：重建会 destroy 整张表，过于频繁会打断已有连接。
import * as uloop from 'uloop';
import { expirePending, refresh, refreshDomains, state } from 'console.flow-engine';
import { pendingState, writeJson } from 'console.flow-util';

const STATUS = '/var/run/console-flow-daemon.json';
const INTERVAL = 60000;

let lastSignature = '', lastDomain = 0, lastError = null;

function writeStatus(snapshot) {
	writeJson(STATUS, {
		time: time(),
		error: lastError,
		enabled: !!(snapshot && snapshot.config && snapshot.config.enabled === true),
		lines: snapshot ? map(snapshot.lines, line => ({
			id: line.id, name: line.name, up: line.up,
			degraded: line.degraded, gateway: line.gateway
		})) : [],
		pending: snapshot ? snapshot.pending : null
	});
}

function tick() {
	const now = time();
	try {
		// 1) 兜底回滚
		const pending = pendingState();
		if (pending && pending.secondsLeft <= 0) expirePending();

		const snapshot = state();
		const model = snapshot.config;
		if (!model || model.enabled !== true) {
			// 未启用时什么都不用做，但仍把状态写出去，页面据此显示“未启用”。
			lastError = null;
			writeStatus(snapshot);
			return;
		}
		// 确认窗口内不动内核，避免把用户正在确认的配置覆盖掉。
		if (snapshot.pending) { writeStatus(snapshot); return; }

		// 2) 拓扑变化 → 重建规则
		const signature = sprintf('%J', {
			lines: map(snapshot.lines, line => line.id + ':' + line.up + ':' + line.degraded + ':' + line.gateway),
			lan: snapshot.topology.lan,
			wan: snapshot.topology.wan,
			devices: length(snapshot.devices)
		});
		if (signature != lastSignature) {
			// 首次记录签名时不重建：开机恢复已经建过一遍了。
			if (length(lastSignature)) refresh();
			lastSignature = signature;
		}

		// 3) 域名重解析（ttl 未到期的规则在 refreshDomains 内部被跳过）
		if (now - lastDomain >= 60) {
			refreshDomains(false);
			lastDomain = now;
		}
		writeStatus(snapshot);
		lastError = null;
	} catch (e) {
		lastError = (e && e.message) ? e.message : '流控分流巡检失败';
		warn(lastError + '\n');
	}
}

uloop.init();
tick();
uloop.timer(INTERVAL, tick);
uloop.run();
