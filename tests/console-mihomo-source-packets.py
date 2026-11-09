"""Live source-policy packet checks using workstation 192.168.1.5 / interface 15."""
import socket,struct,subprocess,re,ssl
def router(command):
    return subprocess.check_output(['ssh','-o','BatchMode=yes','root@192.168.1.1',command],text=True)
probe='table inet console_mihomo_source_probe {\nchain observe {\ntype filter hook prerouting priority -149; policy accept;\nip saddr 192.168.1.5 meta mark 0x434d counter\n}\n}\n'
def send():
    s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
    s.setsockopt(socket.IPPROTO_IP,31,struct.pack('!I',15));s.bind(('192.168.1.5',0))
    s.sendto(b'source-policy-probe',('1.1.1.1',123));s.close()
try:
    for mode,selected in [('include',True),('exclude',False),('none',False),('all',True)]:
        router('ucode /tmp/console-mihomo-source-live.uc '+mode)
        router("nft destroy table inet console_mihomo_source_probe; nft '"+probe+"'")
        send()
        result=router('nft list table inet console_mihomo_source_probe')
        count=int(re.search(r'counter packets (\d+)',result)[1])
        assert (count>0)==selected,(mode,result)
        print('PASS source packet selection:',mode,count)
    host='www.gstatic.com';target=socket.gethostbyname(host)
    s=socket.socket();s.setsockopt(socket.IPPROTO_IP,31,struct.pack('!I',15));s.bind(('192.168.1.5',0));s.settimeout(12);s.connect((target,443))
    with ssl.create_default_context().wrap_socket(s,server_hostname=host) as tls:
        tls.sendall(b'GET /generate_204 HTTP/1.1\r\nHost: www.gstatic.com\r\nConnection: close\r\n\r\n')
        response=tls.recv(4096);assert b' 204 ' in response,response[:150]
    print('PASS real LAN client HTTPS through selected transparent path: HTTP 204')
finally:
    router('ucode /tmp/console-mihomo-source-live.uc all; nft destroy table inet console_mihomo_source_probe')
