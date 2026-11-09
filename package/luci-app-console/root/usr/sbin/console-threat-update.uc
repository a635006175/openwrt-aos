// SPDX-License-Identifier: Apache-2.0
// 威胁情报黑名单刷新：由 uloop 定时或 CLI 触发。
import { forceRefresh, threatConfig } from 'console.situational';
const cfg = threatConfig();
forceRefresh();
