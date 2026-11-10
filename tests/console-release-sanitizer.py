"""Regression: release copies must not inherit a device's secrets or history."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
import io
import tarfile

REPO=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('release_sanitizer',REPO/'.dsh/skills/openwrt-installer-image/scripts/sanitize-rootfs.py')
san=importlib.util.module_from_spec(spec);spec.loader.exec_module(san)

class ReleaseCopyTests(unittest.TestCase):
    def test_scrubs_device_copy_preserves_programs_and_public_resources(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            fixture={
                'etc/config/network':b'private-address',
                'etc/config/ddns':b'config service saved\n',
                'etc/config/firewall':b'private-port-forward',
                'etc/config/dhcp.bak-console':b'private-lease',
                'etc/dropbear/dropbear_ed25519_host_key':b'real-device-key-fixture',
                'etc/dropbear/authorized_keys':b'personal-authorized-key',
                'etc/uhttpd.key':b'device-tls-key',
                'etc/console-vpn/accounts.json':b'private-account',
                'etc/console-backup/network.last-good':b'private-address',
                'root/unrelated-backup.tar.gz':b'private-backup',
                'root/.ssh/id_ed25519':b'personal-private-key',
                'srv/console-history/123.jsonl':b'private-history',
                'srv/console-security/traffic.db':b'private-events',
                'srv/console-security/traffic.db-wal':b'private-wal',
                'srv/console-security/geo-2026-11-123.db':b'public-geo-resource',
                'srv/console-situational/dynamic.json':b'private-blocklist',
                'srv/console-situational/feed-dshield.txt':b'public-feed',
                'etc/console-mihomo/config.json':b'private-subscription',
                'etc/console-mihomo/geoip.metadb':b'public-geodata',
                'www/luci-static/console/fonts/DINPro-Regular.otf':b'old-font',
                'usr/sbin/application':b'program-must-not-change',
            }
            for name,data in fixture.items():
                p=root/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(data)
            with tarfile.open(root/'root/unrelated-backup.tar.gz','w:gz') as archive:
                member=tarfile.TarInfo('etc/dropbear/dropbear_ed25519_host_key')
                member.size=len(b'private-key-fixture')
                archive.addfile(member,io.BytesIO(b'private-key-fixture'))
            self.assertFalse(san.check(root))
            policy=san.apply(root)
            self.assertTrue(san.check(root))
            self.assertEqual((root/'usr/sbin/application').read_bytes(),fixture['usr/sbin/application'])
            self.assertEqual((root/'srv/console-security/geo-2026-11-123.db').read_bytes(),b'public-geo-resource')
            self.assertFalse((root/'srv/console-security/traffic.db').exists())
            self.assertFalse((root/'etc/dropbear/dropbear_ed25519_host_key').exists())
            self.assertEqual(list((root/'root').iterdir()),[])
            self.assertEqual((root/'www/luci-static/console/fonts/SourceHanSansSC-VF.otf.woff2').read_bytes(),(REPO/'package/luci-theme-console/htdocs/luci-static/console/fonts/SourceHanSansSC-VF.otf.woff2').read_bytes())
            self.assertFalse(policy['ssh_host_keys_embedded'])
            # A second sanitization must also pass without restoring device data.
            san.apply(root);self.assertTrue(san.check(root))

if __name__=='__main__':unittest.main()
