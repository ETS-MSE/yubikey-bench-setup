<#
.SYNOPSIS
    Set up ETS bench YubiKeys, one after another, on the dedicated Windows 11 provisioning laptop.

.DESCRIPTION
    For each key it:
      1. REPORTS what it sees, in full: the USB device Windows sees (Yubico, vendor 1050, and what its
         product number means), what ykman says about the key (model, serial, firmware, which
         applications are on and off), and what each of the two OTP slots holds (programmed / empty).
         The same report goes into a log file whose path is printed at the start and the end;
      2. tells a key that can never type a code (a FIDO-only key: the "Security Key" series, or a
         YubiKey 5 whose OTP part is switched off) from one that can, and says which in plain words.
         A YubiKey 5 with OTP switched off is offered a one-step switch-on;
      3. reads what the key types today: a SHORT press (slot 1) and a LONG press (slot 2, ~3 s),
         masked, never echoed and never written to the log;
      4. decides from that what to do -- a new key, a key already set up, or a key that holds
         something else. For anything it cannot use as it is, it OFFERS A RESET (type RESET): the
         short press gets the bench start command and the long press a NEW ETS one-time code that
         the provisioning service checks itself. Nothing is changed without that typed word;
      5. checks both presses again, and ENROLS the key to the person who will carry it, there and
         then: from that moment its long press signs in at the bench.

    It installs what it needs itself, the first time, from Yubico and only if Windows confirms the
    installer is signed by Yubico AB: the YubiKey Manager command line (ykman), and the Yubico
    Authenticator app (the window that SHOWS the key; Yubico retired the old "YubiKey Manager" window
    on 2026-02-19 and points to Authenticator instead). It opens Authenticator so the technician can
    see the key it is working on.

    It runs as administrator and reopens itself as administrator if it is not: Windows lets only an
    administrator talk to the FIDO part of a key, and some keys have nothing else.

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

$ScriptVersion = '1.3.0'
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
# Yubico's own release folders; the signed Windows installers are published there.
$YkmanReleases = 'https://developers.yubico.com/yubikey-manager/Releases/'
$AuthenticatorReleases = 'https://developers.yubico.com/yubioath-flutter/Releases/'

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
    '0402' = @{ Name = 'YubiKey 4/5 or Security Key: FIDO only (OTP switched off, or not on this model)'; Otp = $false; Fido = $true }
    '0403' = @{ Name = 'YubiKey 4/5: OTP + FIDO';              Otp = $true;  Fido = $true }
    '0404' = @{ Name = 'YubiKey 4/5: smart card only';         Otp = $false; Fido = $false }
    '0405' = @{ Name = 'YubiKey 4/5: OTP + smart card';        Otp = $true;  Fido = $false }
    '0406' = @{ Name = 'YubiKey 4/5: FIDO + smart card (OTP switched off)'; Otp = $false; Fido = $true }
    '0407' = @{ Name = 'YubiKey 4/5: OTP + FIDO + smart card'; Otp = $true;  Fido = $true }
    '0410' = @{ Name = 'YubiKey Plus';                         Otp = $true;  Fido = $true }
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

function Install-YubicoMsi {
    # The newest x64 installer Yubico publishes in $Releases matching "$Prefix-<version>-win64.msi",
    # from Yubico itself; run only if Windows says it is signed by Yubico AB. $true on success.
    param([string]$Releases, [string]$Prefix, [string]$What)
    $ProgressPreference = 'SilentlyContinue'   # Windows PowerShell 5.1 downloads ~10x slower with the bar
    $page = Invoke-WebRequest -Uri $Releases -UseBasicParsing
    $newest = [regex]::Matches($page.Content, [regex]::Escape($Prefix) + '-(\d+\.\d+\.\d+)-win64\.msi(?!\.sig)') |
        ForEach-Object { [version]$_.Groups[1].Value } | Sort-Object -Descending | Select-Object -First 1
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
                Write-Host "  The install was not allowed, so $What is still missing. Run the line again and choose Yes." -ForegroundColor Red
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
    Install-YubicoMsi -Releases $YkmanReleases -Prefix 'yubikey-manager' -What 'ykman (YubiKey Manager command line)'
}

