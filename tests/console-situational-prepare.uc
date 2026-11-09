// Invoked by console-situational-regression.sh with a private directory.
import { readfile,writefile } from 'fs';
const root=testdir;
let security=readfile('/usr/share/ucode/console/security.uc');
security=replace(security,"const DB = DATA + '/traffic.db';","const DB = '"+root+"/test-security.db';");
writefile(root+'/test-security.uc',security);
let s=readfile('/usr/share/ucode/console/situational.uc');
s=replace(s,"'console.security'","'"+root+"/test-security.uc'");
s=replace(s,"const TDATA = '/srv/console-situational';","const TDATA = '"+root+"';");
s=replace(s,"'/tmp/console-threat-packets.lock'","'"+root+"/packets.lock'");
s=replace(s,"function tOutput(args) {","function tOutput(args) { if (args[0]=='/usr/sbin/nft' && args[1]=='-j') return readfile('"+root+"/fixture-counters.json') || ''; ");
s=replace(s,"const raw = tOutput(['/bin/sh', '-c', cmd + \" | grep -E 'CS[GT]:' | tail -n \" + LOG_TAIL]);","const raw = readfile('"+root+"/fixture-kernel.log') || ''; ");
writefile(root+'/mock-situational.uc',s);
let test=readfile(testsource);
test=replace(test,/\/tmp\//g,root+'/');
writefile(root+'/regression.uc',test);
