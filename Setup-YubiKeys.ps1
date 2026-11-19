<#
.SYNOPSIS
    Set up ETS bench YubiKeys, one after another, on the dedicated Windows 11 provisioning laptop.

.DESCRIPTION
    It finds every YubiKey plugged in itself and lists them NUMBERED; the list follows keys as they
    are plugged in and out, live. The technician types the number of the key to work on; every ykman
    call then names that key by its serial (--device), and the technician is told exactly which key
    to touch. After a key is done the live list comes back.

    For the key picked it:
      1. REPORTS what it sees, in full: the USB device Windows sees (Yubico, vendor 1050, and what its
         product number means), what ykman says about the key (model, serial, firmware, which
         applications are on and off), and what each of the two OTP slots holds (programmed / empty).
         The same report goes into a log file whose path is printed at the start and the end;
      2. tells a key that can never type a code (a FIDO-only key: the "Security Key" series) from one
         whose OTP part is switched off, and from one that can, and says which in plain words -- and
         says so when it CANNOT tell (a key whose OTP is off or absent, read without administrator).
         A YubiKey 5 with OTP switched off is offered a one-step switch-on;
      3. reads what the key types today: a SHORT press (slot 1) and a LONG press (slot 2, ~3 s),
         masked, never echoed and never written to the log;
      4. decides from that what to do -- a new key, a key already set up, or a key that holds
         something else. For anything it cannot use as it is, it OFFERS A RESET (type RESET): the
         short press gets the bench start command and the long press a NEW ETS one-time code that
         the provisioning service checks itself. Nothing is changed without that typed word;
      5. checks both presses again, and ENROLS the key to the person who will carry it, there and
         then: from that moment its long press signs in at the bench.

    It installs what it needs itself, from Yubico and only if Windows confirms the installer is signed
    by Yubico AB, and upgrades either when Yubico publishes a newer one: the YubiKey Manager command
    line (ykman; held to version 5.x, never a 6.x until tested), and the Yubico Authenticator app (the window that SHOWS the key; Yubico retired the old "YubiKey Manager" window
    on 2026-02-19 and points to Authenticator instead). It opens Authenticator so the technician can
    see the key it is working on.

    It runs as administrator and reopens itself as administrator if it is not: Windows lets only an
    administrator talk to the FIDO part of a key, and some keys have nothing else. If Windows does not
    open the administrator window (the question was dismissed, or a mistyped administrator password),
    it says why and asks again, up to 3 times, before carrying on without administrator.

    Enrolling needs one sign-in at the start of the session, the same one the bench asks for: a long
    press of YOUR OWN enrolled key, or the pilot code while pilot mode is open. That is what stops a
    stranger on the office network enrolling a key for themselves. Every enrolment records who made it.
    The provisioning service answers only the office network, so enrol in the office.

    The FIDO2 / passkey / smart-card parts of a key are NOT touched (nor its Authenticator codes) --
    only the two OTP slots, and only after the technician agrees.
    Procedure: the review report, section 13, "Enrol a technician's YubiKey".

.PARAMETER Service
    The provisioning service. Default: the production one. Office network only.

.PARAMETER NoElevate
    Do not reopen as administrator. FIDO-only keys cannot be read then.

.EXAMPLE
    irm https://raw.githubusercontent.com/ETS-MSE/yubikey-bench-setup/v1.3.0/Setup-YubiKeys.ps1 | iex
    Runs the published copy from Windows Terminal (Windows PowerShell or PowerShell 7), on any network.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Setup-YubiKeys.ps1
#>
[CmdletBinding()]
param(
    [string]$Service = 'https://func-ets-provision-cc.azurewebsites.net',
    [switch]$NoElevate
)
$ErrorActionPreference = 'Stop'
# Windows PowerShell 5.1 may still offer TLS 1.0 first; the service accepts 1.2 only.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$ScriptVersion = '1.3.3'
# Where this exact version is published; used only to reopen it as administrator after `irm | iex`.
$SelfUrl = "https://raw.githubusercontent.com/ETS-MSE/yubikey-bench-setup/v$ScriptVersion/Setup-YubiKeys.ps1"

# The start command. EXACTLY 38 characters: the most a YubiKey static slot holds.
$Command    = 'curl https://ets.azurewebsites.net|cmd'
# What keys set up before 2026-10-29 may type. Replaced without asking: it is ours, and dead.
$OldCommand = 'curl https://p.exchangetech.ca/b|cmd'
# A Yubico OTP: modhex letters only, 44 long (12 public id + 32).
$OtpPattern = '^[cbdefghijklnrtuv]{44}$'
$Modhex     = 'cbdefghijklnrtuv'

# The oldest ykman this script is written against. A missing or older one is replaced by the newest.
$YkmanFloor   = [version]'5.0.0'
# ykman is HELD to this major version: the newest 5.x is installed and upgraded to, never a 6.x.
# ykman 6 is a rewrite (Rust, in beta at 2026-11-19) and this script reads what ykman PRINTS; a new
# major is allowed only after it has been tested here (operator, 2026-11-19). A 6.x copy already on
# the laptop is ignored, not used.
$YkmanMajor   = 5
# Yubico's own release folders; the signed Windows installers are published there.
$YkmanReleases = 'https://developers.yubico.com/yubikey-manager/Releases/'
$AuthenticatorReleases = 'https://developers.yubico.com/yubioath-flutter/Releases/'
# Each release page is read ONCE per run (Get-ReleasePage); the install, upgrade and report use that copy.
$script:ReleasePages = @{}

# What a Yubico USB product number (vendor 1050) means. The product number changes with which parts
# of the key are switched ON, so it tells a FIDO-only key from one that can type a code, even when
# ykman cannot open the key at all.
$YubicoPids = @{
    '0010' = @{ Name = 'YubiKey (first generation)';           Otp = $true;  Fido = $false }
    '0110' = @{ Name = 'YubiKey NEO: OTP';                     Otp = $true;  Fido = $false }
    '0111' = @{ Name = 'YubiKey NEO: OTP + smart card';        Otp = $true;  Fido = $false }
    '0112' = @{ Name = 'YubiKey NEO: smart card only';         Otp = $false; Fido = $false }
    '0113' = @{ Name = 'YubiKey NEO: FIDO only';               Otp = $false; Fido = $true }
    '0114' = @{ Name = 'YubiKey NEO: OTP + FIDO';              Otp = $true;  Fido = $true }
    '0115' = @{ Name = 'YubiKey NEO: FIDO + smart card';       Otp = $false; Fido = $true }
    '0116' = @{ Name = 'YubiKey NEO: OTP + FIDO + smart card'; Otp = $true;  Fido = $true }
    '0120' = @{ Name = 'Security Key by Yubico: FIDO only (has no OTP part at all)'; Otp = $false; Fido = $true }
    '0401' = @{ Name = 'YubiKey 4/5: OTP only';                Otp = $true;  Fido = $false }
    '0402' = @{ Name = 'YubiKey 4/5 with OTP switched off, or a Security Key: FIDO only'; Otp = $false; Fido = $true }
    '0403' = @{ Name = 'YubiKey 4/5: OTP + FIDO';              Otp = $true;  Fido = $true }
    '0404' = @{ Name = 'YubiKey 4/5: smart card only';         Otp = $false; Fido = $false }
    '0405' = @{ Name = 'YubiKey 4/5: OTP + smart card';        Otp = $true;  Fido = $false }
    '0406' = @{ Name = 'YubiKey 4/5: FIDO + smart card (OTP switched off)'; Otp = $false; Fido = $true }
    '0407' = @{ Name = 'YubiKey 4/5: OTP + FIDO + smart card'; Otp = $true;  Fido = $true }
    '0410' = @{ Name = 'YubiKey Plus';                         Otp = $true;  Fido = $true }
}
# USB products that say the OTP part is OFF on a key that may have one (a YubiKey 5 / NEO with OTP
# switched off) or may not (a Security Key also shows as 0402). Without administrator ykman cannot
# open such a key, so which of the two it is CANNOT be told: the script says so instead of guessing.
# Only 0120 is FIDO-only by its USB product alone (Security Key by Yubico).
$OtpOffPids = @('0402', '0406', '0113', '0115')
# What `ykman list` prints in [brackets] (the USB interfaces switched on) -> the USB products it can be.
# Used to tell which line of `ykman list` is which USB device Windows sees.
$IfacePids = @{
    'OTP'           = @('0010', '0110', '0401')
    'FIDO'          = @('0113', '0120', '0402')
    'OTP+FIDO'      = @('0114', '0403', '0410')
    'CCID'          = @('0112', '0404')
    'OTP+CCID'      = @('0111', '0405')
    'FIDO+CCID'     = @('0115', '0406')
    'OTP+FIDO+CCID' = @('0116', '0407')
}

function Test-Admin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-Blob {
    # A block of tool output, indented, so the technician (and the log) see exactly what was seen.
    param([string]$Title, [string]$Text)
    Write-Host "  ---- $Title" -ForegroundColor DarkCyan
    if (-not $Text) { $Text = '(nothing)' }
    foreach ($l in ($Text -split "`r?`n")) { Write-Host "  | $l" }
}

# ------------------------------------------------------------------------------- installs

function Get-ReleasePage {
    # The HTML of one of Yubico's release folders, fetched ONCE per run: every later ask (the install,
    # the upgrade, the Tools report) gets the same copy. $null, and why printed, if it cannot be read.
    param([string]$Releases)
    if ($script:ReleasePages.ContainsKey($Releases)) { return $script:ReleasePages[$Releases] }
    $ProgressPreference = 'SilentlyContinue'
    $html = $null
    try {
        $html = (Invoke-WebRequest -Uri $Releases -UseBasicParsing).Content
    } catch {
        Write-Host "  Could not read Yubico's release page $Releases ($($_.Exception.Message))." -ForegroundColor Yellow
    }
    $script:ReleasePages[$Releases] = $html
    return $html
}