function Install-Authenticator {
    Install-YubicoMsi -Releases $AuthenticatorReleases -Prefix 'yubico-authenticator' -What 'Yubico Authenticator'
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
    # older than the one the installer has just put in Program Files.
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
        if ($v -and (-not $best -or $v -gt $best.Version)) { $best = @{ Path = $p; Version = $v } }
    }
    return $best
}

function Find-Authenticator {
    foreach ($root in @("$env:ProgramFiles\Yubico", "${env:ProgramFiles(x86)}\Yubico")) {
        if ($root -and (Test-Path $root)) {
            $hit = Get-ChildItem -Path $root -Filter authenticator.exe -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($hit) { return $hit.FullName }
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
    param([string[]]$YkArgs)
    # Windows PowerShell 5.1: with ErrorActionPreference=Stop, a native command's stderr line
    # redirected by 2>&1 becomes a terminating error. ykman prints warnings there; read them instead.
    $ErrorActionPreference = 'Continue'
    $all = @($script:DeviceArgs) + $YkArgs
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
    # (vendor 1050). Works without administrator and without ykman.
    $devs = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
        Where-Object { $_.InstanceId -match '^USB\\VID_1050&PID_([0-9A-F]{4})\\' })
    $out = @()
    foreach ($d in $devs) {
        $null = $d.InstanceId -match 'PID_([0-9A-F]{4})'
        $pid4 = $Matches[1].ToUpper()
        $known = $YubicoPids[$pid4]
        $meaning = 'unknown Yubico product'
        if ($known) { $meaning = $known.Name }
        $out += [pscustomobject]@{
            Pid = $pid4; Meaning = $meaning; Name = $d.FriendlyName; Status = $d.Status; InstanceId = $d.InstanceId
            Otp = ($known -and $known.Otp); Fido = ($known -and $known.Fido)
        }
    }
    return ,$out
}

function Get-KeyFacts {
    # Everything the script knows about the ONE key plugged in, and the full report of how it knows.
    # Returns a hashtable: Usb, Serial, DeviceType, Firmware, OtpState (Enabled|Disabled|Not available|
    # unknown), Slot1, Slot2 (programmed|empty|unknown), Count, Report.
    $f = @{ Usb = @(); Serial = ''; DeviceType = ''; Firmware = ''; OtpState = 'unknown';
            Slot1 = 'unknown'; Slot2 = 'unknown'; Count = 0 }
    $f.Usb = Get-UsbYubiKeys
    $f.Count = $f.Usb.Count
    $usbText = ($f.Usb | ForEach-Object { "USB product $($_.Pid) = $($_.Meaning)  [$($_.Name), $($_.Status)]  $($_.InstanceId)" }) -join "`n"
    Write-Blob 'What Windows sees (USB devices from Yubico, vendor 1050)' $usbText

    $script:DeviceArgs = @()
    $list = Invoke-Ykman @('list')
    Write-Blob 'ykman list' $list.Text
    $lines = @($list.Text -split "`r?`n" | Where-Object { $_ -match '\S' -and $_ -notmatch '^(WARNING|ERROR)' })
    if ($lines.Count -gt $f.Count) { $f.Count = $lines.Count }
    if ($f.Count -ne 1) { return $f }

    $ser = Invoke-Ykman @('list', '--serials')
    $sers = @($ser.Text -split "`r?`n" | Where-Object { $_ -match '^\d+$' })
    if ($sers.Count -eq 1) { $f.Serial = $sers[0]; $script:DeviceArgs = @('--device', $f.Serial) }

    $info = Invoke-Ykman @('info')
    Write-Blob 'ykman info' $info.Text
    if ($info.Text -match '(?m)^Device type:\s*(.+)$')      { $f.DeviceType = $Matches[1].Trim() }
    if ($info.Text -match '(?m)^Firmware version:\s*(.+)$') { $f.Firmware = $Matches[1].Trim() }
    if (-not $f.Serial -and $info.Text -match '(?m)^Serial number:\s*(\d+)') { $f.Serial = $Matches[1] }
    if ($info.Text -match '(?m)^\s*(?:Yubico )?OTP\s+(Enabled|Disabled|Not available)') {
        $f.OtpState = $Matches[1]
    } elseif ($info.Text -match '(?m)^Enabled USB interfaces:\s*(.+)$') {
        if ($Matches[1] -match 'OTP') { $f.OtpState = 'Enabled' } else { $f.OtpState = 'Disabled' }
    } elseif ($f.Usb.Count -eq 1) {
        # ykman could not open it (most often: not administrator, and the key is FIDO-only).
        if ($f.Usb[0].Otp) { $f.OtpState = 'Enabled' } elseif ($f.Usb[0].Fido) { $f.OtpState = 'Not available' }
    }

    if ($f.OtpState -eq 'Enabled') {
        $oi = Invoke-Ykman @('otp', 'info')
        Write-Blob 'ykman otp info (what the two OTP slots hold; never their contents)' $oi.Text
        if ($oi.Text -match '(?m)^Slot 1:\s*(\w+)') { $f.Slot1 = $Matches[1].ToLower() }
        if ($oi.Text -match '(?m)^Slot 2:\s*(\w+)') { $f.Slot2 = $Matches[1].ToLower() }
    }
    return $f
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
    Write-Host ''
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

function Connect-Service {
    # One sign-in, the bench's own: it is what allows this session to enrol keys. Returns $true when
    # signed in. A session lasts 15 minutes; Assert-Session renews it between keys.
    Write-Host ''
    Write-Host '  SIGN IN to enrol keys: plug in YOUR OWN enrolled key and HOLD it about 3 s,' -ForegroundColor Cyan
    Write-Host '  or type the pilot code. Then unplug your key. (Enter alone = set keys up without enrolling.)' -ForegroundColor Cyan
    for ($try = 1; $try -le 3; $try++) {
        $code = Read-Masked '  Your key or the pilot code'
        if (-not $code) { return $false }
        $r = Invoke-Service -Path 'signin' -Body @{ otp = $code }
        if ($r.Ok -and $r.Body.session) {
            $script:Session = $r.Body.session
            $script:SessionUntil = (Get-Date).AddSeconds([int]$r.Body.expires_in)
            $script:SignedInAs = $r.Body.name
            Write-Host "  Signed in as $($r.Body.name). Keys set up from now on are enrolled at once." -ForegroundColor Green
            return $true
        }
        Write-Host "  Not signed in: $($r.Error)" -ForegroundColor Red
        if ($r.Status -eq 0 -or $r.Status -eq 403) { break }
    }
    return $false
}

function Assert-Session {
    # Before a NEW key goes in: if the sign-in ends within 3 minutes, renew it now, while the
    # technician's own key can still be the only one plugged in.
    if (-not $script:Enrol) { return }
    if ($script:Session -and (Get-Date).AddMinutes(3) -lt $script:SessionUntil) { return }
    Write-Host '  Your sign-in is about to end. Sign in again before the next key.' -ForegroundColor Yellow
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
    # Everything for the ONE key plugged in. Returns the line for the end-of-run summary.
    $f = Get-KeyFacts
    if ($f.Count -eq 0) {
        Write-Host '  NO KEY FOUND: Windows sees no device from Yubico. Push the key fully in, try another USB port,' -ForegroundColor Red
        Write-Host '  then press Enter again. (A key that lights up but is not listed above is not a Yubico key.)' -ForegroundColor Red
        return $null
    }
    if ($f.Count -gt 1) {
        Write-Host "  Found $($f.Count) keys. Leave exactly one plugged in." -ForegroundColor Yellow
        return $null
    }
    $label = $f.DeviceType
    if (-not $label -and $f.Usb.Count) { $label = $f.Usb[0].Meaning }
    $serial = $f.Serial
    $sl = $serial; if (-not $sl) { $sl = '(no serial readable)' }
    Write-Host ''
    Write-Host "  KEY: $label, serial $sl, firmware $($f.Firmware). OTP part: $($f.OtpState). Slot 1: $($f.Slot1). Slot 2: $($f.Slot2)." -ForegroundColor Cyan

    if ($f.OtpState -eq 'unknown' -and -not (Test-Admin)) {
        Write-Host '  ykman could not open this key, and this window is not administrator. Windows lets only an' -ForegroundColor Red
        Write-Host '  administrator read the FIDO part of a key. Close this window and run the line again; choose Yes' -ForegroundColor Red
        Write-Host '  when Windows asks.' -ForegroundColor Red
        return "  serial $sl  NOT READ (not administrator)"
    }
    if ($f.OtpState -eq 'Not available') {
        Write-Host '  FIDO-ONLY KEY: this model has NO one-time-code (OTP) part at all. It cannot type the start command' -ForegroundColor Yellow
        Write-Host '  or a one-time code, so the short/long press set-up does not apply to it. It is a Yubico' -ForegroundColor Yellow
        Write-Host '  "Security Key" (FIDO2 / passkey only). At the bench, type the start command by hand and sign in' -ForegroundColor Yellow
        Write-Host '  with the key by touch (FIDO2 sign-in). Set it aside for FIDO2 enrolment; nothing was changed.' -ForegroundColor Yellow
        return "  serial $sl  FIDO-ONLY ($label): no OTP part; FIDO2 sign-in only"
    }
    if ($f.OtpState -eq 'Disabled') {
        Write-Host '  The OTP part of this key is SWITCHED OFF (someone turned it off; the key has one). Without it the key' -ForegroundColor Yellow
        Write-Host '  cannot type the start command or a one-time code. Switching it on changes nothing else on the key.' -ForegroundColor Yellow
        $a = Read-Host '  Type ON to switch the OTP part on, or press Enter to leave the key unchanged'
        if ($a -cne 'ON') { return "  serial $sl  OTP switched off, left unchanged" }
        Invoke-YkmanChecked -YkArgs @('config', 'usb', '--enable', 'OTP', '--force') -What 'switch the OTP part on' | Out-Null
        Write-Host '  Switched on. The key restarts itself; waiting 4 s ...'
        Start-Sleep -Seconds 4
        $f = Get-KeyFacts
        if ($f.OtpState -ne 'Enabled') {
            Write-Host "  The OTP part still reads $($f.OtpState). Unplug the key, plug it back in, and run it again." -ForegroundColor Red
            return "  serial $sl  OTP switch-on did not take"
        }
    }

    $cred = $null
    $p = Read-BothPresses
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
    $v = Read-BothPresses
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
            $v = Read-BothPresses
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
    try {
        Start-Process -FilePath powershell.exe -Verb RunAs -ArgumentList $argLine | Out-Null
        # return, not exit: run as `irm ... | iex`, exit would close the technician's window.
        return
    } catch {
        Write-Host '  Not allowed. Carrying on WITHOUT administrator: FIDO-only keys cannot be read in this window.' -ForegroundColor Yellow
    }
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
        "computer:   $env:COMPUTERNAME   user: $env:USERDOMAIN\$env:USERNAME   administrator: $(Test-Admin)",
        "windows:    $($os.Caption) build $($os.BuildNumber)",
        "powershell: $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))",
        "service:    $Service",
        "log file:   $logPath"
    ) -join "`n")

    $yk = Find-Ykman
    if (-not $yk -or $yk.Version -lt $YkmanFloor) {
        if ($yk) { Write-Host "  ykman $($yk.Version) is older than $YkmanFloor; installing the newest from Yubico." }
        else     { Write-Host '  The YubiKey Manager command line (ykman) is not on this laptop yet; installing it from Yubico (once per laptop).' }
        $installed = $false
        try { $installed = Install-Ykman }
        catch { Write-Host "  Could not install ykman: $($_.Exception.Message)" -ForegroundColor Red }
        if ($installed) { $yk = Find-Ykman }
        if (-not $yk -or $yk.Version -lt $YkmanFloor) {
            Write-Host '  ykman is not ready, so no key was touched. Run the line again; if it fails twice, call the operator.' -ForegroundColor Red
            return
        }
    }
    $script:Ykman = $yk.Path
    $script:DeviceArgs = @()

    $script:AuthenticatorPath = Find-Authenticator
    if (-not $script:AuthenticatorPath) {
        Write-Host '  Yubico Authenticator (the window that shows the key) is not on this laptop yet; installing it from Yubico.'
        $ok = $false
        try { $ok = Install-Authenticator } catch { Write-Host "  Could not install Yubico Authenticator: $($_.Exception.Message)" -ForegroundColor Yellow }
        if ($ok) { $script:AuthenticatorPath = Find-Authenticator }
        if (-not $script:AuthenticatorPath) {
            Write-Host '  Carrying on without it: the window is a help to see the key, not needed to set it up.' -ForegroundColor Yellow
        }
    }

    $lang = (Get-WinUserLanguageList)[0]
    $authText = $script:AuthenticatorPath; if (-not $authText) { $authText = '(not installed)' }
    Write-Blob 'Tools' (@(
        "ykman:         $($yk.Version) at $script:Ykman",
        "Authenticator: $authText",
        "keyboard:      $($lang.LanguageTag) $($lang.InputMethodTips -join ',')",
        "start command a short press will type: $Command"
    ) -join "`n")
    # 00000409 is the US layout, whatever the language (en-US 0409:00000409, en-CA 1009:00000409).
    if (-not ($lang.InputMethodTips | Where-Object { $_ -like '*:00000409' })) {
        Write-Host "  WARNING: the keyboard layout is not English (US) ($($lang.LanguageTag)). Switch to it (Win+Space) before starting." -ForegroundColor Yellow
    }
    Open-Authenticator

    $script:Session = $null; $script:SessionUntil = Get-Date; $script:SignedInAs = $null
    $script:Enrol = Connect-Service
    if (-not $script:Enrol) {
        Write-Host '  NOT signed in: keys will be set up but NOT enrolled, and a key that needs a RESET is left alone.' -ForegroundColor Yellow
        Write-Host '  Run this again, signed in, in the office, to enrol them.' -ForegroundColor Yellow
    }

    $done = New-Object System.Collections.ArrayList
    while ($true) {
        Write-Host ''
        Write-Host '--------------------------------------------------------------------------------'
        Assert-Session
        $go = Read-Host '  Plug in ONE key (only one), then press Enter.  Q + Enter to finish'
        if ($go -match '^[qQ]') { break }
        try {
            $line = Invoke-OneKey
            if ($line) { [void]$done.Add($line) }
        } catch {
            Write-Host "  ERROR: $($_.Exception.Message)" -ForegroundColor Red
            Write-Host '  Nothing more was done to this key. Fix the cause and run it again; the log has the detail.'
            [void]$done.Add("  ERROR: $($_.Exception.Message)")
        }
    }

    Write-Host ''
    Write-Host "  This run ($($done.Count) key(s)):" -ForegroundColor Cyan
    if ($done.Count) { $done | ForEach-Object { Write-Host $_ } } else { Write-Host '  (none)' }
    if ($script:SignedInAs) { Write-Host "  Enrolments are recorded against $($script:SignedInAs)." }
} finally {
    Write-Host "  Log of this run: $logPath"
    if ($transcribing) { try { Stop-Transcript | Out-Null } catch { } }
}
