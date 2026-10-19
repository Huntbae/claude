<#
.SYNOPSIS
    Brother DCP-T720DW 네트워크 스캔 오류 진단 및 복구 (Windows 10/11)

.DESCRIPTION
    기본 실행은 진단만 하며 시스템 설정을 바꾸지 않는다.
    -Fix 를 주면 관리자 권한으로 다시 실행한 뒤, 확인을 받고 다음을 적용한다.
      1) '공용'으로 설정된 네트워크 프로필을 '개인'으로 변경
      2) Brother 네트워크 스캔용 방화벽 인바운드 규칙 추가 (UDP 54925/137/161, 로컬 서브넷 한정)
      3) 스캔 관련 Windows 서비스(WIA, 기능 검색) 재시작, '사용 안 함'이면 기본값(수동)으로 복원
      4) 스캐너 응답 재시험 후, 드라이버 주소가 틀리면 '스캐너 및 카메라' 설정 창을 연다
    -Undo 를 주면 이 스크립트가 추가한 방화벽 규칙만 제거한다.

.PARAMETER PrinterIP
    네트워크 구성 보고서에서 확인한 프린터 IP. 지정하면 자동 탐색보다 우선한다.

.PARAMETER Pause
    끝날 때 엔터 입력을 기다린다 (더블클릭 실행용).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\brother-scan-fix.ps1
    powershell -ExecutionPolicy Bypass -File .\brother-scan-fix.ps1 -Fix -PrinterIP 192.168.0.15
#>
[CmdletBinding()]
param(
    [switch]$Fix,
    [switch]$Undo,
    [string]$PrinterIP,
    [switch]$Pause
)

$ErrorActionPreference = 'Continue'
$ModelPattern = 'Brother|DCP-T720'
$ScanPorts = 54925, 137, 161
$RulePrefix = 'Brother Network Scan (brother-scan-fix)'
$ImagingClassKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{6bdd1fc6-810f-11d0-bec7-08002be2092f}'
$IPv4Regex = '\b(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)\b'

# WIA 오류 코드 -> 의미
$WiaErrors = @{
    0x80210001 = '일반 오류'
    0x80210002 = '용지 걸림'
    0x80210003 = '급지 장치(ADF)에 원고 없음'
    0x80210004 = '용지 문제'
    0x80210005 = '장치 오프라인 (주소 불일치 또는 네트워크 차단 가능성이 큼)'
    0x80210006 = '장치 사용 중 (다른 PC나 앱이 스캐너를 점유 중)'
    0x80210007 = '장치 예열 중'
    0x80210008 = '사용자 조치 필요 (기기 화면 확인)'
    0x8021000A = '장치 통신 실패 (네트워크 경로 문제)'
    0x8021000C = '하드웨어 설정 불일치'
    0x8021000D = '장치 잠김'
    0x8021000E = '드라이버 내부 오류 (드라이버 재설치 권장)'
    0x8021000F = '드라이버 응답 오류 (드라이버 재설치 권장)'
    0x80210015 = '사용 가능한 장치 없음'
    0x80210016 = '덮개 열림'
}

$Findings = New-Object System.Collections.Generic.List[string]
$Candidates = [ordered]@{}

