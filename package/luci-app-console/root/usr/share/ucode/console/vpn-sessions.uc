// SPDX-License-Identifier: Apache-2.0
import { mkdir,lsdir,stat,unlink } from 'fs';
import { writeText } from 'console.security';
// Synchronous OpenVPN connect/disconnect hooks are serialized by its event loop.
// Scope records by daemon PID so a crashed daemon cannot leave active reservations.
function admission(root,pid,account,ip,port,disconnect){
	if(!match(''+pid,/^[1-9][0-9]*$/)||!match(account.username||'',/^[A-Za-z0-9_-]{1,48}$/)||!match(ip||'',/^[0-9a-fA-F:.]+$/)||!match(''+port,/^[0-9]{1,5}$/)||+port<1||+port>65535)return false;
	mkdir(root,0700);const dir=root+'/'+pid;mkdir(dir,0700);
	const prefix=account.username+'__',file=dir+'/'+prefix+replace(ip,/:/g,'_')+'_'+port;
	if(disconnect){unlink(file);return true;}
	if(!account.enabled)return false;if(stat(file))return true;
	const limit=account.address||account.remoteSubnet?1:99;
	if(length(filter(lsdir(dir)||[],name=>substr(name,0,length(prefix))==prefix))>=limit)return false;
	writeText(file,''+time());return true;
}
export { admission };