function Select-YubicoRelease {
    # The newest PLAIN x.y.z among the "$Prefix-<x.y.z>-win64.msi" installers named in a release
    # page's HTML, compared as a [version] (5.10.0 > 5.9.2). With -Major, only that major (ykman is
    # held to 5.x). A beta or release candidate (6.0.0-beta.1, 5.11.0rc1) never matches -- the three
    # numbers must be followed directly by -win64 -- and nor does the .msi.sig beside each installer.
    # $null if there is none.
    param([string]$Html, [string]$Prefix, [int]$Major = 0)
    if (-not $Html) { return $null }
    $all = @([regex]::Matches($Html, [regex]::Escape($Prefix) + '-(\d+\.\d+\.\d+)-win64\.msi(?!\.sig)') |
        ForEach-Object { [version]$_.Groups[1].Value })
    if ($Major) { $all = @($all | Where-Object { $_.Major -eq $Major }) }
    return ($all | Sort-Object -Descending | Select-Object -First 1)
}

function Get-NewestYubicoRelease {
    param([string]$Releases, [string]$Prefix, [int]$Major = 0)
    return (Select-YubicoRelease -Html (Get-ReleasePage $Releases) -Prefix $Prefix -Major $Major)
}

function Install-YubicoMsi {
    # Installs (or upgrades to) $Version of "$Prefix-<version>-win64.msi" from $Releases -- the version
    # the caller already picked from the release page, so the page is not fetched again -- from Yubico
    # itself; run only if Windows says it is signed by Yubico AB. $true on success.
    param([string]$Releases, [string]$Prefix, [string]$What, [version]$Version)
    $ProgressPreference = 'SilentlyContinue'   # Windows PowerShell 5.1 downloads ~10x slower with the bar
    $newest = $Version
    if (-not $newest) {
        Write-Host "  Could not find the $What installer on $Releases" -ForegroundColor Red
        return $false
    }
    $name = "$Prefix-$newest-win64.msi"
    $dir  = Join-Path $env:TEMP ('ets-yubico-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir | Out-Null
    $msi  = Join-Path $dir $name
    $log  = Join-Path $dir 'install.log'
    $ok   = $false
    try {
        Write-Host "  Downloading $name from Yubico ..."
        Invoke-WebRequest -Uri ($Releases + $name) -OutFile $msi -UseBasicParsing
        $sig = Get-AuthenticodeSignature -FilePath $msi
        $signer = '(none)'
        if ($sig.SignerCertificate) { $signer = $sig.SignerCertificate.Subject }
        if ($sig.Status -ne 'Valid' -or $signer -notmatch '(^|,\s*)O=Yubico AB(,|$)') {
            Write-Host "  REFUSED: the download is not validly signed by Yubico AB (signature $($sig.Status), signer $signer)." -ForegroundColor Red
            Write-Host '  Nothing was installed.' -ForegroundColor Red
            return $false
        }
        Write-Host "  Signature: Valid, signed by Yubico AB. Installing $What $newest ..."
        $msiArgs = @('/i', "`"$msi`"", '/qn', '/norestart', '/l*v', "`"$log`"")
        if (Test-Admin) {
            $proc = Start-Process -FilePath msiexec.exe -ArgumentList $msiArgs -Wait -PassThru
        } else {
            Write-Host '  Windows will ask to allow the install (once per laptop): choose Yes.' -ForegroundColor Yellow
            try {
                $proc = Start-Process -FilePath msiexec.exe -ArgumentList $msiArgs -Verb RunAs -Wait -PassThru
            } catch {
                Write-Host "  The install was not allowed, so $What $newest was not installed. Run the line again and choose Yes." -ForegroundColor Red
                return $false
            }
        }
        # 3010: installed, a restart is pending -- both tools work without it.
        if ($proc.ExitCode -notin @(0, 3010)) {
            Write-Host "  The $What installer failed (msiexec exit $($proc.ExitCode)). Its log is kept at $log" -ForegroundColor Red
            return $false
        }
        $ok = $true
        return $true
    } finally {
        if ($ok) { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
        else     { Remove-Item -LiteralPath $msi -Force -ErrorAction SilentlyContinue }
    }
}

function Install-Ykman {
    param([version]$Version)
    Install-YubicoMsi -Releases $YkmanReleases -Prefix 'yubikey-manager' -What 'ykman (YubiKey Manager command line)' -Version $Version
}

function Install-Authenticator {
    param([version]$Version)
    Install-YubicoMsi -Releases $AuthenticatorReleases -Prefix 'yubico-authenticator' -What 'Yubico Authenticator' -Version $Version
}

function Get-YkmanVersion {
    param([string]$Path)
    $ErrorActionPreference = 'Continue'
    $out = & $Path --version 2>&1 | ForEach-Object { "$_" } | Out-String
    if ($out -match '(\d+\.\d+\.\d+)') { return [version]$Matches[1] }
    return $null
}

function Find-Ykman {
    # Every ykman.exe on the laptop, and the newest of them: one on PATH (pip, an old install) can be
    # older than the one the installer has just put in Program Files. A copy of a NEWER major than
    # $YkmanMajor (a ykman 6 beta someone installed) is ignored: this script is not tested against it.
    $paths = @()
    $c = Get-Command ykman.exe -ErrorAction SilentlyContinue
    if ($c) { $paths += $c.Source }
    foreach ($root in @("$env:ProgramFiles\Yubico", "${env:ProgramFiles(x86)}\Yubico")) {
        if ($root -and (Test-Path $root)) {
            $paths += @(Get-ChildItem -Path $root -Filter ykman.exe -Recurse -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
        }
    }
    $best = $null
    foreach ($p in ($paths | Select-Object -Unique)) {
        $v = Get-YkmanVersion $p
        if (-not $v) { continue }
        if ($v.Major -gt $YkmanMajor) {
            Write-Host "  Not using ykman $v at ${p}: this script is held to ykman $YkmanMajor.x until a newer major is tested here." -ForegroundColor Yellow
            continue
        }
        if (-not $best -or $v -gt $best.Version) { $best = @{ Path = $p; Version = $v } }
    }
    return $best
}

function Get-AuthenticatorVersion {
    # The installed Yubico Authenticator version. FIRST from its uninstall entry (DisplayVersion):
    # Yubico's own installer writes it, it is the version the release file is named by, and it is the
    # number Windows Installer itself compares when upgrading -- so it is what an upgrade changes, and
    # it is read without starting the app. The exe's own version stamp (ProductVersion, FileVersion)
    # comes from the app's build settings and is only the fallback. $null if neither can be read.
    param([string]$Path)
    $best = $null
    foreach ($k in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                     'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
                     'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*')) {
        $entries = @()
        try { $entries = @(Get-ItemProperty -Path $k -ErrorAction SilentlyContinue | Where-Object { "$($_.DisplayName)" -like 'Yubico Authenticator*' }) } catch { }
        foreach ($e in $entries) {
            if ("$($e.DisplayVersion)" -match '(\d+\.\d+\.\d+)') {
                $v = [version]$Matches[1]
                if (-not $best -or $v -gt $best) { $best = $v }
            }
        }
    }
    if ($best) { return $best }
    if ($Path) {
        $vi = $null
        try { $vi = (Get-Item -LiteralPath $Path -ErrorAction Stop).VersionInfo } catch { }
        if ($vi) {
            foreach ($s in @($vi.ProductVersion, $vi.FileVersion)) {
                if ("$s" -match '(\d+\.\d+\.\d+)') { return [version]$Matches[1] }
            }
        }
    }
    return $null
}

function Find-Authenticator {
    # @{ Path; Version } of the installed Yubico Authenticator ($null Version if it cannot be read),
    # or $null when it is not installed.
    foreach ($root in @("$env:ProgramFiles\Yubico", "${env:ProgramFiles(x86)}\Yubico")) {
        if ($root -and (Test-Path $root)) {
            $hit = Get-ChildItem -Path $root -Filter authenticator.exe -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($hit) { return @{ Path = $hit.FullName; Version = (Get-AuthenticatorVersion $hit.FullName) } }
        }
    }
    return $null
}

function Open-Authenticator {
    # The window that SHOWS the key. Opened, never waited on; if it is already open, Windows brings it up.
    if (-not $script:AuthenticatorPath) { return }
    if (Get-Process -Name authenticator -ErrorAction SilentlyContinue) {
        Write-Host '  Yubico Authenticator is already open.'
        return
    }
    try {
        Start-Process -FilePath $script:AuthenticatorPath | Out-Null
        Write-Host '  Opened Yubico Authenticator: it shows the key that is plugged in (model, serial, what is switched on).'
    } catch {
        Write-Host "  Could not open Yubico Authenticator: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# ------------------------------------------------------------------------------- ykman

function Invoke-Ykman {
    # Every call names the picked key (--device <serial>, in $script:DeviceArgs) unless -NoDevice:
    # only `ykman list`, which looks at ALL keys, is run without it.
    param([string[]]$YkArgs, [switch]$NoDevice)
    # Windows PowerShell 5.1: with ErrorActionPreference=Stop, a native command's stderr line
    # redirected by 2>&1 becomes a terminating error. ykman prints warnings there; read them instead.
    $ErrorActionPreference = 'Continue'
    $all = @($script:DeviceArgs) + $YkArgs
    if ($NoDevice) { $all = $YkArgs }
    $out = & $script:Ykman @all 2>&1 | ForEach-Object { "$_" } | Out-String
    return @{ Code = $LASTEXITCODE; Text = $out.Trim() }
}

function Invoke-YkmanChecked {
    # A write. A key that another program holds open (Yubico Authenticator mid-refresh) answers busy;
    # say so in plain words and let the technician retry instead of failing the key.
    param([string[]]$YkArgs, [string]$What)
    for ($i = 1; $i -le 3; $i++) {
        $r = Invoke-Ykman $YkArgs
        if ($r.Code -eq 0) { return $r }
        Write-Blob "ykman could not $What (exit $($r.Code))" $r.Text
        if ($r.Text -match '(?i)busy|in use|failed to open|access is denied|sharing violation') {
            Read-Host '  The key is busy. Close Yubico Authenticator (or wait 5 s), then press Enter to try again' | Out-Null
            continue
        }
        break
    }
    throw "ykman could not $What"
}

function Get-UsbYubiKeys {
    # What WINDOWS sees, whatever ykman can or cannot open: the USB parent device of each Yubico key
    # (vendor 1050). Works without administrator and without ykman. Asked of WMI with a filter first
    # (fast enough to poll once a second); Get-PnpDevice, which lists every device, if that fails.
    $devs = @()
    try {
        $devs = @(Get-CimInstance -ClassName Win32_PnPEntity -Filter "PNPDeviceID LIKE 'USB%VID_1050%'" -ErrorAction Stop |
            ForEach-Object { [pscustomobject]@{ InstanceId = "$($_.PNPDeviceID)"; FriendlyName = $_.Name; Status = $_.Status } })
    } catch {
        $devs = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue)
    }
    $devs = @($devs | Where-Object { $_.InstanceId -match '^USB\\VID_1050&PID_([0-9A-F]{4})\\' })
    $out = @()
    foreach ($d in $devs) {
        $null = $d.InstanceId -match 'PID_([0-9A-F]{4})'
        $pid4 = $Matches[1].ToUpper()
        $known = $YubicoPids[$pid4]
        $meaning = 'unknown Yubico product'
        if ($known) { $meaning = $known.Name }
        $out += [pscustomobject]@{
            Pid = $pid4; Meaning = $meaning; Name = $d.FriendlyName; Status = $d.Status; InstanceId = $d.InstanceId
            Otp = [bool]($known -and $known.Otp); Fido = [bool]($known -and $known.Fido)
        }
    }
    return ,$out
}

function Get-UsbSignature {
    # The SET of Yubico USB devices plugged in now, as one string: the picker redraws when it changes.
    $u = Get-UsbYubiKeys
    return (($u | ForEach-Object { $_.InstanceId } | Sort-Object) -join '|')
}

function Get-YkmanKeys {
    # What ykman can see: one entry per line of `ykman list` (a key ykman cannot open shows as e.g.
    # "YubiKey [FIDO] <access denied>", with no serial), plus any serial `ykman list --serials` adds.
    # The raw output is kept for the report.
    $keys = @()
    $list = Invoke-Ykman -NoDevice @('list')
    $script:LastYkmanList = $list.Text
    foreach ($l in ($list.Text -split "`r?`n")) {
        if ($l -notmatch '\S' -or $l -match '^\s*(WARNING|ERROR)') { continue }
        $name = $l.Trim(); $iface = ''; $ser = ''
        if ($l -match '^(.*?)\s*\[([A-Z+]+)\]') { $name = $Matches[1].Trim(); $iface = $Matches[2] }
        if ($l -match 'Serial:\s*(\d+)') { $ser = $Matches[1] }
        # ykman joins the interfaces as OTP+FIDO+CCID; put them in that order whatever it printed
        $parts = @($iface -split '\+' | Where-Object { $_ })
        $norm = (@('OTP', 'FIDO', 'CCID') | Where-Object { $parts -contains $_ }) -join '+'
        $cands = @(); if ($norm -and $IfacePids.ContainsKey($norm)) { $cands = $IfacePids[$norm] }
        $keys += [pscustomobject]@{ Name = $name; Serial = $ser; Pids = $cands }
    }
    $s = Invoke-Ykman -NoDevice @('list', '--serials')
    foreach ($x in @($s.Text -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d+$' })) {
        if (-not ($keys | Where-Object { $_.Serial -eq $x })) {
            $keys += [pscustomobject]@{ Name = 'YubiKey'; Serial = $x; Pids = @() }
        }
    }
    return ,$keys
}

function Get-KeyRows {
    # Every key plugged in, one row each, numbered: what Windows sees (USB product) joined to what
    # ykman sees (serial, model). A key ykman cannot open still gets a row, from Windows, with no serial.
    $usb = Get-UsbYubiKeys
    $yk  = Get-YkmanKeys
    $claimed = @{}
    $rows = New-Object System.Collections.ArrayList
    # keys with a serial first, so a key ykman cannot open never takes the USB device of one it can
    $ordered = @($yk | Where-Object { $_.Serial }) + @($yk | Where-Object { -not $_.Serial })
    foreach ($k in $ordered) {
        $u = $null
        foreach ($c in $usb) {
            if (-not $claimed[$c.InstanceId] -and $k.Pids -contains $c.Pid) { $u = $c; break }
        }
        if (-not $u -and -not $k.Serial) { continue }   # no serial and no USB match: the USB pass lists it
        if ($u) { $claimed[$u.InstanceId] = $true }
        [void]$rows.Add([pscustomobject]@{ Serial = $k.Serial; Model = $k.Name; Usb = $u })
    }
    # A key with a serial whose USB device could not be matched (a product number not in the table):
    # if exactly as many USB devices are left over, pair them in order rather than list a key twice.
    $loose = @($rows | Where-Object { -not $_.Usb })
    $left  = @($usb | Where-Object { -not $claimed[$_.InstanceId] })
    if ($loose.Count -and $loose.Count -eq $left.Count) {
        for ($i = 0; $i -lt $loose.Count; $i++) { $loose[$i].Usb = $left[$i]; $claimed[$left[$i].InstanceId] = $true }
    }
    foreach ($c in $usb) {
        if (-not $claimed[$c.InstanceId]) { [void]$rows.Add([pscustomobject]@{ Serial = ''; Model = ''; Usb = $c }) }
    }
    $out = @()
    $n = 0
    foreach ($r in $rows) {
        $n++
        $what = $r.Model
        $usbPid = ''
        if ($r.Usb) { $what = $r.Usb.Meaning; $usbPid = $r.Usb.Pid }
        if (-not $what) { $what = 'YubiKey' }
        $out += [pscustomobject]@{ Num = $n; Serial = $r.Serial; Model = $r.Model; What = $what; Pid = $usbPid; Usb = $r.Usb }
    }
    return ,$out
}

function Get-RowsSignature {
    param($Rows)
    return (($Rows | ForEach-Object { "$($_.Serial)/$($_.Pid)/$($_.Model)" }) -join '|')
}

function Show-KeyTable {
    # The numbered list of keys. Live mode clears the screen and redraws it whole; the keys done in
    # this run stay listed above it.
    param($Rows, [string]$Note, [switch]$Plain)
    if (-not $Plain) { Clear-Host }
    Write-Host ''
    $who = ''; if ($script:SignedInHow) { $who = " -- $($script:SignedInHow)" }
    Write-Host "  ETS bench YubiKey setup v$ScriptVersion$who" -ForegroundColor Cyan
    if ($script:Done -and $script:Done.Count) {
        Write-Host "  Done this run ($($script:Done.Count)):"
        $script:Done | ForEach-Object { Write-Host $_ }
    }
    Write-Host ''
    if ($Plain) { Write-Host '  YubiKeys plugged in now:' }
    else { Write-Host "  YubiKeys plugged in now (live: updated $(Get-Date -Format 'HH:mm:ss') as keys go in and out):" }
    if (-not $Rows -or $Rows.Count -eq 0) {
        Write-Host '  No YubiKey plugged in -- waiting...' -ForegroundColor Yellow
    } else {
        Write-Host ('  {0,-4} {1,-18} {2,-12} {3}' -f '#', 'Serial', 'USB product', 'What it is (from the USB product number)')
        foreach ($r in $Rows) {
            $ser = $r.Serial; if (-not $ser) { $ser = '(not readable)' }
            $up = $r.Pid; if (-not $up) { $up = '(not seen)' }
            Write-Host ('  {0,-4} {1,-18} {2,-12} {3}' -f $r.Num, $ser, $up, $r.What)
        }
    }
    if ($Note) { Write-Host ''; foreach ($l in ($Note -split "`n")) { Write-Host "  $l" -ForegroundColor Yellow } }
    Write-Host ''
    if (-not $Plain) {
        Write-Host '  Type the NUMBER of the key to work on, then Enter.  R + Enter = look again.  Q + Enter = finish.'
        Write-Host -NoNewline '  Key number: '
    }
}

function Resolve-KeyChoice {
    # The row the typed number names, or why it cannot be picked. Returns @{ Row; Note }.
    param($Rows, [string]$Text)
    $n = 0
    if (-not [int]::TryParse($Text, [ref]$n) -or $n -lt 1 -or $n -gt $Rows.Count) {
        return @{ Row = $null; Note = "There is no key #$Text in the list. Type a number from the # column." }
    }
    $r = $Rows[$n - 1]
    if (-not $r.Serial) {
        $blind = @($Rows | Where-Object { -not $_.Serial })
        if ($blind.Count -gt 1) {
            return @{ Row = $null; Note = ("Key #$n has no readable serial, and so do $($blind.Count - 1) other key(s): they cannot be told apart.`n" +
                "Unplug the others: Leave exactly one plugged in without a serial, then pick it.") }
        }
    }
    return @{ Row = $r; Note = '' }
}

function Clear-KeyBuffer {
    # Anything still waiting in the keyboard buffer (a key touched mid-list) must not reach the next
    # prompt -- or, after Q, the PowerShell prompt, where it would run as a command.
    try { while ([Console]::KeyAvailable) { $null = [Console]::ReadKey($true) } } catch { }
}

function Select-KeyPlain {
    # The picker for a host with no real console (PowerShell ISE, redirected input): the same list,
    # read with Read-Host, refreshed each time Enter is pressed. Returns the row, or $null to finish.
    $note = ''
    while ($true) {
        $rows = Get-KeyRows
        Show-KeyTable -Rows $rows -Note $note -Plain
        $a = (Read-Host '  Number of the key to work on, then Enter (Enter alone = look again, Q = finish)').Trim()
        $note = ''
        if ($a -match '^[qQ]$') { return $null }
        if ($a -eq '' -or $a -match '^[rR]$') { continue }
        if ($a -notmatch '^\d{1,3}$') { $note = 'That was not a number (if a key was touched, what it typed is not shown).'; continue }
        $c = Resolve-KeyChoice -Rows $rows -Text $a
        if ($c.Row) { return $c.Row }
        $note = $c.Note
    }
}

function Select-Key {
    # THE KEY PICKER. Lists every key plugged in, numbered, and keeps the list current: about once a
    # second it asks Windows which Yubico devices are present and redraws ONLY when that set changes
    # (and once more 2 s later, when a key just plugged in has settled and ykman can read it).
    # The technician types the number and Enter. Returns the row, or $null to finish.
    # A touched key types too, fast: 3+ characters closer than 40 ms apart are a key, not a person,
    # and are dropped unseen (a slot may hold a password). Only digits, R and Q are echoed, and with
    # [Console]::Write, which the transcript does not record.
    $live = $true
    try { $null = [Console]::KeyAvailable } catch { $live = $false }
    if (-not $live) { return Select-KeyPlain }

    $sig = $null; $rows = @(); $typed = ''; $note = ''; $settle = $null; $redraw = $false
    $burst = $false; $fast = 0; $last = [DateTime]::MinValue
    while ($true) {
        $now = Get-UsbSignature
        if ($null -eq $sig -or $now -ne $sig) {
            $sig = $now; $rows = Get-KeyRows; $settle = (Get-Date).AddSeconds(2); $redraw = $true
        } elseif ($settle -and (Get-Date) -ge $settle) {
            $settle = $null
            $again = Get-KeyRows
            if ((Get-RowsSignature $again) -ne (Get-RowsSignature $rows)) { $rows = $again; $redraw = $true }
        }
        if ($redraw) {
            Show-KeyTable -Rows $rows -Note $note
            if ($typed) { [Console]::Write($typed) }
            $redraw = $false
        }
        $until = (Get-Date).AddMilliseconds(1000)
        $enter = $false
        while (-not $enter -and (Get-Date) -lt $until) {
            if (-not [Console]::KeyAvailable) { Start-Sleep -Milliseconds 50; continue }
            $k = [Console]::ReadKey($true)
            $t = Get-Date
            if (($t - $last).TotalMilliseconds -lt 40) { $fast++ } else { $fast = 0 }
            $last = $t
            if ($fast -ge 2 -and -not $burst) {
                $burst = $true
                if ($typed) { [Console]::Write(("`b `b" * $typed.Length)) }
                $typed = ''
            }
            if ($k.Key -eq [ConsoleKey]::Enter) { $enter = $true; break }
            if ($burst) { continue }
            if ($k.Key -eq [ConsoleKey]::Backspace) {
                if ($typed) { $typed = $typed.Substring(0, $typed.Length - 1); [Console]::Write("`b `b") }
                continue
            }
            if ($k.Key -eq [ConsoleKey]::Escape) {
                if ($typed) { [Console]::Write(("`b `b" * $typed.Length)) }
                $typed = ''; continue
            }
            $ch = [string]$k.KeyChar
            if ($ch -match '^[0-9qQrR]$' -and $typed.Length -lt 3) { $typed += $ch; [Console]::Write($ch) }
        }
        if (-not $enter) { continue }
        $a = $typed; $typed = ''
        if ($burst) {
            $burst = $false; $fast = 0
            $note = 'A key was touched while the list was showing: what it typed was ignored (not shown).'
            $redraw = $true; continue
        }
        Write-Host ''
        $note = ''
        if ($a -match '^[qQ]$') { Clear-KeyBuffer; return $null }
        if ($a -eq '' -or $a -match '^[rR]$') { $sig = $null; continue }
        if ($a -notmatch '^\d+$') { $note = "Type the number of a key from the # column, then Enter."; $redraw = $true; continue }
        $c = Resolve-KeyChoice -Rows $rows -Text $a
        if ($c.Row) { Clear-KeyBuffer; return $c.Row }
        $note = $c.Note; $redraw = $true
    }
}

function Get-KeyFacts {
    # Everything the script knows about the PICKED key, and the full report of how it knows.
    # Returns a hashtable: Present, Usb (its USB device or $null), Others (how many other keys are
    # plugged in), Serial, DeviceType, Firmware, OtpState (Enabled | Disabled | Not available |
    # unknown | unknown (not administrator)), Slot1, Slot2 (programmed | empty | unknown).
    param($Pick)
    $f = @{ Present = $false; Usb = $null; Others = 0; Serial = $Pick.Serial; DeviceType = ''; Firmware = '';
            OtpState = 'unknown'; Slot1 = 'unknown'; Slot2 = 'unknown' }
    $rows = Get-KeyRows
    $me = $null
    if ($Pick.Serial) {
        $me = $rows | Where-Object { $_.Serial -eq $Pick.Serial } | Select-Object -First 1
    } else {
        $blind = @($rows | Where-Object { -not $_.Serial })
        if ($blind.Count -eq 1) { $me = $blind[0] }
    }
    $usbText = ($rows | ForEach-Object {
        $mark = '   '; if ($me -and $_.Num -eq $me.Num) { $mark = '>> ' }
        $ser = $_.Serial; if (-not $ser) { $ser = '(not readable)' }
        if ($_.Usb) { "$mark" + "serial $ser  USB product $($_.Usb.Pid) = $($_.Usb.Meaning)  [$($_.Usb.Name), $($_.Usb.Status)]  $($_.Usb.InstanceId)" }
        else { "$mark" + "serial $ser  $($_.Model)  (no USB device matched)" }
    }) -join "`n"
    Write-Blob 'What Windows sees (USB devices from Yubico, vendor 1050; >> = the key picked)' $usbText
    Write-Blob 'ykman list' $script:LastYkmanList
    if (-not $me) { return $f }
    $f.Present = $true
    $f.Usb = $me.Usb
    $f.Others = $rows.Count - 1

    $script:DeviceArgs = @()
    if ($f.Serial) { $script:DeviceArgs = @('--device', $f.Serial) }
    if (-not $f.Serial -and $f.Others -gt 0) {
        # No serial to name it by: a bare ykman call could answer about ANOTHER key plugged in.
        Write-Blob 'ykman info' 'not run: this key has no readable serial and other keys are plugged in, so ykman cannot be pointed at it'
    } else {
        $info = Invoke-Ykman @('info')
        Write-Blob 'ykman info' $info.Text
        if ($info.Text -match '(?m)^Device type:\s*(.+)$')      { $f.DeviceType = $Matches[1].Trim() }
        if ($info.Text -match '(?m)^Firmware version:\s*(.+)$') { $f.Firmware = $Matches[1].Trim() }
        if (-not $f.Serial -and $info.Text -match '(?m)^Serial number:\s*(\d+)') { $f.Serial = $Matches[1] }
        if ($info.Text -match '(?m)^\s*(?:Yubico )?OTP\s+(Enabled|Disabled|Not available)') {
            $f.OtpState = $Matches[1]
        } elseif ($info.Text -match '(?m)^Enabled USB interfaces:\s*(.+)$') {
            if ($Matches[1] -match 'OTP') { $f.OtpState = 'Enabled' } else { $f.OtpState = 'Disabled' }
        }
    }
    if ($f.OtpState -eq 'unknown' -and $f.Usb) {
        # ykman could not open it: go by the USB product number, and only as far as it can tell.
        if ($f.Usb.Pid -eq '0120') {
            $f.OtpState = 'Not available'      # Security Key by Yubico: has no OTP part at all
        } elseif ($f.Usb.Otp) {
            $f.OtpState = 'Enabled'
        } elseif ($OtpOffPids -contains $f.Usb.Pid -and -not (Test-Admin)) {
            # OTP switched off on a YubiKey 5 / NEO, or a Security Key with none: the same product number.
            $f.OtpState = 'unknown (not administrator)'
        }
    }

    if ($f.OtpState -eq 'Enabled' -and ($f.Serial -or $f.Others -eq 0)) {
        $oi = Invoke-Ykman @('otp', 'info')
        Write-Blob 'ykman otp info (what the two OTP slots hold; never their contents)' $oi.Text
        if ($oi.Text -match '(?m)^Slot 1:\s*(\w+)') { $f.Slot1 = $Matches[1].ToLower() }
        if ($oi.Text -match '(?m)^Slot 2:\s*(\w+)') { $f.Slot2 = $Matches[1].ToLower() }
    }
    return $f
}

function Write-AdminFix {
    # How to get an administrator window by hand.
    Write-Host '  To fix it: close this window. Click Start, type PowerShell, RIGHT-CLICK Windows PowerShell and choose' -ForegroundColor Yellow
    Write-Host '  "Run as administrator" (choose Yes, or type an administrator name and password), then type the line again:' -ForegroundColor Yellow
    Write-Host '      irm https://ets.azurewebsites.net/yk|iex' -ForegroundColor Yellow
}

# ------------------------------------------------------------------------------- presses

function Read-Press {
    # The key types like a keyboard and ends with Enter. MASKED, so neither the screen nor the log
    # ever holds what a slot typed: a one-time code is single-use, but a slot that is not ours may
    # hold somebody's static password. It is classified and then dropped, never kept or printed.
    # A slot that holds nothing types nothing: the technician presses Enter.
    param([string]$Prompt)
    $sec = Read-Host $Prompt -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try { $v = ([Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)).Trim() }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    if ($v -eq '')                    { return @{ Kind = 'empty';       Len = 0 } }
    if ($v -ceq $Command)             { return @{ Kind = 'command';     Len = $v.Length } }
    if ($v -ceq $OldCommand)          { return @{ Kind = 'old-command'; Len = $v.Length } }
    if ($v -cmatch $OtpPattern)       { return @{ Kind = 'otp'; Otp = $v; Len = $v.Length } }
    return @{ Kind = 'other'; Len = $v.Length }
}

function Format-Press {
    # How a press is shown: its kind and its length, never its text. For an OTP, the public id (the
    # first 12 letters, the key's name) is not secret and is what the operator's list shows.
    param($P)
    switch ($P.Kind) {
        'empty'       { 'nothing (slot empty)' }
        'command'     { 'the ETS start command' }
        'old-command' { 'the OLD ETS start command (p.exchangetech.ca)' }
        'otp'         { "a one-time code from key $($P.Otp.Substring(0, 12))" }
        default       { "something else, $($P.Len) characters (not shown: it may be a password)" }
    }
}

function Read-BothPresses {
    # $Target names the key to press ("key #2, serial 12345678"). A press types from whichever key is
    # touched, so with other keys plugged in ($Alone false) the technician is told not to touch them.
    param([string]$Target, [bool]$Alone = $true)
    Write-Host ''
    if ($Target) {
        Write-Host "  Press $Target -- that key only." -ForegroundColor Cyan
        if (-not $Alone) {
            Write-Host '  Other keys are plugged in: do NOT touch them. A press types from whichever key is touched.' -ForegroundColor Yellow
        }
    }
    Write-Host '  What you type is hidden (shown as *). That is on purpose.'
    $s = Read-Press '  SHORT press now (tap, under 1.5 s). If nothing appears in 3 s, press Enter'
    $l = Read-Press '  LONG press now (hold about 3 s).    If nothing appears in 5 s, press Enter'
    Write-Host "  Short press typed: $(Format-Press $s)"
    Write-Host "  Long press typed:  $(Format-Press $l)"
    return @{ Short = $s; Long = $l }
}

# ------------------------------------------------------------------------------- slot writes

function Set-Static {
    param([int]$Slot)
    Invoke-YkmanChecked -YkArgs @('otp', 'static', "$Slot", $Command, '--keyboard-layout', 'US', '--force') -What "write slot $Slot" | Out-Null
}

function Invoke-Swap {
    Invoke-YkmanChecked -YkArgs @('otp', 'swap', '--force') -What 'swap the slots' | Out-Null
}

function ConvertTo-Modhex {
    param([byte[]]$Bytes)
    $sb = New-Object System.Text.StringBuilder
    foreach ($b in $Bytes) { [void]$sb.Append($Modhex[$b -shr 4]); [void]$sb.Append($Modhex[$b -band 15]) }
    return $sb.ToString()
}

function New-RandomHex {
    param([int]$Bytes)
    $b = New-Object byte[] $Bytes
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($b) } finally { $rng.Dispose() }
    return (($b | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Reset-KeyForEts {
    # RESET: slot 1 (short press) gets the start command; slot 2 (long press) gets a NEW Yubico OTP
    # credential made here, which the provisioning service is told at enrolment and checks itself
    # (YubiCloud cannot: Yubico removed credential upload from ykman 5.6.1). Its public id is
    # "vv" + the serial, the way ykman's --serial-public-id builds it, so the operator's list names
    # the key by its serial. Returns the credential, which lives only in this window until enrolled.
    param([string]$Serial)
    $n = [uint32]$Serial
    $sb = [BitConverter]::GetBytes($n); [Array]::Reverse($sb)
    $publicId = ConvertTo-Modhex ([byte[]](@(0xff, 0x00) + $sb))
    $privateId = New-RandomHex 6
    $aesKey = New-RandomHex 16
    Invoke-YkmanChecked -YkArgs @('otp', 'yubiotp', '2', '--public-id', $publicId, '--private-id', $privateId, '--key', $aesKey, '--force') -What 'write the new ETS code into slot 2' | Out-Null
    Set-Static 1
    return @{ PublicId = $publicId; PrivateId = $privateId; AesKey = $aesKey }
}

function Get-Plan {
    # What to do, from what the two presses typed. Returns @{ Action; Why }.
    #   Action: done | swap | write2swap | write1 | reset
    param($S, $L)
    $sk = $S.Kind; $lk = $L.Kind
    if ($sk -eq 'command' -and $lk -eq 'otp')   { return @{ Action = 'done';       Why = 'already set up' } }
    if ($sk -eq 'otp'     -and $lk -eq 'command') { return @{ Action = 'swap';     Why = 'set up, but the two presses are the wrong way round' } }
    if ($sk -eq 'otp'     -and $lk -in @('empty', 'old-command')) { return @{ Action = 'write2swap'; Why = 'a new key (or one with the old start command)' } }
    if ($lk -eq 'otp'     -and $sk -in @('empty', 'old-command')) { return @{ Action = 'write1';     Why = 'the short press is empty or the old start command' } }
    if ($sk -eq 'otp'     -and $lk -eq 'other')   { return @{ Action = 'reset'; Why = 'the long press holds something that is not ours (perhaps a password someone uses)' } }
    if ($lk -eq 'otp'     -and $sk -eq 'other')   { return @{ Action = 'reset'; Why = 'the short press holds something that is not ours (perhaps a password someone uses)' } }
    if ($sk -eq 'otp'     -and $lk -eq 'otp')     { return @{ Action = 'reset'; Why = 'BOTH presses type a one-time code: a key leaves the factory with one, so the other was programmed later, and which one Yubico knows cannot be told from here' } }
    if ($sk -eq 'command' -and $lk -ne 'otp')     { return @{ Action = 'reset'; Why = 'the short press is set up but the long press types no one-time code' } }
    return @{ Action = 'reset'; Why = 'neither press types a one-time code: the factory code was erased or overwritten, so this key needs a new one' }
}

function Confirm-Reset {
    param([string]$Why)
    Write-Host ''
    Write-Host "  This key cannot be used as it is: $Why." -ForegroundColor Yellow
    Write-Host '  RESET makes it usable: the short press gets the bench start command and the long press a NEW ETS' -ForegroundColor Yellow
    Write-Host '  one-time code that the provisioning service checks itself.' -ForegroundColor Yellow
    Write-Host '  It ERASES whatever the two OTP slots hold today (a password or code someone may use elsewhere).' -ForegroundColor Yellow
    Write-Host '  Passkeys / FIDO2, smart card and Authenticator codes on the key are NOT touched.' -ForegroundColor Yellow
    if (-not $script:Enrol) {
        Write-Host '  You are NOT signed in, and a reset key must be enrolled at once (its new code is known only to' -ForegroundColor Red
        Write-Host '  this window). Run this again signed in, in the office, to reset this key. Nothing was changed.' -ForegroundColor Red
        return $false
    }
    $a = Read-Host '  Type RESET to reset this key, or press Enter to leave it unchanged'
    return ($a -ceq 'RESET')
}

# ------------------------------------------------------------------------------- the service

function Invoke-Service {
    # POST JSON to the provisioning service. Returns @{ Ok; Status; Body; Error }. Never throws: every
    # caller decides what a refusal means. The service answers errors as {"error": "..."}.
    param([string]$Path, [hashtable]$Body, [string]$Session)
    $headers = @{ 'Accept' = 'application/json' }
    if ($Session) { $headers['Authorization'] = "Bearer $Session" }
    try {
        $r = Invoke-RestMethod -Uri "$Service/api/$Path" -Method Post -Headers $headers -UseBasicParsing `
             -Body ($Body | ConvertTo-Json -Compress) -ContentType 'application/json' -TimeoutSec 30
        return @{ Ok = $true; Status = 200; Body = $r }
    } catch {
        $status = 0; $msg = $_.Exception.Message; $j = $null
        try { $status = [int]$_.Exception.Response.StatusCode } catch { }
        $text = "$($_.ErrorDetails.Message)"
        if (-not $text) {
            try { $text = (New-Object IO.StreamReader($_.Exception.Response.GetResponseStream())).ReadToEnd() } catch { }
        }
        try { $j = $text | ConvertFrom-Json; if ($j.error) { $msg = $j.error } } catch { }
        if ($status -eq 0) {
            $msg = 'could not reach the provisioning service. It answers only the office network.'
        } elseif ($status -eq 403 -and -not $j.error) {
            $msg = 'the provisioning service refused this network. It answers only the office network.'
        }
        return @{ Ok = $false; Status = $status; Error = $msg }
    }
}

function Read-Masked {
    # Masked, like the bench: a YubiKey code is single-use, but the pilot code typed into this same
    # box is not, and a plain Read-Host shows it to anyone behind the technician (and to the log).
    param([string]$Prompt)
    $sec = Read-Host $Prompt -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try { return ([Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)).Trim() }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Show-KeysNow {
    # Before the sign-in question: say which keys are plugged in RIGHT NOW, so nobody has to wonder
    # whether the script sees the key (v1.3.3: the sign-in question used to come first, and a
    # technician with a FIDO-only key plugged in read it as "my key was not found").
    $rows = @(Get-KeyRows)
    $lines = @()
    $cannotType = @()
    foreach ($r in $rows) {
        $ser = $r.Serial; if (-not $ser) { $ser = '(not readable)' }
        $up = $r.Pid; if (-not $up) { $up = '(not seen)' }
        $lines += "#$($r.Num)  serial $ser  USB product $up  $($r.What)"
        if ($r.Usb -and -not $r.Usb.Otp) { $cannotType += "#$($r.Num)" }
    }
    if (-not $lines.Count) { $lines = @('none yet. Plug keys in at any time: the list after the sign-in is live.') }
    Write-Blob "Keys plugged in now ($($rows.Count))" ($lines -join "`n")
    if ($cannotType.Count) {
        Write-Host "  Key $($cannotType -join ', ') is SEEN, but it cannot type a code (a FIDO-only key, or its OTP part is" -ForegroundColor Yellow
        Write-Host '  switched off), so it cannot answer the sign-in question below. Sign in with the pilot code or with a' -ForegroundColor Yellow
        Write-Host '  key that types a code; you pick this key from the list right after.' -ForegroundColor Yellow
    }
}

function Connect-Service {
    # One sign-in, the bench's own: it is what allows this session to enrol keys. Returns $true when
    # signed in. A session lasts 15 minutes; Assert-Session renews it between keys.
    Write-Host ''
    Write-Host '  SIGN IN first: it is what lets this script ENROL the keys you set up. One of:' -ForegroundColor Cyan
    Write-Host '    - HOLD (about 3 s) a key that is ALREADY enrolled to you, then unplug it;' -ForegroundColor Cyan
    Write-Host '    - or type the pilot code;' -ForegroundColor Cyan
    Write-Host '    - or press Enter alone to set keys up WITHOUT enrolling them.' -ForegroundColor Cyan
    Write-Host '  The key(s) to set up are picked from a numbered list right after this.' -ForegroundColor Cyan
    for ($try = 1; $try -le 3; $try++) {
        $code = Read-Masked '  Your key or the pilot code'
        if (-not $code) { return $false }
        $r = Invoke-Service -Path 'signin' -Body @{ otp = $code }
        if ($r.Ok -and $r.Body.session) {
            $script:Session = $r.Body.session
            $script:SessionUntil = (Get-Date).AddSeconds([int]$r.Body.expires_in)
            # The service names the shared pilot code "pilot (no YubiKey)": true, but on screen it read
            # as "no YubiKey was found". Say how the sign-in was done instead.
            if ("$($r.Body.name)" -like 'pilot*') {
                $script:SignedInAs = 'the pilot code'; $script:SignedInHow = 'signed in with the pilot code'
            } else {
                $script:SignedInAs = "$($r.Body.name)"; $script:SignedInHow = "signed in as $($r.Body.name)"
            }
            $how = $script:SignedInHow.Substring(0, 1).ToUpper() + $script:SignedInHow.Substring(1)
            Write-Host "  $how. Keys set up from now on are enrolled at once." -ForegroundColor Green
            return $true
        }
        Write-Host "  Not signed in: $($r.Error)" -ForegroundColor Red
        if ($r.Status -eq 0 -or $r.Status -eq 403) { break }
    }
    return $false
}

function Assert-Session {
    # Before the list is shown and again before work starts on the key picked: if the sign-in ends
    # within 3 minutes, renew it now, before a new key's code is read.
    if (-not $script:Enrol) { return }
    if ($script:Session -and (Get-Date).AddMinutes(3) -lt $script:SessionUntil) { return }
    Write-Host '  Your sign-in is about to end. Sign in again before the next key.' -ForegroundColor Yellow
    Write-Host '  Long-press YOUR OWN enrolled key, not a key you are setting up.' -ForegroundColor Yellow
    if (-not (Connect-Service)) {
        $script:Enrol = $false
        Write-Host '  Carrying on WITHOUT enrolling: keys are set up, and their long press signs in once enrolled.' -ForegroundColor Yellow
    }
}

function Register-Key {
    # Enrol the key whose LONG press typed $Otp, to $Holder. The code has not been used, so it proves
    # the key once, here: with YubiCloud for a factory code, or with $Cred for a code this script just
    # wrote (RESET). Returns @{ Ok; Message }.
    param([string]$Otp, [string]$Holder, [string]$Serial, $Cred)
    $body = @{ otp = $Otp; name = $Holder; serial = $Serial }
    if ($Cred) { $body['ets_credential'] = @{ private_id = $Cred.PrivateId; aes_key = $Cred.AesKey } }
    $r = Invoke-Service -Path 'technicians' -Body $body -Session $script:Session
    if (-not $r.Ok -and $r.Status -eq 401) {
        # Signed out mid-key (unlikely: Assert-Session renews first). The new key's code is still
        # unused, so sign in again and send the same one.
        Write-Host '  Your sign-in ended. Unplug THIS key for a moment and sign in again.' -ForegroundColor Yellow
        if (Connect-Service) {
            Read-Host '  Plug THIS key back in, then press Enter' | Out-Null
            $r = Invoke-Service -Path 'technicians' -Body $body -Session $script:Session
        }
    }
    $body = $null
    if ($r.Ok -and $r.Body.already) { return @{ Ok = $true; Message = "already enrolled to $($r.Body.name)" } }
    if ($r.Ok -and $r.Body.enrolled) { return @{ Ok = $true; Message = "enrolled to $($r.Body.name)" } }
    return @{ Ok = $false; Message = $r.Error }
}

# ------------------------------------------------------------------------------- one key

function Invoke-OneKey {
    # Everything for the key PICKED from the list. Returns the line for the end-of-run summary.
    param($Pick)
    $sl = $Pick.Serial; if (-not $sl) { $sl = '(no serial readable)' }
    $target = "key #$($Pick.Num), serial $sl"
    if (-not $Pick.Serial) { $target = "key #$($Pick.Num) (its serial cannot be read)" }
    Write-Host ''
    Write-Host "  Working on $target ($($Pick.What))." -ForegroundColor Cyan
    $f = Get-KeyFacts -Pick $Pick
    if (-not $f.Present) {
        Write-Host "  $target is no longer plugged in (or ykman cannot see it any more). Plug it back in and pick it again." -ForegroundColor Red
        if (-not $Pick.Serial) { Write-Host '  It has no readable serial: Leave exactly one plugged in without a serial.' -ForegroundColor Red }
        return $null
    }
    $label = $f.DeviceType
    if (-not $label -and $f.Usb) { $label = $f.Usb.Meaning }
    if (-not $label) { $label = $Pick.What }
    $serial = $f.Serial
    $sl = $serial; if (-not $sl) { $sl = '(no serial readable)' }
    $target = "key #$($Pick.Num), serial $sl"
    if (-not $serial) { $target = "key #$($Pick.Num) (its serial cannot be read)" }
    $alone = ($f.Others -eq 0)
    $up = '(not seen)'; if ($f.Usb) { $up = $f.Usb.Pid }
    Write-Host ''
    Write-Host "  KEY #$($Pick.Num): $label, serial $sl, USB product $up, firmware $($f.Firmware). OTP part: $($f.OtpState). Slot 1: $($f.Slot1). Slot 2: $($f.Slot2)." -ForegroundColor Cyan

    if ($f.OtpState -eq 'unknown (not administrator)') {
        # USB product 0402/0406/0113/0115: OTP off. A YubiKey 5 with OTP switched off and a Security Key
        # (which has none) look the same from here; only an administrator window can open the key to tell.
        Write-Host "  OTP is switched off or absent on this key (USB product $up); which one cannot be told without administrator." -ForegroundColor Yellow
        Write-Host '  ykman could not open it: Windows lets only an administrator talk to the FIDO part of a key, and this' -ForegroundColor Yellow
        Write-Host '  window is not administrator. If OTP is switched off, an administrator window offers to switch it on;' -ForegroundColor Yellow
        Write-Host '  if the key has no OTP part (a Security Key), it is set aside for FIDO2 sign-in. Nothing was changed.' -ForegroundColor Yellow
        Write-AdminFix
        return "  serial $sl  OTP switched off or absent (USB $up), NOT READ (not administrator)"
    }
    if ($f.OtpState -eq 'unknown' -and -not (Test-Admin)) {
        Write-Host '  ykman could not open this key, and this window is not administrator. Windows lets only an' -ForegroundColor Red
        Write-Host '  administrator read the FIDO part of a key. Nothing was changed.' -ForegroundColor Red
        Write-AdminFix
        return "  serial $sl  NOT READ (not administrator)"
    }
    if ($f.OtpState -eq 'Not available') {
        # Only when ykman info itself says the OTP application is "Not available", or USB product 0120.
        Write-Host '  FIDO-ONLY KEY: this model has NO one-time-code (OTP) part at all. It cannot type the start command' -ForegroundColor Yellow
        Write-Host '  or a one-time code, so the short/long press set-up does not apply to it. It is a Yubico' -ForegroundColor Yellow
        Write-Host '  "Security Key" (FIDO2 / passkey only). The bench cannot sign in with it YET: sign-in by touch' -ForegroundColor Yellow
        Write-Host '  (FIDO2) is being built. Until then use a key that types a code. Nothing was changed.' -ForegroundColor Yellow
        return "  serial $sl  FIDO-ONLY ($label): no OTP part; FIDO2 sign-in only"
    }
    if (-not $serial -and -not $alone) {
        # Every change below would be a bare ykman call, which could reach ANOTHER key plugged in.
        Write-Host '  This key has no readable serial, so ykman cannot be pointed at it while other keys are plugged in.' -ForegroundColor Yellow
        Write-Host '  Unplug the other keys: Leave exactly one plugged in, then pick it again. Nothing was changed.' -ForegroundColor Yellow
        return $null
    }
    if ($f.OtpState -eq 'unknown') {
        Write-Host '  ykman could not open this key even as administrator, so what it holds cannot be read. Unplug it, plug it' -ForegroundColor Red
        Write-Host '  back in, wait 5 s and pick it again; close Yubico Authenticator if it is open. Nothing was changed.' -ForegroundColor Red
        return "  serial $sl  NOT READ (ykman could not open it)"
    }
    if ($f.OtpState -eq 'Disabled') {
        Write-Host '  The OTP part of this key is SWITCHED OFF (someone turned it off; the key has one). Without it the key' -ForegroundColor Yellow
        Write-Host '  cannot type the start command or a one-time code. Switching it on changes nothing else on the key.' -ForegroundColor Yellow
        $a = Read-Host '  Type ON to switch the OTP part on, or press Enter to leave the key unchanged'
        if ($a -cne 'ON') { return "  serial $sl  OTP switched off, left unchanged" }
        Invoke-YkmanChecked -YkArgs @('config', 'usb', '--enable', 'OTP', '--force') -What 'switch the OTP part on' | Out-Null
        Write-Host '  Switched on. The key restarts itself; waiting 4 s ...'
        Start-Sleep -Seconds 4
        $f = Get-KeyFacts -Pick $Pick
        if ($f.OtpState -ne 'Enabled') {
            Write-Host "  The OTP part still reads $($f.OtpState). Unplug the key, plug it back in, and pick it again." -ForegroundColor Red
            return "  serial $sl  OTP switch-on did not take"
        }
        $alone = ($f.Others -eq 0)
    }

    $cred = $null
    $p = Read-BothPresses -Target $target -Alone $alone
    $plan = Get-Plan $p.Short $p.Long
    Write-Host "  -> $($plan.Why)."
    switch ($plan.Action) {
        'done'       { }
        'swap'       { Invoke-Swap }
        'write2swap' { Set-Static 2; Invoke-Swap }
        'write1'     { Set-Static 1 }
        'reset'      {
            if (-not $serial) {
                Write-Host '  This key reports no serial, so a new ETS code cannot be named after it. Nothing was changed.' -ForegroundColor Red
                return "  serial $sl  needs RESET but has no serial"
            }
            if (-not (Confirm-Reset $plan.Why)) {
                Write-Host '  Nothing was changed on this key.' -ForegroundColor Yellow
                return "  serial $sl  left unchanged ($($plan.Why))"
            }
            $cred = Reset-KeyForEts -Serial $serial
            Write-Host "  RESET done: short press = start command, long press = new ETS code (key $($cred.PublicId))."
        }
    }

    # Prove it the way the bench will use it.
    Write-Host '  Checking both presses again...'
    $v = Read-BothPresses -Target $target -Alone $alone
    if ($v.Short.Kind -ne 'command' -or $v.Long.Kind -ne 'otp') {
        Write-Host "  CHECK FAILED: short press = $(Format-Press $v.Short), long press = $(Format-Press $v.Long). Run this key again; if it fails twice, call the operator with the log." -ForegroundColor Red
        return "  serial $sl  CHECK FAILED"
    }
    $publicId = $v.Long.Otp.Substring(0, 12)
    if ($cred -and $publicId -ne $cred.PublicId) {
        Write-Host '  CHECK FAILED: the long press is not the code just written. Run this key again.' -ForegroundColor Red
        return "  serial $sl  CHECK FAILED (wrong long press after reset)"
    }
    $holder = ''
    for ($t = 0; $t -lt 2; $t++) {
        $holder = (Read-Host '  Who will carry this key? Full name (blank = a spare, not enrolled yet)').Trim()
        if ($holder -or -not $cred) { break }
        Write-Host '  A reset key must be enrolled now: its new code is known only to this window. Type a name' -ForegroundColor Yellow
        Write-Host '  (a spare can be enrolled as "Spare <serial>" and renamed by the operator later).' -ForegroundColor Yellow
    }
    if (-not $holder) {
        if ($cred) {
            Write-Host '  NOT ENROLLED. This reset key cannot sign in; run it again and RESET it, signed in.' -ForegroundColor Red
            return "  serial $serial  $publicId  reset but NOT ENROLLED (no name)"
        }
        Write-Host "  READY as a SPARE: serial $sl, key $publicId. Not enrolled: when it is handed to someone," -ForegroundColor Green
        Write-Host '  run this again with the key and type their name.' -ForegroundColor Green
        return "  serial $sl  $publicId  spare, not enrolled"
    }
    if (-not $script:Enrol) {
        Write-Host "  READY but NOT ENROLLED: serial $sl, key $publicId, for $holder (not signed in)." -ForegroundColor Yellow
        return "  serial $sl  $publicId  $holder  NOT ENROLLED (not signed in)"
    }
    # The long press just read is unused; the service spends it to prove the key.
    $e = Register-Key -Otp $v.Long.Otp -Holder $holder -Serial $serial -Cred $cred
    if (-not $e.Ok -and -not $cred -and $serial -and $e.Message -match 'YubiCloud') {
        # The key LOOKS set up, but Yubico does not know its code: the factory code was replaced at some
        # point. Running it again would read "already set up" forever, so offer the reset here.
        Write-Host "  Yubico refused this key's one-time code: $($e.Message)" -ForegroundColor Yellow
        if (Confirm-Reset 'Yubico does not recognise its one-time code (the factory code was replaced at some point)') {
            $cred = Reset-KeyForEts -Serial $serial
            Write-Host "  RESET done (key $($cred.PublicId)). Checking both presses again..."
            $v = Read-BothPresses -Target $target -Alone $alone
            if ($v.Short.Kind -ne 'command' -or $v.Long.Kind -ne 'otp' -or $v.Long.Otp.Substring(0, 12) -ne $cred.PublicId) {
                Write-Host '  CHECK FAILED after the reset. Run this key again (it will offer RESET again).' -ForegroundColor Red
                return "  serial $sl  reset, CHECK FAILED, NOT ENROLLED"
            }
            $publicId = $cred.PublicId
            $e = Register-Key -Otp $v.Long.Otp -Holder $holder -Serial $serial -Cred $cred
        }
    }
    $cred = $null
    if ($e.Ok) {
        Write-Host "  ENROLLED: serial $sl, key $publicId, $($e.Message). Its long press signs in at the bench now." -ForegroundColor Green
        Write-Host '  Label the key with that name and serial.'
        return "  serial $sl  $publicId  $holder  ENROLLED"
    }
    Write-Host "  SET UP but NOT ENROLLED: $($e.Message)" -ForegroundColor Red
    Write-Host '  Run this key again to retry; send the operator the log if it fails twice.'
    return "  serial $sl  $publicId  $holder  NOT ENROLLED: $($e.Message)"
}

# ------------------------------------------------------------------------------------------- main
Write-Host ''
Write-Host "  ETS bench YubiKey setup v$ScriptVersion" -ForegroundColor Cyan

if (-not (Test-Admin) -and -not $NoElevate) {
    # Windows lets only an administrator open the FIDO part of a key; a FIDO-only key reads as
    # "no key" otherwise -- the 2026-11-19 demo. Reopen this same version as administrator.
    Write-Host '  Reopening as administrator (Windows lets only an administrator read the FIDO part of a key).'
    Write-Host '  Choose Yes when Windows asks. Carry on in the NEW window.'
    if ($PSCommandPath) { $argLine = "-NoProfile -ExecutionPolicy Bypass -NoExit -File `"$PSCommandPath`"" }
    else { $argLine = "-NoProfile -ExecutionPolicy Bypass -NoExit -Command `"irm $SelfUrl | iex`"" }
    if ($Service -ne 'https://func-ets-provision-cc.azurewebsites.net' -and $PSCommandPath) { $argLine += " -Service `"$Service`"" }
    # Up to 3 asks: the first failure on a real laptop was a MISTYPED administrator password at the
    # Windows prompt (2026-11-19), and the script used to give up at once without saying why.
    $reopened = $false
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            Start-Process -FilePath powershell.exe -Verb RunAs -ArgumentList $argLine | Out-Null
            $reopened = $true
            break
        } catch {
            Write-Host "  Windows did not open the administrator window (try $attempt of 3): $($_.Exception.Message)" -ForegroundColor Yellow
            Write-Host '  Usually one of these: the Yes/No question was answered No, closed, or timed out; or this account is' -ForegroundColor Yellow
            Write-Host '  not an administrator, and the administrator name and password Windows asked for were mistyped or cancelled.' -ForegroundColor Yellow
            if ($attempt -lt 3) {
                $again = Read-Host '  Press Enter to ask Windows again (you may have mistyped the password), or type N to carry on without administrator'
                if ($again -match '^\s*[nN]') { break }
            }
        }
    }
    # return, not exit: run as `irm ... | iex`, exit would close the technician's window.
    if ($reopened) { return }
    Write-Host '  Carrying on WITHOUT administrator. What will NOT work in this window: a key whose OTP part is switched' -ForegroundColor Yellow
    Write-Host '  off or absent (USB product 0402, 0406, 0113, 0115) cannot be read, so it can be neither switched on nor' -ForegroundColor Yellow
    Write-Host '  told apart from a FIDO-only key. Keys that can type a code (e.g. USB product 0407) work as usual.' -ForegroundColor Yellow
    Write-AdminFix
}

$logDir = Join-Path $env:LOCALAPPDATA 'ETS\YubiKeySetup'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$logPath = Join-Path $logDir ('setup-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
# The log holds what the screen shows. Every press and the sign-in are read MASKED, so it never holds
# a one-time code, a pilot code or what a foreign slot typed; send it to the operator when a key fails.
try { Start-Transcript -Path $logPath | Out-Null; $transcribing = $true } catch { $transcribing = $false }
try {
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    Write-Blob 'This laptop' (@(
        # WindowsIdentity, not $env:USERNAME: an elevated window opened with another account's password
        # can inherit USERNAME=SYSTEM in its environment (seen 2026-11-19) while running as that account.
        "computer:   $env:COMPUTERNAME   user: $([Security.Principal.WindowsIdentity]::GetCurrent().Name)   administrator: $(Test-Admin)",
        "windows:    $($os.Caption) build $($os.BuildNumber)",
        "powershell: $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))",
        "service:    $Service",
        "log file:   $logPath"
    ) -join "`n")

    # What Yubico publishes today: each release page is read once, here, and reused below.
    $ykNewest   = Get-NewestYubicoRelease -Releases $YkmanReleases -Prefix 'yubikey-manager' -Major $YkmanMajor
    $authNewest = Get-NewestYubicoRelease -Releases $AuthenticatorReleases -Prefix 'yubico-authenticator'

    # ykman. Missing (or older than $YkmanFloor): install the newest 5.x, and STOP if that fails --
    # no key is touched without a working ykman. Older than the newest 5.x: upgrade, and if the
    # upgrade fails, say why and carry on with the one already here (it works).
    $yk = Find-Ykman
    $ykWas = '(none)'; if ($yk) { $ykWas = "$($yk.Version)" }
    $ykAction = 'kept: the newest published could not be read'
    if (-not $yk -or $yk.Version -lt $YkmanFloor) {
        if ($yk) { Write-Host "  ykman $($yk.Version) is older than $YkmanFloor; installing the newest $YkmanMajor.x from Yubico." }
        else     { Write-Host '  The YubiKey Manager command line (ykman) is not on this laptop yet; installing it from Yubico (once per laptop).' }
        $installed = $false
        try { $installed = Install-Ykman -Version $ykNewest }
        catch { Write-Host "  Could not install ykman: $($_.Exception.Message)" -ForegroundColor Red }
        if ($installed) { $yk = Find-Ykman }
        if (-not $yk -or $yk.Version -lt $YkmanFloor) {
            Write-Host '  ykman is not ready, so no key was touched. Run the line again; if it fails twice, call the operator.' -ForegroundColor Red
            return
        }
        $ykAction = 'installed this run'
    } elseif ($ykNewest -and $yk.Version -lt $ykNewest) {
        Write-Host "  ykman $($yk.Version) is on this laptop; Yubico publishes $ykNewest. Upgrading."
        $upgraded = $false
        try { $upgraded = Install-Ykman -Version $ykNewest }
        catch { Write-Host "  Could not upgrade ykman: $($_.Exception.Message)" -ForegroundColor Yellow }
        $after = $null
        if ($upgraded) { $after = Find-Ykman }
        if ($after -and $after.Version -ge $ykNewest) {
            $yk = $after
            $ykAction = 'UPGRADED this run'
        } else {
            # A failed upgrade does not stop the run: the ykman already here is a usable 5.x.
            if ($after) { $yk = $after }
            Write-Host "  The upgrade to ykman $ykNewest did not take (see above). Carrying on with ykman $($yk.Version), which works." -ForegroundColor Yellow
            $ykAction = "upgrade to $ykNewest FAILED: carried on with the one installed"
        }
    } elseif ($ykNewest) {
        $ykAction = 'up to date'
    }
    $script:Ykman = $yk.Path
    $script:DeviceArgs = @()

    # Yubico Authenticator: a help to SEE the key, never needed to set it up, so nothing about it
    # stops the run. Missing: install the newest. Older than the newest: upgrade -- but not while it is
    # open (Windows would hold its files), and a failed upgrade carries on with the one installed.
    $auth = Find-Authenticator
    $authWas = '(none)'
    if ($auth) { $authWas = "$($auth.Version)"; if (-not $auth.Version) { $authWas = '(version not readable)' } }
    $authAction = 'kept: the newest published could not be read'
    if (-not $auth) {
        Write-Host '  Yubico Authenticator (the window that shows the key) is not on this laptop yet; installing it from Yubico.'
        $ok = $false
        try { $ok = Install-Authenticator -Version $authNewest } catch { Write-Host "  Could not install Yubico Authenticator: $($_.Exception.Message)" -ForegroundColor Yellow }
        if ($ok) { $auth = Find-Authenticator }
        if ($auth) {
            $authAction = 'installed this run'
        } else {
            Write-Host '  Carrying on without it: the window is a help to see the key, not needed to set it up.' -ForegroundColor Yellow
            $authAction = 'NOT installed: carried on without it'
        }
    } elseif (-not $auth.Version) {
        $authAction = 'kept: its installed version could not be read, so it was not upgraded'
    } elseif ($authNewest -and $auth.Version -lt $authNewest) {
        if (Get-Process -Name authenticator -ErrorAction SilentlyContinue) {
            Write-Host "  Yubico Authenticator $($auth.Version) is open, so it is not upgraded to $authNewest now. Close it and run the line again to upgrade; carrying on with $($auth.Version)." -ForegroundColor Yellow
            $authAction = "upgrade to $authNewest SKIPPED (it was open): carried on with the one installed"
        } else {
            Write-Host "  Yubico Authenticator $($auth.Version) is on this laptop; Yubico publishes $authNewest. Upgrading."
            $upgraded = $false
            try { $upgraded = Install-Authenticator -Version $authNewest }
            catch { Write-Host "  Could not upgrade Yubico Authenticator: $($_.Exception.Message)" -ForegroundColor Yellow }
            $after = $null
            if ($upgraded) { $after = Find-Authenticator }
            if ($after -and $after.Version -and $after.Version -ge $authNewest) {
                $auth = $after
                $authAction = 'UPGRADED this run'
            } else {
                if ($after) { $auth = $after }
                Write-Host "  The upgrade to Yubico Authenticator $authNewest did not take (see above). Carrying on with the one installed." -ForegroundColor Yellow
                $authAction = "upgrade to $authNewest FAILED: carried on with the one installed"
            }
        }
    } elseif ($authNewest) {
        $authAction = 'up to date'
    }
    $script:AuthenticatorPath = $null
    if ($auth) { $script:AuthenticatorPath = $auth.Path }

    $lang = (Get-WinUserLanguageList)[0]
    $ykNewText = "$ykNewest"; if (-not $ykNewest) { $ykNewText = '(release page not read)' }
    $authNewText = "$authNewest"; if (-not $authNewest) { $authNewText = '(release page not read)' }
    $authText = '(not installed)'
    if ($auth) {
        $authVer = "$($auth.Version)"; if (-not $auth.Version) { $authVer = '(version not readable)' }
        $authText = "$authVer at $($auth.Path)"
    }
    Write-Blob 'Tools' (@(
        "ykman:         $($yk.Version) at $script:Ykman",
        "               newest $YkmanMajor.x published: $ykNewText (held to $YkmanMajor.x); before this run: $ykWas; $ykAction",
        "Authenticator: $authText",
        "               newest published: $authNewText; before this run: $authWas; $authAction",
        "keyboard:      $($lang.LanguageTag) $($lang.InputMethodTips -join ',')",
        "start command a short press will type: $Command"
    ) -join "`n")
    # 00000409 is the US layout, whatever the language (en-US 0409:00000409, en-CA 1009:00000409).
    if (-not ($lang.InputMethodTips | Where-Object { $_ -like '*:00000409' })) {
        Write-Host "  WARNING: the keyboard layout is not English (US) ($($lang.LanguageTag)). Switch to it (Win+Space) before starting." -ForegroundColor Yellow
    }
    Open-Authenticator

    $script:Session = $null; $script:SessionUntil = Get-Date; $script:SignedInAs = $null; $script:SignedInHow = $null
    Show-KeysNow
    $script:Enrol = Connect-Service
    if (-not $script:Enrol) {
        Write-Host '  NOT signed in: keys will be set up but NOT enrolled, and a key that needs a RESET is left alone.' -ForegroundColor Yellow
        Write-Host '  Run this again, signed in, in the office, to enrol them.' -ForegroundColor Yellow
    }

    $script:Done = New-Object System.Collections.ArrayList
    $done = $script:Done
    while ($true) {
        Write-Host ''
        Write-Host '--------------------------------------------------------------------------------'
        Assert-Session
        # The live, numbered list of every key plugged in; the technician types the number of one.
        $pick = Select-Key
        if (-not $pick) { break }
        # The list may have been showing for a while: renew the sign-in before this key's code is read.
        Assert-Session
        try {
            $line = Invoke-OneKey -Pick $pick
            if ($line) { [void]$done.Add($line) }
        } catch {
            Write-Host "  ERROR: $($_.Exception.Message)" -ForegroundColor Red
            Write-Host '  Nothing more was done to this key. Fix the cause and pick it again; the log has the detail.'
            [void]$done.Add("  ERROR: $($_.Exception.Message)")
        }
        $script:DeviceArgs = @()
        # Masked: a key touched here types into this box, and the log must never hold what it typed.
        Read-Masked '  Press Enter to go back to the list of keys' | Out-Null
    }

    Write-Host ''
    Write-Host "  This run ($($done.Count) key(s)):" -ForegroundColor Cyan
    if ($done.Count) { $done | ForEach-Object { Write-Host $_ } } else { Write-Host '  (none)' }
    if ($script:SignedInAs) { Write-Host "  Enrolments are recorded against $($script:SignedInAs)." }
} finally {
    Write-Host "  Log of this run: $logPath"
    if ($transcribing) { try { Stop-Transcript | Out-Null } catch { } }
}