function Write-Section([string]$Text) { Write-Host ''; Write-Host "== $Text ==" -ForegroundColor Cyan }
function Write-Ok([string]$Text) { Write-Host "  [정상] $Text" -ForegroundColor Green }
function Write-Info([string]$Text) { Write-Host "  $Text" }
function Write-Warn([string]$Text) {
    Write-Host "  [주의] $Text" -ForegroundColor Yellow
    if (-not $script:Findings.Contains($Text)) { $script:Findings.Add($Text) }
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-IPv4FromText([string]$Text) {
    if (-not $Text) { return @() }
    [regex]::Matches($Text, $IPv4Regex) |
        ForEach-Object { $_.Value } |
        Where-Object { $_ -notmatch '^(0\.|127\.|255\.|169\.254\.)' } |
        Select-Object -Unique
}

function Add-Candidate([string]$Ip, [string]$Source) {
    if ($Ip -and -not $script:Candidates.Contains($Ip)) { $script:Candidates[$Ip] = $Source }
}

function ConvertTo-UInt32([string]$Ip) {
    $bytes = ([System.Net.IPAddress]::Parse($Ip)).GetAddressBytes()
    [Array]::Reverse($bytes)
    [BitConverter]::ToUInt32($bytes, 0)
}

function Test-SameSubnet([string]$A, [string]$B, [int]$Prefix) {
    if ($Prefix -le 0) { return $true }
    $mask = [uint32]([math]::Pow(2, 32) - [math]::Pow(2, 32 - $Prefix))
    ((ConvertTo-UInt32 $A) -band $mask) -eq ((ConvertTo-UInt32 $B) -band $mask)
}

function Test-TcpPort([string]$Ip, [int]$Port, [int]$TimeoutMs = 1000) {
    $client = New-Object System.Net.Sockets.TcpClient
    try { return $client.ConnectAsync($Ip, $Port).Wait($TimeoutMs) }
    catch { return $false }
    finally { $client.Close() }
}

function Get-DeviceTitle([string]$Ip) {
    try {
        $r = Invoke-WebRequest -Uri "http://$Ip/" -UseBasicParsing -TimeoutSec 4 -ErrorAction Stop
        if ($r.Content -match '<title>\s*([^<]+)') { return $Matches[1].Trim() }
    } catch {}
    return $null
}

# 로컬 /24 대역에서 인쇄 포트(9100, 631)가 열린 장치를 찾는다
function Find-PrintersOnLan($PcAddresses) {
    $found = New-Object System.Collections.Generic.List[string]
    $prefixes = $PcAddresses | ForEach-Object { (($_.IPAddress -split '\.')[0..2]) -join '.' } | Select-Object -Unique
    foreach ($prefix in $prefixes) {
        Write-Info "$prefix.0/24 대역에서 프린터를 찾는 중..."
        $pending = New-Object System.Collections.Generic.List[object]
        foreach ($i in 1..254) {
            foreach ($port in 9100, 631) {
                $client = New-Object System.Net.Sockets.TcpClient
                $pending.Add(@{ Ip = "$prefix.$i"; Client = $client; Task = $client.ConnectAsync("$prefix.$i", $port) })
            }
        }
        Start-Sleep -Milliseconds 1500
        foreach ($p in $pending) {
            if ($p.Task.Status -eq 'RanToCompletion' -and -not $found.Contains($p.Ip)) { $found.Add($p.Ip) }
            $p.Client.Close()
        }
    }
    $found | Where-Object { $PcAddresses.IPAddress -notcontains $_ }
}

function Get-WiaHResult($ErrorRecord) {
    $e = $ErrorRecord.Exception
    while ($e.InnerException) { $e = $e.InnerException }
    $e.HResult
}

# Brother 스캐너에 WIA로 연결해 본다. 반환: $true(정상) / $false(실패) / $null(스캐너 미인식)
function Test-WiaScanner {
    try { $dm = New-Object -ComObject WIA.DeviceManager }
    catch { Write-Warn 'Windows 스캔 구성요소(WIA)를 불러오지 못했습니다.'; return $null }

    Write-Info '스캐너에 연결하는 중입니다 (최대 30초 걸릴 수 있음)...'
    $result = $null
    foreach ($info in $dm.DeviceInfos) {
        if ($info.Type -ne 1) { continue }  # 1 = 스캐너
        $name = ($info.Properties | Where-Object { $_.Name -eq 'Name' }).Value
        if ($name -notmatch $ModelPattern) { continue }
        try {
            $null = $info.Connect()
            Write-Ok "스캐너 '$name' 연결 응답 정상"
            if ($result -ne $false) { $result = $true }
        } catch {
            # HResult와 표의 16진수 키는 모두 부호 있는 Int32라 그대로 조회된다
            $hr = Get-WiaHResult $_
            $code = '0x{0:X8}' -f $hr
            $meaning = $WiaErrors[$hr]
            if (-not $meaning) { $meaning = $_.Exception.Message }
            Write-Warn "스캐너 '$name' 연결 실패: $code $meaning"
            $result = $false
        }
    }
    if ($null -eq $result) { Write-Warn 'Windows가 Brother 스캐너를 인식하지 못합니다. 스캐너 드라이버가 없거나 손상되었을 수 있습니다.' }
    return $result
}

function Get-OurFirewallRules {
    Get-NetFirewallRule -DisplayName "$RulePrefix*" -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# 관리자 권한 확보 (-Fix, -Undo)
# ---------------------------------------------------------------------------
if (($Fix -or $Undo) -and -not (Test-Admin)) {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-Pause')
    if ($Fix) { $argList += '-Fix' }
    if ($Undo) { $argList += '-Undo' }
    if ($PrinterIP) { $argList += @('-PrinterIP', $PrinterIP) }
    Write-Host '관리자 권한이 필요합니다. 사용자 계정 컨트롤 창에서 [예]를 눌러 주세요.'
    try { Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList -ErrorAction Stop }
    catch {
        Write-Host "관리자 권한 실행이 취소되었습니다: $($_.Exception.Message)" -ForegroundColor Yellow
        if ($Pause) { Read-Host '엔터를 누르면 창이 닫힙니다' | Out-Null }
    }
    return
}

if ($Undo) {
    $rules = @(Get-OurFirewallRules)
    if ($rules) {
        $rules | Remove-NetFirewallRule
        Write-Host "이 스크립트가 추가한 방화벽 규칙 $($rules.Count)개를 제거했습니다."
    } else {
        Write-Host '제거할 방화벽 규칙이 없습니다.'
    }
    Write-Host '네트워크 프로필(개인/공용)은 [설정 > 네트워크 및 인터넷 > 속성]에서 직접 되돌릴 수 있습니다.'
    if ($Pause) { Read-Host '엔터를 누르면 창이 닫힙니다' | Out-Null }
    return
}

$ReportDir = [Environment]::GetFolderPath('Desktop')
if (-not $ReportDir) { $ReportDir = $env:TEMP }
if (-not $ReportDir) { $ReportDir = (Get-Location).Path }
$ReportPath = Join-Path $ReportDir ('brother-scan-report-{0:yyyyMMdd-HHmmss}.txt' -f (Get-Date))
try { Start-Transcript -Path $ReportPath -ErrorAction Stop | Out-Null } catch { $ReportPath = $null }

Write-Host 'Brother DCP-T720DW 스캔 진단을 시작합니다.' -ForegroundColor Cyan
if (-not $Fix) { Write-Host '진단 모드: 시스템 설정은 바꾸지 않습니다.' }

# ---------------------------------------------------------------------------
Write-Section '1. 시스템'
$os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
Write-Info "Windows: $($os.Caption) (빌드 $($os.BuildNumber))"
Write-Info ('관리자 권한: {0}' -f $(if (Test-Admin) { '예' } else { '아니오' }))

# ---------------------------------------------------------------------------
Write-Section '2. PC 네트워크'
$PcAddresses = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' -and $_.InterfaceAlias -notmatch 'Loopback|vEthernet|VirtualBox|VMware' })
foreach ($a in $PcAddresses) { Write-Info "$($a.InterfaceAlias): $($a.IPAddress)/$($a.PrefixLength)" }
if (-not $PcAddresses) { Write-Warn 'PC에 유효한 IPv4 주소가 없습니다. Wi-Fi 또는 유선 연결을 확인하세요.' }

$PublicProfiles = @()
foreach ($p in @(Get-NetConnectionProfile -ErrorAction SilentlyContinue)) {
    if ($p.NetworkCategory -eq 'Public') {
        Write-Warn "네트워크 '$($p.Name)'이(가) '공용'으로 설정되어 있어 스캔 응답이 차단될 수 있습니다."
        $PublicProfiles += $p
    } else {
        Write-Ok "네트워크 '$($p.Name)': $($p.NetworkCategory)"
    }
}

$vpnPattern = 'VPN|TAP-|WireGuard|Wintun|AnyConnect|Fortinet|FortiClient|Pulse Secure|GlobalProtect|PANGP|Zscaler|OpenVPN'
foreach ($v in @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' -and "$($_.Name) $($_.InterfaceDescription)" -match $vpnPattern })) {
    Write-Warn "VPN 어댑터가 켜져 있습니다: $($v.Name). VPN은 같은 공간의 프린터와의 통신을 막을 수 있으니 끊고 다시 시도하세요."
}

# ---------------------------------------------------------------------------
Write-Section '3. Brother 소프트웨어'
$uninstallKeys = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
)
$brotherApps = @(Get-ItemProperty $uninstallKeys -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -match 'Brother|iPrint&Scan|ControlCenter' } |
    Sort-Object DisplayName -Unique)
