#!/usr/bin/env python3
"""Remove device identity, credentials and runtime data from a release copy."""
from pathlib import Path, PurePosixPath
import argparse,hashlib,json,os,re,shutil,tarfile

FEATURE=re.compile(r'(?:console[-_])?(?:openvpn|mihomo|vpn|ddns)',re.I)
def sensitive(name):
    p=PurePosixPath(name.lstrip('./'))
    parts=p.parts
    if any(s in ('console-vpn','console-mihomo','openvpn') for s in parts):return True
    if any(FEATURE.search(s) for s in parts[:-1]) and parts and parts[0]=='root':return True
    if p.name=='ddns' and 'config' in parts:return True
    return bool(parts and parts[0]=='root' and FEATURE.search(p.name))

def database_hashes(root):
    result={}
    for p in root.rglob('*'):
        if p.is_symlink() or not p.is_file() or any('mihomo' in part for part in p.parts):continue
        # Only public GeoIP datasets are immutable release resources. Runtime
        # databases must be removed rather than protected by this hash check.
        if p.parent==root/'srv/console-security' and re.fullmatch(r'geo-[0-9-]+\.db',p.name):
            result[str(p.relative_to(root))]=hashlib.sha256(p.read_bytes()).hexdigest()
    return result

def apply(root):
    before=database_hashes(root);removed=0
    def drop(p):
        nonlocal removed
        if not p.exists() and not p.is_symlink():return
        assert p.parent.resolve().is_relative_to(root)
        if p.is_dir() and not p.is_symlink():shutil.rmtree(p)
        else:p.unlink()
        removed+=1
    for rel in ['etc/console-vpn','etc/openvpn','usr/share/ddns/custom',
                'etc/console-backup','etc/console-security','etc/console-situational',
                'etc/console-flow','etc/console-portmap','srv/console-history',
                'etc/uhttpd.key','etc/uhttpd.crt','etc/ethers','etc/installer-nic.json']:
        drop(root/rel)
    for directory in [root/'root',root/'tmp',root/'var/log']:
        if directory.is_dir() and not directory.is_symlink():
            for p in list(directory.iterdir()):drop(p)
    for directory,allow in [
        ('srv/console-security',lambda n: bool(re.fullmatch(r'geo-[0-9-]+\.db',n)) or n=='geo.json'),
        ('srv/console-situational',lambda n: bool(re.fullmatch(r'feed-[a-zA-Z0-9_-]+\.txt',n)) or n=='feeds.json'),
    ]:
        d=root/directory
        if d.is_dir():
            for p in list(d.iterdir()):
                if not allow(p.name):drop(p)
    for pattern in ['etc/dropbear/*_host_key','etc/dropbear/authorized_keys','etc/ssh/ssh_host_*']:
        for p in list(root.glob(pattern)):drop(p)
    # Restore distribution defaults, removing saved leases, port forwards,
    # DDNS/API credentials and device-specific address assignments.
    repo=Path(__file__).resolve().parents[4]
    # Device snapshots can predate the public source's example-data cleanup.
    # Use the reviewed source for these installed files rather than resurrecting
    # the original device addresses embedded in samples and explanatory comments.
    app=repo/'package/luci-app-console'
    for rel in ['usr/sbin/selftest-situational.sh','usr/share/ucode/console/security.uc',
                'usr/share/ucode/console/situational.uc','usr/share/ucode/console/net-state.uc']:
        source=app/'root'/rel;target=root/rel
        if target.is_file():shutil.copyfile(source,target)
    for rel in ['console/model.js','view/console/security.js']:
        source=app/'htdocs/luci-static/resources'/rel
        target=root/'www/luci-static/resources'/rel
        if target.is_file():shutil.copyfile(source,target)
    theme=repo/'package/luci-theme-console/htdocs/luci-static/console'
    destination=root/'www/luci-static/console'
    (destination/'fonts').mkdir(parents=True,exist_ok=True)
    for p in list((destination/'fonts').glob('DINPro-*.otf')):drop(p)
    for name in ['SourceHanSansSC-VF.otf.woff2','LICENSE.txt']:
        shutil.copyfile(theme/'fonts'/name,destination/'fonts'/name)
    shutil.copyfile(theme/'console-system.css',destination/'console-system.css')
    defaults={
        'dhcp':'package/network/services/dnsmasq/files/dhcp.conf',
        'firewall':'package/network/config/firewall/files/firewall.config',
        'rpcd':'package/system/rpcd/files/rpcd.config',
    }
    for name,rel in defaults.items():
        source=repo/rel
        if not source.is_file():raise RuntimeError('Missing release default: '+rel)
        (root/'etc/config'/name).write_bytes(source.read_bytes())
    oaf=repo/'package/OpenAppFilter/open-app-filter/files'
    for name in ['appfilter','appfilter_whitelist','fwx','fwx_record','mac_blacklist',
                 'macfilter','macfilter_whitelist','user_info']:
        source=oaf/(name+'.config')
        if source.is_file():(root/'etc/config'/name).write_bytes(source.read_bytes())
    for p in list((root/'etc/config').iterdir()):
        if re.search(r'(?i)(?:\.bak|\.orig|\.old|backup|last-good)',p.name):drop(p)
    (root/'etc/config/network').write_text("config interface 'loopback'\n\toption device 'lo'\n\toption proto 'static'\n\toption ipaddr '127.0.0.1'\n\toption netmask '255.0.0.0'\n")
    (root/'etc/hosts').write_text('127.0.0.1 localhost\n::1 localhost ip6-localhost ip6-loopback\n')
    (root/'etc/rc.local').write_text('#!/bin/sh\nexit 0\n');(root/'etc/rc.local').chmod(0o755)
    shadow=root/'etc/shadow'
    if shadow.is_file():
        lines=shadow.read_text().splitlines()
        shadow.write_text('\n'.join('root:::0:99999:7:::' if line.startswith('root:') else line for line in lines)+'\n')
        shadow.chmod(0o600)
    mihomo=root/'etc/console-mihomo'
    if mihomo.is_dir():
        # GeoIP/geosite databases are program resources, not saved subscriptions.
        for p in list(mihomo.iterdir()):
            if p.name not in ['geoip.metadb','GeoIP.dat','GeoSite.dat','Country.mmdb']:drop(p)
    for p in list((root/'etc/config').glob('openvpn*')):drop(p)
    for service in ['console-openvpn','openvpn','console-mihomo','mihomo']:
        for p in list((root/'etc/rc.d').glob('*'+service)):
            if p.is_symlink() or p.is_file():drop(p)
    for directory in [root/'root',root/'etc/console-backup']:
        if directory.is_dir():
            for p in list(directory.iterdir()):
                if FEATURE.search(p.name):drop(p)
    # Remove matching files inside otherwise unrelated backup archives as well.
    archive_members_removed=0
    for p in list((root/'root').rglob('*.tar.gz')):
        if not p.is_file():continue
        temp=p.with_name(p.name+'.clean')
        with tarfile.open(p,'r:gz') as src,tarfile.open(temp,'w:gz') as dst:
            for member in src:
                if sensitive(member.name):archive_members_removed+=1;continue
                dst.addfile(member,src.extractfile(member) if member.isfile() else None)
        os.chmod(temp,p.stat().st_mode);temp.replace(p)
    for p in (root/'etc/config').iterdir():
        if p.name.startswith(('ddns.','openvpn.')):drop(p)
    ddns=root/'etc/config/ddns'
    ddns.write_text("config ddns 'global'\n\toption ddns_dateformat '%F %R'\n\toption ddns_loglines '250'\n\toption upd_privateip '0'\n")
    hook=root/'etc/openvpn.user'
    if hook.exists():hook.write_text('#!/bin/sh\n# No user OpenVPN hooks in the release image.\nexit 0\n');hook.chmod(0o755)
    for p in [root/'etc/config/firewall',root/'etc/console-backup/portmap.firewall.last-good']:
        if not p.is_file():continue
        chunks=re.split(r'(?m)(?=^config\s)',p.read_text())
        keep=[]
        for chunk in chunks:
            if re.search(r'console_vpn_|\bcvpns\b|\bcvpnc\b|OpenVPN|/etc/console-mihomo/',chunk,re.I):removed+=1
            else:keep.append(chunk)
        p.write_text(''.join(keep))
    after=database_hashes(root)
    if before!=after:raise RuntimeError('A retained database was changed by release sanitization')
    policy={'openvpn_accounts':0,'openvpn_configured':False,'openvpn_autostart':False,
            'mihomo_configured':False,'mihomo_autostart':False,'ddns_saved_services':0,
            'retained_databases':len(after),'removed_config_groups':removed,'removed_archive_members':archive_members_removed,
            'ssh_host_keys_embedded':False,'runtime_history_embedded':False,
            'development_backups_embedded':False,'network_defaults_reset':True}
    (root/'etc/console-image-policy.json').write_text(json.dumps(policy,indent=2)+'\n')
    return policy

