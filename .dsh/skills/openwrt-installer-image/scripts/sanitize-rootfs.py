#!/usr/bin/env python3
"""Remove personal VPN/proxy/DDNS settings from a disposable release rootfs."""
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
        if p.suffix in ('.db','.sqlite','.sqlite3'):
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
    for rel in ['etc/console-vpn','etc/openvpn','usr/share/ddns/custom']:
        drop(root/rel)
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
            'retained_databases':len(after),'removed_config_groups':removed,'removed_archive_members':archive_members_removed}
    (root/'etc/console-image-policy.json').write_text(json.dumps(policy,indent=2)+'\n')
    return policy

def check(root):
    bad=[]
    for rel in ['etc/console-vpn','etc/openvpn']:
        if (root/rel).exists():bad.append(rel)
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
