// SPDX-License-Identifier: Apache-2.0
import { open,popen,unlink,stat,rename,lsdir,readfile } from 'fs';
import { DATA,ensure,geoMeta,activateGeo,writeJson,readJson,ipKey,command,exec,query,storage } from 'console.security';

ensure();
const started=time();
const process=split(readfile('/proc/self/stat') || '', ' ');
let stream=null, sink=null;
function progress(message, count) { writeJson('/tmp/console-geo-job.json',{running:true,started,pid:+process[0],processStart:process[21],message,records:count || 0}); }
try {
	const current=geoMeta();
	if (storage().freeBytes<180*1024*1024) for(let name in lsdir(DATA) || []) if(match(name,/^geo-[0-9-]+\.db$/) && name!=current?.file) unlink(DATA+'/'+name);
	if (storage().freeBytes<180*1024*1024) die('存储空间不足，更新地区库至少需要180MiB可用空间');
	let version=null;
	// The current month's release may not be published yet. Try last month too.
	const month=localtime(); const y=month.year, m=month.mon;
	const versions=[sprintf('%04d-%02d',y,m),sprintf('%04d-%02d',m==1?y-1:y,m==1?12:m-1)];
	const archive='/tmp/console-country.csv.gz';
	for (let v in versions) {
		progress('正在下载 DB-IP Country Lite '+v);
		if (system(['/usr/bin/wget','-q','-T','60','-O',archive,'https://download.db-ip.com/free/dbip-country-lite-'+v+'.csv.gz'])==0) { version=v; break; }
	}
	// A trusted host may stage the official archive when the router cannot reach the Internet.
	if (!version) {
		const staged=readJson('/tmp/console-country-staged.json',null);
		if (staged && match(staged.version || '',/^20\d\d-\d\d$/) && stat('/tmp/console-country-staged.csv.gz')) {
			version=staged.version; exec(['/bin/cp','/tmp/console-country-staged.csv.gz',archive]);
		} else die('下载失败；请检查路由器联网。现有数据库和规则已保留');
	}
	if ((stat(archive)?.size || 0)>50*1024*1024) die('地区库压缩包大小异常');
	exec(['/bin/gzip','-t',archive]);
	if(current?.version==version) { writeJson('/tmp/console-geo-job.json',{running:false,started,finished:time(),ok:true,message:'当前已是可下载的最新版本 '+version}); unlink(archive); exit(0); }
	const temp='/tmp/console-country-new.db'; unlink(temp);
	sink=popen(command(['/usr/bin/sqlite3',temp]),'w'); if (!sink) die('无法创建地区索引');
	sink.write('PRAGMA journal_mode=OFF; PRAGMA synchronous=OFF; PRAGMA max_page_count=25600; CREATE TABLE geo(family INTEGER,start TEXT,finish TEXT,a TEXT,b TEXT,cc TEXT,PRIMARY KEY(family,start)) WITHOUT ROWID; BEGIN;\n');
	stream=popen(command(['/bin/gzip','-dc',archive]),'r'); if (!stream) die('无法读取地区库');
	let count=0;
	for (let line=stream.read('line'); line!=null; line=stream.read('line')) {
		line=replace(trim(line),/"/g,''); if (!length(line)) continue;
		const p=split(line,','); const first=ipKey(p[0]), last=ipKey(p[1]);
		if (length(p)!=3 || !first || !last || first.family!=last.family || first.key>last.key || !match(p[2],/^[A-Z]{2}$/)) die('地区库包含无效地址或字段');
		sink.write(sprintf("INSERT INTO geo VALUES(%d,'%s','%s','%s','%s','%s');\n",first.family,first.key,last.key,p[0],p[1],p[2]));
		count++; if (count%20000==0) progress('正在构建 IPv4/IPv6 地区索引',count);
		if (count>2000000) die('地区库记录数量异常');
	}
	stream.close(); stream=null;
	sink.write('COMMIT; CREATE INDEX geo_country ON geo(cc,family); PRAGMA optimize;\n'); const status=sink.close(); sink=null;
	if (status!=0 || count<100000 || query('SELECT count(*) AS n FROM geo;',temp)[0]?.n!=count) die('地区索引构建或校验失败');
	if ((stat(temp)?.size || 0)>100*1024*1024) die('地区数据库超过100MiB预算');
	const file='geo-'+version+'-'+started+'.db', target=DATA+'/'+file;
	exec(['/bin/cp',temp,target]);
	exec(['/bin/chmod','0600',target]);
	const previous=geoMeta();
	try { activateGeo({file,version,records:count,updated:time(),source:'DB-IP Country Lite',license:'CC BY 4.0',bytes:stat(target).size,countries:query('SELECT cc,count(*) AS ranges FROM geo GROUP BY cc ORDER BY cc;',target)}); } catch(e) {unlink(target);die(e.message);}
	// Keep one previous version for recovery, remove only our own obsolete versions.
	for (let name in lsdir(DATA) || []) if (match(name,/^geo-[0-9-]+\.db$/) && name!=file && name!=previous?.file) unlink(DATA+'/'+name);
	writeJson('/tmp/console-geo-job.json',{running:false,started,finished:time(),ok:true,message:'地区数据库更新成功',records:count});
	unlink(archive); unlink(temp); unlink('/tmp/console-country-staged.csv.gz'); unlink('/tmp/console-country-staged.json');
} catch (e) {
	if (stream) stream.close(); if (sink) sink.close();
	unlink('/tmp/console-country-new.db'); unlink('/tmp/console-country.csv.gz');
	writeJson('/tmp/console-geo-job.json',{running:false,started,finished:time(),ok:false,message:e.message || '地区数据库更新失败'});
}