if ($brotherApps) {
    foreach ($app in $brotherApps) { Write-Info "$($app.DisplayName) $($app.DisplayVersion)" }
} else {
    Write-Warn 'Brother 드라이버/앱 설치 기록이 없습니다. 브라더 고객지원 사이트에서 DCP-T720DW용 Full Driver & Software Package를 설치하세요.'
}
if (-not ($brotherApps | Where-Object { $_.DisplayName -match 'iPrint&Scan' })) {
    Write-Info '참고: Brother iPrint&Scan이 보이지 않습니다. PC에서 스캔하려면 설치를 권장합니다.'
}

# ---------------------------------------------------------------------------
Write-Section '4. Windows에 등록된 Brother 장치'
foreach ($pr in @(Get-Printer -ErrorAction SilentlyContinue | Where-Object { $_.Name -match $ModelPattern -or $_.DriverName -match $ModelPattern })) {
    $port = Get-PrinterPort -Name $pr.PortName -ErrorAction SilentlyContinue
    $hostAddr = if ($port) { $port.PrinterHostAddress } else { $null }
    Write-Info "프린터: $($pr.Name) / 포트: $($pr.PortName)$(if ($hostAddr) { " / 주소: $hostAddr" })"
    if ($hostAddr) {
        $ips = @(Get-IPv4FromText $hostAddr)
        if (-not $ips) {
            try { $ips = @([System.Net.Dns]::GetHostAddresses($hostAddr) | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | ForEach-Object { $_.ToString() }) } catch {}
        }
        foreach ($ip in $ips) { Add-Candidate $ip "프린터 포트($($pr.Name))" }
    }
}

