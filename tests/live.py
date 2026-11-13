"""Explicit integration scenarios; see docs/TESTING.md before fault injection.

ROUTER is required. SSH keys are supported; SSHPASS optionally enables sshpass.
Results are private diagnostic artifacts and are excluded from Git.
"""
import argparse, base64, ipaddress, json, os, pathlib, re, shlex, shutil, socket, struct, subprocess, time
ROOT=pathlib.Path(__file__).resolve().parents[1]
RESULTS=pathlib.Path(os.environ.get('LIVE_RESULTS', str(ROOT/'artifacts/live-results.json'))).expanduser()
HOST=os.environ.get('ROUTER','')
CTL='/jffs/scripts/net-stack/netctl.sh'
SCENARIOS=('baseline','reboot','modes','wan','crash','hang','firewall','daemon','clients','policy')


def ssh(command,timeout=30,check=True):
    prefix=['sshpass','-e'] if os.environ.get('SSHPASS') else []
    r=subprocess.run(prefix+['ssh','-o','LogLevel=ERROR','-o','ConnectTimeout=4',HOST,command],text=True,capture_output=True,timeout=timeout)
    if check and r.returncode: raise RuntimeError(f'SSH exit {r.returncode}: {r.stderr} {r.stdout}')
    return r.stdout.strip()


def wait_online(timeout=180):
    start=time.monotonic(); last=''
    while time.monotonic()-start<timeout:
        try:
            out=ssh(f'{CTL} status',timeout=10)
            line=out.splitlines()[0]
            if line!=last: print(f'+{time.monotonic()-start:.1f}s {line}',flush=True);last=line
            if ('state=tunnel-online gate=allow' in line
                    and re.search(r'^controller=\d+$',out,re.M)
                    and re.search(r'^xray=\d+$',out,re.M)):
                return round(time.monotonic()-start,1)
        except (RuntimeError,subprocess.TimeoutExpired): pass
        time.sleep(3)
    raise RuntimeError('did not recover within deadline')


def baseline():
    checks=ssh(f'''{CTL} status
printf '\\nCRON\\n'; cru l
printf '\\nHEALTH\\n'; {CTL} health
printf '\\nCTF\\n'; nvram get ctf_disable; nvram get ctf_disable_force
printf '\\nVM\\n'; cat /proc/sys/vm/overcommit_memory; cat /proc/sys/vm/overcommit_ratio
printf '\\nOLD_PROCESSES\\n'; ps | grep -E '[s]run.sh watch|[x]ray-super.sh loop'
''',check=False)
    assert 'state=tunnel-online gate=allow' in checks,checks
    assert 'health_status=0 (0=healthy)' in checks,checks
    assert checks.count('#net-stack-v2#')==1,checks
    assert 'srun.sh watch' not in checks and 'xray-super.sh loop' not in checks,checks
    print(checks,flush=True)
    return checks



PS=os.environ.get('POWERSHELL','')
CURL=os.environ.get('CLIENT_CURL','curl')
LAN4=os.environ.get('LAN4','')
LAN6=os.environ.get('LAN6','')
DNS4=os.environ.get('ROUTER_DNS4','')
DNS6=os.environ.get('ROUTER_DNS6','')
HTTP4_HOST=os.environ.get('HTTP4_HOST','www.baidu.com')
HTTP6_HOST=os.environ.get('HTTP6_HOST','ipv6.baidu.com')
HTTP4_IP=os.environ.get('HTTP4_IP','')
HTTP6_IP=os.environ.get('HTTP6_IP','')

def client_http(family, timeout=12):
    host=HTTP4_HOST if family==4 else HTTP6_HOST
    address=HTTP4_IP if family==4 else HTTP6_IP
    target=address if family==4 else f'[{address}]'
    null='NUL' if CURL.lower().endswith('.exe') else os.devnull
    r=subprocess.run([CURL,'--noproxy','*','--interface',LAN4 if family==4 else LAN6,f'-{family}',
        '--resolve',f'{host}:443:{target}','-sS','-m',str(timeout),'-o',null,'-w','%{http_code}',f'https://{host}/'],
        text=True,capture_output=True,timeout=timeout+5)
    return {'exit':r.returncode,'http':r.stdout.strip(),'stderr':r.stderr.strip()}

