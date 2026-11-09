// SPDX-License-Identifier: Apache-2.0
import { admission } from 'console.vpn-sessions';
import { lsdir,unlink,rmdir } from 'fs';
function check(v,m){if(!v)die(m+'\n');}
const root='/tmp/console-vpn-sessions-test-'+time(),a={username:'shared',enabled:true};
for(let i=0;i<99;i++)check(admission(root,'1',a,'127.0.0.1',''+(10000+i),false),'admit client '+i);
check(!admission(root,'1',a,'127.0.0.1','11000',false),'100th client rejected');
check(admission(root,'1',a,'127.0.0.1','10000',true),'disconnect released');check(admission(root,'1',a,'127.0.0.1','11000',false),'replacement admitted');
check(admission(root,'2',a,'127.0.0.1','10000',false),'new daemon ignores old reservations');
const fixed={username:'fixed',enabled:true,address:'10.8.0.10'};check(admission(root,'1',fixed,'127.0.0.1','12000',false),'fixed first allowed');check(!admission(root,'1',fixed,'127.0.0.1','12001',false),'fixed duplicate rejected');
check(!admission(root,'1',{username:'disabled',enabled:false},'127.0.0.1','12000',false),'disabled rejected');
for(let pid in lsdir(root)){for(let file in lsdir(root+'/'+pid))unlink(root+'/'+pid+'/'+file);rmdir(root+'/'+pid);}rmdir(root);
print('PASS 99 sessions, 100th rejection, release/reconnect, daemon restart, fixed-IP protection and disabled account\n');