foreach ($d in @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.FriendlyName -match $ModelPattern })) {
    Write-Info "장치: $($d.FriendlyName) [$($d.Class)] 상태: $($d.Status)"
    if ($d.Class -eq 'Image' -and $d.Status -ne 'OK') { Write-Warn "스캐너 장치 '$($d.FriendlyName)' 상태가 '$($d.Status)'입니다." }
    foreach ($prop in @(Get-PnpDeviceProperty -InstanceId $d.InstanceId -ErrorAction SilentlyContinue)) {
        foreach ($ip in @(Get-IPv4FromText ([string]($prop.Data -join ' ')))) { Add-Candidate $ip "장치 정보($($d.FriendlyName))" }
    }
}

# 스캐너 드라이버에 저장된 주소 (읽기만 함)
$DriverIPs = New-Object System.Collections.Generic.List[string]
foreach ($key in @(Get-ChildItem $ImagingClassKey -ErrorAction SilentlyContinue)) {
    $desc = (Get-ItemProperty $key.PSPath -ErrorAction SilentlyContinue).DriverDesc
    if ($desc -notmatch $ModelPattern) { continue }
    Write-Info "스캐너 드라이버: $desc"
    foreach ($k in @($key) + @(Get-ChildItem $key.PSPath -Recurse -ErrorAction SilentlyContinue)) {
        foreach ($n in $k.GetValueNames()) {
            foreach ($ip in @(Get-IPv4FromText ([string]($k.GetValue($n) -join ' ')))) {
                if (-not $DriverIPs.Contains($ip)) { $DriverIPs.Add($ip) }
            }
        }
    }
}
if ($DriverIPs.Count -gt 0) { Write-Info "스캐너 드라이버에 저장된 주소: $($DriverIPs -join ', ')" }
foreach ($ip in $DriverIPs) { Add-Candidate $ip '스캐너 드라이버 설정' }

# ---------------------------------------------------------------------------
Write-Section '5. 프린터 연결 시험'
if ($PrinterIP) {
    if (-not ($PrinterIP -match "^$IPv4Regex$")) { Write-Warn "입력한 주소 '$PrinterIP'는 올바른 IPv4 형식이 아닙니다." }
    else {
        $manual = [ordered]@{ $PrinterIP = '직접 입력' }
        foreach ($k in $Candidates.Keys) { if ($k -ne $PrinterIP) { $manual[$k] = $Candidates[$k] } }
        $Candidates = $manual
    }
}

