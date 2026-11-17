# wifi-diagnose.ps1 — find what's slowing your Wi-Fi down (Windows).
# Read-only: it never changes router or system settings.
# Usage (PowerShell):  powershell -ExecutionPolicy Bypass -File .\wifi-diagnose.ps1

$Problems = New-Object System.Collections.Generic.List[string]
function Flag($m) { $Problems.Add($m); Write-Host "  [!] $m" -ForegroundColor Yellow }
function Ok($m)   { Write-Host "  [ok] $m" -ForegroundColor Green }
function Hdr($m)  { Write-Host "`n== $m ==" -ForegroundColor Cyan }
function Field($text, $name) {
  $line = $text | Select-String -Pattern "^\s*$name\s*:\s*(.+)$" | Select-Object -First 1
  if ($line) { $line.Matches[0].Groups[1].Value.Trim() }
}

# ---------------------------------------------------------------- Wi-Fi link
Hdr "Wi-Fi connection"
$if = netsh wlan show interfaces
$ssid = Field $if 'SSID'; $radio = Field $if 'Radio type'; $band = Field $if 'Band'
$chan = Field $if 'Channel'; $sig = Field $if 'Signal'; $rx = Field $if 'Receive rate \(Mbps\)'; $tx = Field $if 'Transmit rate \(Mbps\)'
if (-not $ssid) {
  Write-Host "  (Not connected to Wi-Fi; wired-only results follow.)"
} else {
  Write-Host "  SSID: $ssid  Radio: $radio  Band: $band  Channel: $chan  Rx/Tx: $rx/$tx Mbps  Signal: $sig"
  $pct = [int]($sig -replace '[^0-9]', '')
  $dbm = [int]($pct / 2 - 100)   # Windows reports %, approx dBm
  if     ($dbm -le -75) { Flag "Very weak signal (~$dbm dBm). Move closer, relocate the router, or add a mesh node." }
  elseif ($dbm -le -67) { Flag "Weak signal (~$dbm dBm); below -67 dBm speeds drop noticeably." }
  else                  { Ok "Signal strength is good (~$dbm dBm)." }
  $chNum = [int]($chan -replace '[^0-9]', '')
  $is24 = ($band -match '2\.4') -or ($chNum -ge 1 -and $chNum -le 14)
  if ($is24) {
    Flag "Connected on 2.4 GHz, which is slower and more crowded. Use the 5 GHz (or 6 GHz) network if you're within range."
    if (@(1, 6, 11) -notcontains $chNum) { Flag "2.4 GHz channel $chNum overlaps neighbours. Set the router to channel 1, 6 or 11." }
  }
  if ($radio -match '802\.11[bgn]$') { Flag "Old Wi-Fi standard ($radio). A Wi-Fi 5/6 router or adapter would be much faster." }

  $nets = netsh wlan show networks mode=bssid
  $same = ($nets | Select-String -Pattern "^\s*Channel\s*:\s*$chNum\s*$").Count - 1
  if ($same -lt 0) { $same = 0 }
  if ($same -ge 5) { Flag "$same other access points share your channel. Pick a less crowded channel in the router settings." }
  else { Ok "$same other access points on your channel." }
}

# ---------------------------------------------------------------- Router
Hdr "Router"
$gw = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Sort-Object RouteMetric | Select-Object -First 1).NextHop
Write-Host "  Gateway: $gw"

function PingStats($target, $n) {
  $r = Test-Connection -ComputerName $target -Count $n -ErrorAction SilentlyContinue
  $ok = @($r).Count
  $times = @($r | ForEach-Object { if ($_.ResponseTime -ne $null) { $_.ResponseTime } else { $_.Latency } })
  $avg = if ($ok) { [math]::Round(($times | Measure-Object -Average).Average, 1) } else { 0 }
  $jit = 0; if ($ok -gt 1) { $d = for ($i = 1; $i -lt $ok; $i++) { [math]::Abs($times[$i] - $times[$i - 1]) }; $jit = [math]::Round(($d | Measure-Object -Average).Average, 1) }
  [pscustomobject]@{ Loss = [math]::Round(100 * ($n - $ok) / $n); Avg = $avg; Max = ($times | Measure-Object -Maximum).Maximum; Jitter = $jit }
}

