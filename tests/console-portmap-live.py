"""Restricted live integration test. Requires empty console mapping list and router SSH."""
import socket
import struct
import subprocess
import threading
import sys

def router(mode):
    subprocess.run(['ssh', '-o', 'BatchMode=yes', 'root@192.168.1.1',
                    'ucode /tmp/console-portmap-live.uc '+mode], check=True)

listeners=[]
def connect(protocol, port):
    s=socket.socket(socket.AF_INET, socket.SOCK_STREAM if protocol=='tcp' else socket.SOCK_DGRAM)
    s.setsockopt(socket.IPPROTO_IP,31,struct.pack('!I',15))
    s.bind(('192.168.1.5',0))
    s.settimeout(2)
    try:
        s.connect(('172.16.10.81',port))
        if protocol=='udp':s.send(b'portmap-test')
        return s.recv(2048).decode()
    finally:s.close()

def blocked(protocol,port):
    try:connect(protocol,port)
    except (TimeoutError,ConnectionRefusedError,ConnectionResetError,OSError):return
    raise AssertionError('unexpected access: '+protocol+str(port))

try:
    router(sys.argv[1] if len(sys.argv)>1 else 'start')
    for port in (45080,45081,45082):
        for protocol in ('tcp','udp'):
            s=socket.socket(socket.AF_INET,socket.SOCK_STREAM if protocol=='tcp' else socket.SOCK_DGRAM)
            s.bind(('192.168.1.5',port))
            if protocol=='tcp':s.listen()
            listeners.append(s)
            def serve(sock=s,p=port,proto=protocol):
                try:
                    while True:
                        msg=(proto+':'+str(p)).encode()
                        if proto=='tcp':
                            c,_=sock.accept();c.sendall(msg);c.close()
                        else:
                            _,a=sock.recvfrom(2048);sock.sendto(msg,a)
                except OSError:pass
            threading.Thread(target=serve,daemon=True).start()
    for proto in ('tcp','udp'):
        for offset in range(3):
            assert connect(proto,48080+offset)==proto+':'+str(45080+offset)
    print('PASS TCP/UDP range mapping and NAT loopback')
    router('hotplug')
    assert connect('tcp',48080)=='tcp:45080'
    router('deny')
    # New 5-tuples avoid already tracked UDP sessions.
    for proto in ('tcp','udp'):blocked(proto,48082)
    print('PASS source restriction also blocks NAT loopback')
    router('disable')
    for proto in ('tcp','udp'):blocked(proto,48081)
    print('PASS disabled rules reject new connections')
finally:
    for s in listeners:s.close()
    router('stop')