$Results = @()
function Test-Candidate([string]$Ip, [string]$Source) {
    $ping = Test-Connection -ComputerName $Ip -Count 2 -Quiet -ErrorAction SilentlyContinue
    $web = Test-TcpPort $Ip 80
    $raw = Test-TcpPort $Ip 9100
    $title = if ($web) { Get-DeviceTitle $Ip } else { $null }
    $reachable = $ping -or $web -or $raw
    $state = if ($reachable) { '응답함' } else { '응답 없음' }
    $suffix = if ($title) { " / $title" } else { '' }
    Write-Info ("{0,-15} [{1}] {2}{3}" -f $Ip, $Source, $state, $suffix)
    [pscustomobject]@{ Ip = $Ip; Source = $Source; Reachable = $reachable; Title = $title; IsBrother = ($title -match $ModelPattern) }
}

foreach ($ip in @($Candidates.Keys)) { $Results += Test-Candidate $ip $Candidates[$ip] }

if (-not ($Results | Where-Object { $_.Reachable }) -and $PcAddresses) {
    foreach ($ip in @(Find-PrintersOnLan $PcAddresses)) {
        if ($Candidates.Contains($ip)) { continue }
        Add-Candidate $ip 'LAN 탐색'
        $Results += Test-Candidate $ip 'LAN 탐색'
    }
}

$Reachable = @($Results | Where-Object { $_.Reachable })
$Printer = @($Reachable | Where-Object { $_.IsBrother }) + @($Reachable | Where-Object { -not $_.IsBrother }) | Select-Object -First 1
$NeedAddressUpdate = $false

if (-not $Printer) {
    Write-Warn '프린터를 네트워크에서 찾지 못했습니다. 프린터 Wi-Fi 연결 상태를 확인하고, 네트워크 구성 보고서의 IP로 다시 실행하세요 (-PrinterIP).'
} else {
    $label = if ($Printer.Title) { $Printer.Title } else { 'Brother 여부 미확인' }
    Write-Ok "프린터 주소: $($Printer.Ip) ($label)"
    if (-not $Printer.IsBrother -and $Reachable.Count -gt 1) {
        Write-Info "응답한 장치가 여러 개입니다. 네트워크 구성 보고서의 IP와 같은지 확인하세요: $(($Reachable | ForEach-Object { $_.Ip }) -join ', ')"
    }
    $sameNet = $PcAddresses | Where-Object { Test-SameSubnet $_.IPAddress $Printer.Ip $_.PrefixLength }
    if (-not $sameNet) { Write-Warn "프린터($($Printer.Ip))가 PC와 다른 네트워크에 있습니다. 게스트 Wi-Fi나 다른 공유기에 연결되어 있지 않은지 확인하세요." }
    if ($DriverIPs.Count -gt 0 -and -not $DriverIPs.Contains($Printer.Ip)) {
        Write-Warn "스캐너 드라이버에 저장된 주소($($DriverIPs -join ', '))와 실제 프린터 주소($($Printer.Ip))가 다릅니다. 스캔 오류의 가장 유력한 원인입니다."
        $NeedAddressUpdate = $true
    }
}

# ---------------------------------------------------------------------------
Write-Section '6. Windows 서비스'
# 재시작 순서: 기반 서비스(fdPHost) 먼저
$Services = [ordered]@{
    fdPHost  = '기능 검색 공급자 호스트'
    FDResPub = '기능 검색 리소스 게시'
    stisvc   = 'Windows 이미지 획득(WIA)'
}
foreach ($n in $Services.Keys) {
    $s = Get-Service -Name $n -ErrorAction SilentlyContinue
    if (-not $s) { Write-Warn "$($Services[$n]) 서비스($n)를 찾을 수 없습니다."; continue }
    # 기본 시작 유형이 '수동(트리거 시작)'이라 멈춰 있는 것 자체는 정상이다
    if ($s.StartType -eq 'Disabled') {
        Write-Warn "$($Services[$n]) 서비스가 '사용 안 함'으로 설정되어 있습니다."
    } elseif ($s.Status -eq 'Running') {
        Write-Ok "$($Services[$n]) 서비스 실행 중"
    } else {
        Write-Info "$($Services[$n]) 서비스: $($s.Status) (필요할 때 시작되는 서비스)"
    }
}

