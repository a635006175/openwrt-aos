// SPDX-License-Identifier: Apache-2.0
import { mkdir,readfile,stat,popen,unlink,rmdir,lsdir } from 'fs';
import { readJson,writeJson,command } from 'console.security';
const ROOT='/var/run/console-mihomo-batch',META=ROOT+'/job.json',CACHE='/var/run/console-mihomo-delay.json';
function job(){const j=readJson(META,null);if(j?.running&&((j.pid&&(!stat('/proc/'+j.pid)||index(readfile('/proc/'+j.pid+'/cmdline')||'',j.dir)<0))||!j.pid&&time()-j.startedAt>10))return {...j,running:false,error:'后台测速进程已中断',finishedAt:time()};return j;}
function validDir(dir){return type(dir)=='string'&&!!match(dir,/^\/var\/run\/console-mihomo-batch\/[0-9]+-[0-9]+$/);}
function start(names){
	const previous=job();if(previous?.running)return {ok:true,job:previous,existing:true};
	if(!length(names))die('没有可测速的节点\n');mkdir(ROOT,0700);
	if(validDir(previous?.dir)){for(let f in lsdir(previous.dir)||[])unlink(previous.dir+'/'+f);rmdir(previous.dir);}
	const id=time()+'-'+split(readfile('/proc/self/stat'),' ')[0],dir=ROOT+'/'+id;mkdir(dir,0700);
	const j={id,dir,running:true,pid:null,startedAt:time(),total:length(names),completed:0,failed:0,concurrency:6};
	writeJson(dir+'/names.json',names);writeJson(META,j);
	if(system(['/bin/sh','-c','/usr/bin/ucode /usr/sbin/console-mihomo-delay.uc run '+dir+' >/tmp/console-mihomo-batch.log 2>&1 &'])!=0){j.running=false;j.error='无法启动后台测速';writeJson(META,j);die(j.error+'\n');}
	return {ok:true,job:j};
}
function worker(dir,index){
	if(!validDir(dir)||!match(''+index,/^[0-9]+$/))die('Invalid worker arguments\n');
	const names=readJson(dir+'/names.json',[]),name=names[+index];if(type(name)!='string')die('Unknown node\n');
	let encoded='';for(let i=0;i<length(name);i++)encoded+=sprintf('%%%02X',ord(substr(name,i,1)));
	const args=['/bin/uclient-fetch','-q','-Y','off','-T','6','-O','-','--header=Authorization: Bearer '+trim(readfile('/etc/console-mihomo/secret')||''),'http://127.0.0.1:9097/proxies/'+encoded+'/delay?timeout=4000&expected=204&url=https%3A%2F%2Fwww.gstatic.com%2Fgenerate_204'];
	let result=null;const p=popen(command(args)+' 2>/dev/null');if(p){const raw=p.read('all');if(p.close()==0)try{result=json(raw);}catch(e){}}
	writeJson(dir+'/'+index+'.json',{testedAt:time(),delay:type(result?.delay)=='int'&&result.delay>=0?result.delay:null});
}
function run(dir){
	if(!validDir(dir))die('Invalid job directory\n');let j=readJson(META,null);if(j?.dir!=dir||!j.running)return;
	j.pid=+split(readfile('/proc/self/stat'),' ')[0];writeJson(META,j);
	const names=readJson(dir+'/names.json',[]);let active={},next=0;
	try{
		while(j.completed<length(names)){
			while(length(keys(active))<j.concurrency&&next<length(names)){
				const i=next++;active[''+i]=time();system(['/bin/sh','-c','/usr/bin/ucode /usr/sbin/console-mihomo-delay.uc worker '+dir+' '+i+' >/dev/null 2>&1 &']);
			}
			let changed=false,cache=readJson(CACHE,{});
			for(let key,started in active){let measurement=readJson(dir+'/'+key+'.json',null);if(!measurement&&time()-started>12)measurement={testedAt:time(),delay:null};if(!measurement)continue;
				cache[names[+key]]=measurement;delete active[key];j.completed++;if(measurement.delay==null)j.failed++;changed=true;
			}
			if(changed){writeJson(CACHE,cache);writeJson(META,j);}if(j.completed<length(names))system(['/bin/sleep','1']);
		}
		j.running=false;j.finishedAt=time();writeJson(META,j);
	}catch(e){j.running=false;j.error='后台测速失败';j.finishedAt=time();writeJson(META,j);die(e);}
}
export { job,start,worker,run };
