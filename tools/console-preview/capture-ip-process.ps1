param(
    [string]$TargetAddress = '203.0.113.72',
    [string]$OutputDirectory = '<repo>\.stage\ip-process-capture',
    [int]$DurationHours = 24,
    [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Net;
using System.Runtime.InteropServices;
public sealed class TargetTcpRow {
 public string LocalAddress { get; set; }
 public int LocalPort { get; set; }
 public string RemoteAddress { get; set; }
 public int RemotePort { get; set; }
 public uint State { get; set; }
 public uint OwningPid { get; set; }
}
public static class TargetTcpOwners {
 [DllImport("iphlpapi.dll", SetLastError=true)]
 private static extern uint GetExtendedTcpTable(IntPtr table, ref int size, bool order, int family, int tableClass, uint reserved);
 private static uint U32(IntPtr p, int offset) { return unchecked((uint)Marshal.ReadInt32(p, offset)); }
 private static int Port(uint raw) { return (int)(((raw & 255) << 8) | ((raw >> 8) & 255)); }
 public static TargetTcpRow[] Read(string target) {
  uint address=BitConverter.ToUInt32(IPAddress.Parse(target).GetAddressBytes(),0);
  for(int attempt=0;attempt<5;attempt++) {
   int size=0;
   uint rc=GetExtendedTcpTable(IntPtr.Zero,ref size,false,2,5,0);
   if(rc!=122 && rc!=0) throw new Win32Exception((int)rc);
   IntPtr data=Marshal.AllocHGlobal(Math.Max(size,4));
   try {
    rc=GetExtendedTcpTable(data,ref size,false,2,5,0);
    if(rc==122) continue;
    if(rc!=0) throw new Win32Exception((int)rc);
    int count=Marshal.ReadInt32(data);
    if(count<0 || (long)count*24+4>size) throw new InvalidOperationException("Invalid TCP table size");
    var result=new List<TargetTcpRow>();
    for(int i=0;i<count;i++) {
     IntPtr row=IntPtr.Add(data,4+i*24);
     uint state=U32(row,0),remote=U32(row,12);
     if(state==2 || remote!=address) continue;
     result.Add(new TargetTcpRow {
      State=state, LocalAddress=new IPAddress((long)U32(row,4)).ToString(),
      LocalPort=Port(U32(row,8)), RemoteAddress=target,
      RemotePort=Port(U32(row,16)), OwningPid=U32(row,20)
     });
    }
    return result.ToArray();
   } finally { Marshal.FreeHGlobal(data); }
  }
  throw new InvalidOperationException("TCP table changed repeatedly during read");
 }
}
'@

if ($SelfTest) {
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
    $client = [Net.Sockets.TcpClient]::new()
    $server = $null
    try {
        $listener.Start()
        $port = $listener.LocalEndpoint.Port
        $client.Connect('127.0.0.1',$port)
        $server = $listener.AcceptTcpClient()
        $localPort = $client.Client.LocalEndPoint.Port
        $rows = @([TargetTcpOwners]::Read('127.0.0.1') | Where-Object {
            $_.LocalPort -eq $localPort -and $_.RemotePort -eq $port -and $_.OwningPid -eq $PID
        })
        if ($rows.Count -ne 1) { throw 'Loopback PID/port attribution failed' }
        'PASS: loopback connection, byte order and process PID verified; no external traffic generated.'
        $dualClient = [Net.Sockets.TcpClient]::new([Net.Sockets.AddressFamily]::InterNetworkV6)
        $dualServer = $null
        try {
            $dualClient.Client.DualMode = $true
            $dualClient.Connect([Net.IPAddress]::Parse('::ffff:127.0.0.1'),$port)
            $dualServer = $listener.AcceptTcpClient()
            $dualLocalPort = $dualClient.Client.LocalEndPoint.Port
            $dualRows = @([TargetTcpOwners]::Read('127.0.0.1') | Where-Object {
                $_.LocalPort -eq $dualLocalPort -and $_.RemotePort -eq $port -and $_.OwningPid -eq $PID
            })
            if ($dualRows.Count -ne 1) { throw 'IPv4-mapped dual-stack process attribution failed' }
            'PASS: IPv4-mapped dual-stack connection is also attributed correctly.'
        } finally {
            if ($dualServer) { $dualServer.Dispose() }
            $dualClient.Dispose()
        }
    } finally {
        if ($server) { $server.Dispose() }
        $client.Dispose(); $listener.Stop()
    }
    exit 0
}

$null = [Net.IPAddress]::Parse($TargetAddress)
$null = New-Item -ItemType Directory -Path $OutputDirectory -Force
$started = [DateTimeOffset]::UtcNow
$deadline = $started.AddHours($DurationHours)
$statusPath = Join-Path $OutputDirectory 'status.json'
$eventsPath = Join-Path $OutputDirectory 'connections.jsonl'
$capturePath = Join-Path $OutputDirectory 'capture.json'
$stopPath = Join-Path $OutputDirectory 'stop'
$script:scans = 0
$script:matches = 0
$script:lastError = $null
$script:phase = 'watching'
$seen = @{}
function Save-Status {
    $status = [ordered]@{
        target = $TargetAddress; protocol = 'TCP/IPv4'; monitorPid = $PID
        phase = $script:phase; startedAt = $started.ToOffset([TimeSpan]::FromHours(8)).ToString('o')
        stopAt = $deadline.ToOffset([TimeSpan]::FromHours(8)).ToString('o')
        heartbeat = [DateTimeOffset]::Now.ToOffset([TimeSpan]::FromHours(8)).ToString('o')
        intervalMilliseconds = 100; scans = $script:scans; matches = $script:matches; error = $script:lastError
    }
    $temporary = $statusPath + '.new'
    [IO.File]::WriteAllText($temporary,($status | ConvertTo-Json -Depth 5))
    Move-Item -LiteralPath $temporary -Destination $statusPath -Force
}
[IO.File]::WriteAllText($eventsPath,'')
$heartbeat = [DateTimeOffset]::MinValue
$failures = 0
try {
    Save-Status
    while ([DateTimeOffset]::UtcNow -lt $deadline -and -not (Test-Path -LiteralPath $stopPath)) {
        try {
            $rows = [TargetTcpOwners]::Read($TargetAddress)
            $script:scans++
            $failures = 0
            foreach ($row in $rows) {
                if ($row.OwningPid -eq 0) { continue }
                $key = '{0}:{1}:{2}' -f $row.OwningPid,$row.LocalPort,$row.RemotePort
                if ($seen.ContainsKey($key)) { continue }
                $observedAt = [DateTimeOffset]::Now.ToOffset([TimeSpan]::FromHours(8)).ToString('o')
                $owner = Get-CimInstance Win32_Process -Filter ('ProcessId={0}' -f $row.OwningPid) -ErrorAction SilentlyContinue
                $path = $owner.ExecutablePath
                if (-not $path) {
                    try { $path = (Get-Process -Id $row.OwningPid -ErrorAction Stop).Path } catch { }
                }
                $record = [ordered]@{
                    observedAt = $observedAt; localAddress = $row.LocalAddress; localPort = $row.LocalPort
                    remoteAddress = $row.RemoteAddress; remotePort = $row.RemotePort
                    tcpState = [string][Net.NetworkInformation.TcpState]$row.State
                    owningPid = $row.OwningPid; processName = $owner.Name; executablePath = $path
                    processCreatedAt = if ($owner.CreationDate) { $owner.CreationDate.ToString('o') } else { $null }
                    parentPid = $owner.ParentProcessId
                    attribution = if ($path) { 'TCP table owning process identified' } else { 'PID observed; executable unavailable, continuing capture' }
                }
                [IO.File]::AppendAllText($eventsPath,($record | ConvertTo-Json -Depth 5 -Compress)+[Environment]::NewLine)
                $script:matches++
                if ($path) {
                    [IO.File]::WriteAllText($capturePath,($record | ConvertTo-Json -Depth 5))
                    $script:phase = 'captured'
                    Save-Status
                    exit 0
                }
                $seen[$key] = $true
            }
            $script:lastError = $null
        } catch {
            $failures++
            $script:lastError = $_.Exception.Message
            if ($failures -ge 10) { throw }
        }
        if (([DateTimeOffset]::UtcNow-$heartbeat).TotalSeconds -ge 10) {
            Save-Status; $heartbeat = [DateTimeOffset]::UtcNow
        }
        Start-Sleep -Milliseconds 100
    }
    $script:phase = if (Test-Path -LiteralPath $stopPath) { 'stopped' } else { 'expired' }
    Save-Status
} catch {
    $script:phase = 'failed'; $script:lastError = $_.Exception.Message
    Save-Status
    throw
}