# ---------------------------------------------------------------------------
Write-Section '7. 방화벽 및 보안 프로그램'
$MissingPorts = @()
if (-not (Get-NetFirewallProfile -ErrorAction SilentlyContinue | Where-Object { $_.Enabled })) {
    Write-Info 'Windows 방화벽이 꺼져 있습니다.'
} else {
    $udpFilters = @(Get-NetFirewallPortFilter -All -PolicyStore ActiveStore -ErrorAction SilentlyContinue | Where-Object { $_.Protocol -eq 'UDP' })
    foreach ($port in $ScanPorts) {
        $allowed = $false
        foreach ($pf in @($udpFilters | Where-Object { @($_.LocalPort) -contains "$port" })) {
            $r = Get-NetFirewallRule -AssociatedNetFirewallPortFilter $pf -ErrorAction SilentlyContinue
            if ($r -and $r.Enabled -eq 'True' -and $r.Direction -eq 'Inbound' -and $r.Action -eq 'Allow') { $allowed = $true; break }
        }
        if ($allowed) { Write-Ok "UDP $port 수신 허용 규칙 있음" }
        else { $MissingPorts += $port }
    }
    if ($MissingPorts) {
        $brotherRules = @(Get-NetFirewallRule -PolicyStore ActiveStore -Direction Inbound -Enabled True -Action Allow -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -match 'Brother' })
        $note = if ($brotherRules) { " (Brother 프로그램 허용 규칙 $($brotherRules.Count)개는 있음)" } else { '' }
        Write-Warn "Brother 네트워크 스캔 포트 수신 허용 규칙이 없습니다: UDP $($MissingPorts -join ', ')$note"
    }
}
try {
    $thirdParty = @(Get-CimInstance -Namespace root/SecurityCenter2 -ClassName FirewallProduct -ErrorAction Stop | ForEach-Object { $_.displayName })
    $thirdParty += @(Get-CimInstance -Namespace root/SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction Stop |
        Where-Object { $_.displayName -notmatch 'Windows Defender|Microsoft Defender' } | ForEach-Object { $_.displayName })
    foreach ($name in ($thirdParty | Select-Object -Unique)) {
        Write-Warn "별도 보안 프로그램이 설치되어 있습니다: $name. 이 프로그램의 방화벽이 스캔을 막을 수 있으니 Brother 프로그램을 예외로 등록하세요."
    }
} catch {}

# ---------------------------------------------------------------------------
Write-Section '8. 스캐너 응답 시험'
$WiaOk = Test-WiaScanner