def receive_exact(connection, length):
    packet=bytearray()
    while len(packet)<length:
        chunk=connection.recv(length-len(packet))
        if not chunk: raise OSError('short DNS response')
        packet.extend(chunk)
    return bytes(packet)


def client_dns(server, family=4, name='www.baidu.com', tcp=False):
    query=struct.pack('!HHHHHH',0x5123,0x0100,1,0,0,0)+b''.join(bytes([len(x)])+x.encode() for x in name.split('.'))+b'\0'+struct.pack('!HH',1 if family==4 else 28,1)
    if not PS:
        # Bind before connecting so a second network interface cannot mask failure.
        kind=socket.SOCK_STREAM if tcp else socket.SOCK_DGRAM
        try:
            with socket.socket(socket.AF_INET if family==4 else socket.AF_INET6,kind) as connection:
                connection.settimeout(5)
                connection.bind((LAN4 if family==4 else LAN6,0))
                connection.connect((server,53))
                if tcp:
                    connection.sendall(struct.pack('!H',len(query))+query)
                    length=struct.unpack('!H',receive_exact(connection,2))[0]
                    packet=receive_exact(connection,length)
                else:
                    connection.send(query)
                    packet=connection.recv(65535)
            return dns_result(packet)
        except OSError:
            return {'response':False}
    encoded=base64.b64encode(query).decode()
    source=LAN4 if family==4 else LAN6
    code=f"$ErrorActionPreference='Stop'; $local=[Net.IPEndPoint]::new([Net.IPAddress]::Parse('{source}'),0); $q=[Convert]::FromBase64String('{encoded}'); "
    if tcp:
        code+=f"$c=[Net.Sockets.TcpClient]::new($local); $c.ReceiveTimeout=5000; $c.SendTimeout=5000; $c.Connect('{server}',53); $s=$c.GetStream(); $wire=[byte[]]@(0,$q.Length)+$q; $s.Write($wire,0,$wire.Length); $h=New-Object byte[] 2; $n=$s.Read($h,0,2); if($n -ne 2){{throw 'short prefix'}}; $len=$h[0]*256+$h[1]; $r=New-Object byte[] $len; $got=0; while($got -lt $len){{$n=$s.Read($r,$got,$len-$got); if($n -le 0){{throw 'short DNS'}}; $got+=$n}}; "
    else:
        code+=f"$c=[Net.Sockets.UdpClient]::new($local); $c.Client.ReceiveTimeout=5000; $c.Connect('{server}',53); [void]$c.Send($q,$q.Length); $peer=[Net.IPEndPoint]::new([Net.IPAddress]::Any,0); $r=$c.Receive([ref]$peer); "
    code+="[Convert]::ToBase64String($r); $c.Close()"
    r=subprocess.run([PS,'-NoProfile','-Command',code],capture_output=True,text=True,errors='replace',timeout=18)
    if r.returncode: return {'response':False,'exit':r.returncode}
    packet=base64.b64decode(r.stdout.strip())
    return dns_result(packet)


def dns_result(packet):
    ident,flags,questions,answers,_,_=struct.unpack('!HHHHHH',packet[:12])
    assert ident==0x5123
    return {'response':True,'rcode':flags&15,'answers':answers}