$g = $null
if ($gw) {
  $g = PingStats $gw 30
  Write-Host "  Ping to router: avg $($g.Avg) ms, max $($g.Max) ms, jitter $($g.Jitter) ms, loss $($g.Loss)%"
  if ($g.Loss -gt 0)    { Flag "Packet loss to your own router ($($g.Loss)%). This is a Wi-Fi link problem (signal or interference), not your ISP." }
  if ($g.Avg -gt 10)    { Flag "High latency to router ($($g.Avg) ms; should be <5 ms). Interference, congestion or an overloaded router." }
  if ($g.Jitter -gt 10) { Flag "High jitter to router ($($g.Jitter) ms). Bad for video calls and gaming." }
  try {
    $resp = Invoke-WebRequest -Uri "http://$gw" -TimeoutSec 4 -UseBasicParsing
    $title = [regex]::Match($resp.Content, '<title>([^<]*)', 'IgnoreCase').Groups[1].Value
    Write-Host "  Router web UI: $title (server: $($resp.Headers['Server'])). Open http://$gw to change channel or firmware."
  } catch {}
  $devices = (arp -a | Select-String 'dynamic').Count
  Write-Host "  Devices this computer has recently seen on the network: $devices"
  if ($devices -ge 25) { Flag "$devices active devices; many devices share airtime. Check the router's client list for unknown or bandwidth-hungry ones." }
}

# ---------------------------------------------------------------- Internet
Hdr "Internet"
$i = PingStats '1.1.1.1' 20
Write-Host "  Ping to 1.1.1.1: avg $($i.Avg) ms, jitter $($i.Jitter) ms, loss $($i.Loss)%"
if ($i.Loss -gt 0 -and $g -and $g.Loss -eq 0) { Flag "Loss to the internet but not to the router: likely your ISP/modem." }

$dns = (Measure-Command { Resolve-DnsName www.wikipedia.org -DnsOnly -ErrorAction SilentlyContinue | Out-Null }).TotalMilliseconds
Write-Host ("  DNS lookup: {0:N0} ms" -f $dns)
if ($dns -gt 150) { Flag ("Slow DNS ({0:N0} ms). Try 1.1.1.1 or 8.8.8.8 as DNS servers on the router." -f $dns) }

Write-Host "  Measuring download speed (25 MB)..."
$sw = [Diagnostics.Stopwatch]::StartNew()
try {
  Invoke-WebRequest -Uri 'https://speed.cloudflare.com/__down?bytes=25000000' -UseBasicParsing -TimeoutSec 60 -OutFile "$env:TEMP\wifi-speedtest.bin"
  $sw.Stop()
  $mbps = [math]::Round(25000000 * 8 / $sw.Elapsed.TotalSeconds / 1e6, 1)
  Remove-Item "$env:TEMP\wifi-speedtest.bin" -ErrorAction SilentlyContinue
  Write-Host "  Download: $mbps Mbps  (compare with your Wi-Fi link rate of $rx Mbps and your ISP plan)"
} catch { Write-Host "  Download test failed: $($_.Exception.Message)" }

# ---------------------------------------------------------------- Summary
Hdr "Summary"
if ($Problems.Count -eq 0) {
  Write-Host "  No obvious problems found. If it's still slow, compare the download speed to your ISP plan and test with a cable."
} else {
  Write-Host "  $($Problems.Count) issue(s) found:"
  $n = 1; foreach ($p in $Problems) { Write-Host "   $n. $p"; $n++ }
}
Write-Host "`n  Tip: also check http://$gw for a firmware update, and reboot the router if it hasn't been in weeks."