# ---------------------------------------------------------------------------
if ($Fix) {
    Write-Section '복구 작업'
    $plan = @()
    if ($PublicProfiles) { $plan += "네트워크 프로필 '공용' -> '개인' 변경: $(($PublicProfiles | ForEach-Object { $_.Name }) -join ', ')" }
    if ($MissingPorts) { $plan += "방화벽 수신 허용 규칙 추가: UDP $($MissingPorts -join ', ') (로컬 서브넷에서 오는 연결만)" }
    $plan += 'WIA, 기능 검색 서비스 재시작 ("사용 안 함"이면 기본값인 수동으로 복원). 실행 중인 스캔 앱은 미리 닫아 주세요'
    foreach ($item in $plan) { Write-Info "- $item" }
    if ($PublicProfiles) { Write-Info '주의: 집이나 사무실처럼 신뢰할 수 있는 네트워크일 때만 진행하세요. 카페 등 공용 Wi-Fi라면 N을 누르세요.' }

    $answer = Read-Host '위 작업을 진행할까요? (Y/N)'
    if ($answer -match '^(y|yes|예|네)$') {
        foreach ($p in $PublicProfiles) {
            try { Set-NetConnectionProfile -InterfaceIndex $p.InterfaceIndex -NetworkCategory Private -ErrorAction Stop; Write-Ok "'$($p.Name)' 네트워크를 개인으로 변경" }
            catch { Write-Warn "'$($p.Name)' 네트워크 프로필 변경 실패: $($_.Exception.Message)" }
        }

        if ($MissingPorts) {
            Get-OurFirewallRules | Remove-NetFirewallRule -ErrorAction SilentlyContinue
            foreach ($port in $ScanPorts) {
                try {
                    New-NetFirewallRule -DisplayName "$RulePrefix UDP $port" -Direction Inbound -Protocol UDP -LocalPort $port `
                        -Action Allow -RemoteAddress LocalSubnet -Profile Domain, Private -ErrorAction Stop | Out-Null
                    Write-Ok "방화벽 규칙 추가: UDP $port"
                } catch { Write-Warn "방화벽 규칙 추가 실패(UDP $port): $($_.Exception.Message)" }
            }
        }

        foreach ($n in $Services.Keys) {
            try {
                if ((Get-Service -Name $n -ErrorAction Stop).StartType -eq 'Disabled') {
                    Set-Service -Name $n -StartupType Manual -ErrorAction Stop
                    Write-Ok "$($Services[$n]) 서비스 시작 유형을 기본값(수동)으로 복원"
                }
                Restart-Service -Name $n -Force -ErrorAction Stop
                Write-Ok "$($Services[$n]) 서비스 재시작"
            } catch { Write-Warn "$($Services[$n]) 서비스 재시작 실패: $($_.Exception.Message)" }
        }
        # -Force 재시작이 의존 서비스를 멈춘 채로 둘 수 있어 다시 확인한다
        foreach ($n in $Services.Keys) {
            if ((Get-Service -Name $n -ErrorAction SilentlyContinue).Status -ne 'Running') {
                Start-Service -Name $n -ErrorAction SilentlyContinue
            }
        }

        Start-Sleep -Seconds 3
        Write-Section '복구 후 스캐너 응답 재시험'
        $WiaOk = Test-WiaScanner

        if ($NeedAddressUpdate -or $WiaOk -eq $false) {
            Write-Host ''
            Write-Host "'스캐너 및 카메라' 창을 엽니다. 다음 순서로 주소를 다시 지정하세요." -ForegroundColor Cyan
            Write-Info '1) Brother DCP-T720DW 선택 -> [속성]'
            Write-Info '2) [네트워크 설정] 탭 -> [주소로 기기 지정] 선택'
            if ($Printer) { Write-Info "3) IP 주소 칸에 $($Printer.Ip) 입력 -> [확인]" }
            else { Write-Info '3) 네트워크 구성 보고서의 IP 입력 -> [확인]' }
            Write-Info '4) Brother iPrint&Scan을 쓰는 경우 앱에서 [기기 선택]을 다시 하세요.'
            Start-Process -FilePath 'control.exe' -ArgumentList '/name Microsoft.ScannersAndCameras'
        }
    } else {
        Write-Info '복구 작업을 취소했습니다. 시스템 설정은 바뀌지 않았습니다.'
    }
}

# ---------------------------------------------------------------------------
Write-Section $(if ($Fix) { '요약 (진단에서 발견한 항목, 복구 전 기준)' } else { '요약' })
if ($Findings.Count -eq 0) {
    Write-Ok '자동 점검에서 문제를 찾지 못했습니다.'
    Write-Info '그래도 오류가 나면 Brother iPrint&Scan을 최신 버전으로 다시 설치하고, 화면의 에러 문구를 확인하세요.'
} else {
    $i = 1
    foreach ($f in $Findings) { Write-Info "$i. $f"; $i++ }
}
if ($Printer) { Write-Info "권장: 공유기 관리 페이지에서 프린터 IP($($Printer.Ip))를 고정(DHCP 예약)하면 같은 오류가 재발하지 않습니다." }
if ($Findings.Count -gt 0 -and -not $Fix) { Write-Host ''; Write-Host '자동 복구를 하려면 run-fix.cmd 를 실행하세요.' -ForegroundColor Cyan }

if ($ReportPath) {
    Write-Host ''
    Write-Host "진단 기록 저장 위치: $ReportPath"
    Stop-Transcript | Out-Null
}
if ($Pause) { Read-Host '엔터를 누르면 창이 닫힙니다' | Out-Null }