def scenario(name):
    start=time.monotonic()
    if name not in ['baseline','reboot']: wait_online(120)
    if name=='baseline': detail=baseline()
    elif name=='reboot':
        ssh('reboot',check=False)
        time.sleep(8)
        detail={'recovery_seconds_after_initial_8s':wait_online(240),'checks':baseline(),'log':ssh('cat /tmp/net-stack/control.log')}
    elif name=='modes':
        for mode in ['off','auth','tunnel']:
            ssh(f'{CTL} mode {mode}')
            if mode=='tunnel': wait_online(180)
            else:
                deadline=time.monotonic()+40
                while time.monotonic()<deadline:
                    out=ssh(f'{CTL} status')
                    target='state=off gate=off' if mode=='off' else 'state=auth-online gate=off'
                    if target in out and 'xray=stopped' in out: break
                    time.sleep(2)
                else: raise RuntimeError(out)
                assert '#net-stack-v2#' in ssh('cru l')
                assert 'NS2_' not in ssh('iptables -S FORWARD; iptables -S OUTPUT; ip6tables -S FORWARD')
        detail=baseline()
    elif name=='wan':
        ssh(f'{CTL} mode off'); time.sleep(4)
        ssh(f'{CTL} logout')
        assert 'auth_status=1' in ssh(f'{CTL} auth-status',check=False)
        try:
            ssh('service stop_wan',timeout=30)
            time.sleep(5)
            ssh(f'{CTL} mode tunnel')
            time.sleep(4)
            assert 'gate=block' in ssh(f'{CTL} status')
        finally:
            ssh('service start_wan',timeout=30)
        detail={'recovery_seconds':wait_online(180),'log':ssh('tail -n 50 /tmp/net-stack/control.log')}
        assert 'bootstrap HTTP=200' in detail['log']
        assert 'authentication: confirmed online' in detail['log']
    elif name=='crash':
        before=ssh('cat /tmp/net-stack/xray.pid').split()[0]
        ssh(f'kill -9 {before}')
        deadline=time.monotonic()+90
        while time.monotonic()<deadline:
            current=ssh('cat /tmp/net-stack/xray.pid',check=False).split()
            if current and current[0]!=before: break
            time.sleep(2)
        else: raise RuntimeError('xray PID was not replaced')
        elapsed=wait_online(120)
        after=ssh('cat /tmp/net-stack/xray.pid').split()[0]
        assert before!=after
        detail={'recovery_seconds_after_initial_3s':elapsed,'old_pid':before,'new_pid':after}
    elif name=='hang':
        before=ssh('cat /tmp/net-stack/xray.pid').split()[0]
        ssh(f'kill -STOP {before}')
        time.sleep(12)
        deadline=time.monotonic()+60
        while time.monotonic()<deadline:
            if 'gate=block' in ssh(f'{CTL} status'): break
            time.sleep(2)
        else: raise RuntimeError('hung process was not blocked')
        elapsed=wait_online(180)
        after=ssh('cat /tmp/net-stack/xray.pid').split()[0]
        assert before!=after
        detail={'recovery_seconds_after_gate_block':elapsed,'old_pid':before,'new_pid':after}
    elif name=='firewall':
        ssh('iptables -N NS2_TEST_RELOAD')
        try:
            ssh('service restart_firewall',timeout=30)
            deadline=time.monotonic()+45
            while time.monotonic()<deadline:
                if not ssh('iptables -S NS2_TEST_RELOAD',check=False): break
                time.sleep(2)
            else: raise RuntimeError('firmware did not actually rebuild the firewall')
            detail={'recovery_seconds':wait_online(120),'checks':baseline()}
        finally:
            ssh('iptables -X NS2_TEST_RELOAD 2>/dev/null || true')
        assert ssh('iptables -S FORWARD').count('-j NS2_FWD')==1
        assert ssh('ip6tables -S FORWARD').count('-j NS2_FWD')==1
    elif name=='clients':
        detail={}
        for family in [4,6]:
            value=client_http(family); assert value['http']=='200',value
            detail[f'HTTPS-v{family}']=value
        for server,family,tcp in [(DNS4,4,False),('8.8.8.8',4,False),(DNS4,4,True),(DNS6,6,False)]:
            value=client_dns(server,family,tcp=tcp)
            assert value.get('rcode')==0 and value['answers']>0,value
            detail[f'DNS-{server}-tcp={tcp}']=value
    elif name=='policy':
        for family in [4,6]:
            before_client=client_http(family)
            assert before_client['http']=='200',before_client
        before_dns=client_dns('8.8.8.8')
        assert before_dns.get('rcode')==0 and before_dns.get('answers',0)>0,before_dns
        controller=ssh('cat /tmp/net-stack/daemon.pid').split()[0]
        xray=ssh('cat /tmp/net-stack/xray.pid').split()[0]
        try:
            ssh(f'kill -STOP {controller}; kill -9 {xray}')
            time.sleep(3)
            detail={'IPv4':client_http(4,4),'IPv6':client_http(6,4)}
            assert detail['IPv4']['exit']!=0 and detail['IPv6']['exit']!=0,detail
            dns=client_dns('8.8.8.8',name=f'n{int(time.time())}.1.1.1.1.sslip.io')
            assert not dns['response'] or dns.get('rcode')==2,dns
            detail['uncached-DNS']=dns
            detail['routes']=ssh('. /jffs/scripts/net-stack/net-stack.conf; ip route show table "$TABLE"; ip -6 route show table "$TABLE"')
            tun=ssh('. /jffs/scripts/net-stack/net-stack.conf; printf "%s" "$TUN"')
            assert f'default dev {tun}' not in detail['routes'],detail
            assert 'blackhole default' in detail['routes'] and 'unreachable default dev lo' in detail['routes']
            resolve=shlex.quote(f'{HTTP4_HOST}:443:{HTTP4_IP}')
            url=shlex.quote(f'https://{HTTP4_HOST}/')
            direct=ssh(f"curl --noproxy '*' --resolve {resolve} -s -m 4 -o /dev/null -w '%{{http_code}}' {url}",check=False)
            assert direct=='000',direct
            detail['router-direct-HTTPS']=direct
        finally:
            ssh(f'kill -CONT {controller}; {CTL} wake')
        wait_online(150)
    elif name=='daemon':
        before=ssh('cat /tmp/net-stack/daemon.pid').split()[0]
        ssh(f'kill -9 {before}')
        time.sleep(5)
        deadline=time.monotonic()+90
        while time.monotonic()<deadline:
            after=ssh('cat /tmp/net-stack/daemon.pid',check=False).split()
            if after and after[0]!=before: break
            time.sleep(3)
        else: raise RuntimeError('cron did not restart controller')
        detail={'recovery_seconds':wait_online(150),'old_pid':before,'new_pid':after[0]}
    else: raise ValueError(name)
    result={'scenario':name,'passed':True,'elapsed_seconds':round(time.monotonic()-start,1),'detail':detail}
    RESULTS.parent.mkdir(mode=0o700,parents=True,exist_ok=True)
    existing=json.loads(RESULTS.read_text()) if RESULTS.exists() else []
    existing.append(result); RESULTS.write_text(json.dumps(existing,ensure_ascii=False,indent=2))
    print(f'PASS {name}: {result["elapsed_seconds"]}s',flush=True)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('scenarios',nargs='+',choices=SCENARIOS,help='explicit scenarios; fault tests interrupt service')
    args=parser.parse_args()
    if not HOST or HOST.startswith('-'):
        parser.error('set ROUTER to the SSH destination, for example admin@your-router')
    required=['ssh']+(['sshpass'] if os.environ.get('SSHPASS') else [])
    if {'clients','policy'} & set(args.scenarios):
        required += [CURL]+([PS] if PS else [])
        for name,family in [('LAN4',4),('LAN6',6),('ROUTER_DNS4',4),('ROUTER_DNS6',6),('HTTP4_IP',4),('HTTP6_IP',6)]:
            try:
                if ipaddress.ip_address(os.environ.get(name,'')).version!=family: raise ValueError()
            except ValueError:
                parser.error(f'set {name} to a valid IPv{family} address; see docs/TESTING.md')
    for executable in required:
        if not shutil.which(executable): parser.error(f'missing executable: {executable}')
    os.umask(0o077)
    for name in args.scenarios: scenario(name)


if __name__=='__main__':
    main()
