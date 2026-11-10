"""Exercise installer network writing against a scrubbed release configuration."""
from pathlib import Path
import shutil,subprocess,tempfile,unittest

class InstallerNetworkTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which('bash'),'requires a POSIX shell')
    def test_minimal_template_and_reconfiguration(self):
        repo=Path(__file__).resolve().parents[1]
        source=(repo/'.dsh/skills/openwrt-installer-image/scripts/installer.sh').read_text()
        functions=source[source.index('nic_showvals() {'):source.index('nic_apply_firewall() {')]
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);network=root/'network';script=root/'check.sh'
            network.write_text("config interface 'loopback'\n\toption device 'lo'\n\toption proto 'static'\n\toption ipaddr '127.0.0.1'\n")
            script.write_text('set -eu\n'+functions+'''
lan_port=eth1;wan_port=eth2;lan_cidr=192.168.88.1/24
nic_apply_network "$1"
test "$(nic_showvals "$1" device '' br-lan ports)" = eth1
test "$(nic_showvals "$1" interface lan '' ipaddr)" = 192.168.88.1/24
test "$(nic_showvals "$1" interface wan '' device)" = eth2
test "$(nic_showvals "$1" interface wan6 '' device)" = eth2
lan_port=eth0;wan_port=;lan_cidr=192.168.99.1/24
nic_apply_network "$1"
test "$(nic_showvals "$1" device '' br-lan ports)" = eth0
test "$(nic_showvals "$1" interface lan '' ipaddr)" = 192.168.99.1/24
! nic_has_iface "$1" wan
! nic_has_iface "$1" wan6
test "$(nic_showvals "$1" interface loopback '' ipaddr)" = 127.0.0.1
''')
            subprocess.run(['bash',str(script),str(network)],check=True)

if __name__=='__main__':unittest.main()
