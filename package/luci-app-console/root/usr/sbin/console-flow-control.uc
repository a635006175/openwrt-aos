// SPDX-License-Identifier: Apache-2.0
// console-flow 的服务端控制入口（init.d、计时器、热插拔都用它）。
//   init          开机恢复：重建表/规则/路由；有未确认的 pending 则先回滚
//   expire        确认窗口到期后自动回滚（由 apply 时 fork 的延迟进程调用）
//   refresh       拓扑变化后重建规则（线路上下线、DHCP 续租）
//   domains       重新解析域名并重建集合
//   stop          停机清理：删表 + 精确清理自己的 ip rule / 路由表
import { restore, expirePending, refresh, refreshDomains, rollbackPolicy, state } from 'console.flow-engine';
import { deleteTable, cleanupIp } from 'console.flow-util';

const action = ARGV[0] || 'init';

if (action == 'init') restore();
else if (action == 'expire') expirePending();
else if (action == 'refresh') refresh();
else if (action == 'domains') {
	const result = refreshDomains(false);
	if (!result) warn('域名解析刷新被跳过\n');
}
else if (action == 'rollback') rollbackPolicy(false);
else if (action == 'stop') { deleteTable(); cleanupIp(); }
else if (action == 'show') print(sprintf('%J\n', state()), '\n');
else warn('未知的 console-flow 操作：' + action + '\n');
