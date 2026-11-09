// SPDX-License-Identifier: Apache-2.0
import { setSourcePolicy,state } from 'console.mihomo';
import { policy } from 'console.mihomo-policy';
const old=policy(),mode=ARGV[0]||'all';
print(sprintf('%J',setSourcePolicy({mode,addresses:mode=='all'||mode=='none'?[]:['192.168.1.5','10.8.0.2'],revision:old.revision})));
if(!state().transparent)die('Proxy not ready\n');