def check(root):
    bad=[]
    for rel in ['etc/console-vpn','etc/openvpn','etc/console-backup','srv/console-history',
                'etc/uhttpd.key','etc/uhttpd.crt','etc/console-security','etc/console-situational']:
        if (root/rel).exists():bad.append(rel)
    for pattern in ['etc/dropbear/*_host_key','etc/dropbear/authorized_keys','etc/ssh/ssh_host_*',
                    '**/DINPro-*.otf']:
        bad.extend(str(p.relative_to(root)) for p in root.glob(pattern))
    if (root/'root').is_dir():
        bad.extend(str(p.relative_to(root)) for p in (root/'root').iterdir())
    for directory,allow in [
        ('srv/console-security',lambda n: bool(re.fullmatch(r'geo-[0-9-]+\.db',n)) or n=='geo.json'),
        ('srv/console-situational',lambda n: bool(re.fullmatch(r'feed-[a-zA-Z0-9_-]+\.txt',n)) or n=='feeds.json'),
    ]:
        d=root/directory
        if d.is_dir():bad.extend(str(p.relative_to(root)) for p in d.iterdir() if not allow(p.name))
    mihomo=root/'etc/console-mihomo'
    if mihomo.exists():
        bad.extend('etc/console-mihomo/'+p.name for p in mihomo.iterdir() if p.name not in ['geoip.metadb','GeoIP.dat','GeoSite.dat','Country.mmdb'])
    for service in ['console-openvpn','openvpn','console-mihomo','mihomo']:
        if list((root/'etc/rc.d').glob('S*'+service)):bad.append('autostart '+service)
    if re.search(r'(?m)^\s*config\s+service\b',(root/'etc/config/ddns').read_text()):bad.append('ddns service')
    for directory in [root/'root',root/'etc/console-backup']:
        if directory.exists():bad.extend(str(p.relative_to(root)) for p in directory.iterdir() if FEATURE.search(p.name))
    for p in (root/'root').rglob('*.tar.gz'):
        with tarfile.open(p,'r:gz') as t:
            if any(sensitive(m.name) for m in t):bad.append('backup archive containing private settings')
    report={'ok':not bad,'differences':bad}
    print(json.dumps(report));return not bad

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('root');p.add_argument('--check',action='store_true');a=p.parse_args()
    root=Path(a.root).resolve()
    if root==Path('/') or not (root/'etc/config/network').is_file():raise SystemExit('Not a release rootfs directory')
    if not a.check:print(json.dumps(apply(root)))
    raise SystemExit(0 if check(root) else 1)
