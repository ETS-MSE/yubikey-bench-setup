<#
.SYNOPSIS
    Set up ETS bench YubiKeys, one after another, on the dedicated Windows 11 provisioning laptop.

.DESCRIPTION
    For each key it:
      1. reads what the key types today: a SHORT press (slot 1) and a LONG press (slot 2, ~3 s);
      2. decides from that what to do -- a new key, a key already set up, a key that holds
         something else (asks before overwriting), or a key that can never sign in (set aside);
      3. writes the bench start command so a SHORT press types it, keeping the Yubico OTP on the
         LONG press (the sign-in);
      4. checks both presses again, and ENROLS the key to the person who will carry it, there and
         then: from that moment its long press signs in at the bench.

    Enrolling needs one sign-in at the start of the session, the same one the bench asks for: a long
    press of YOUR OWN enrolled key, or the pilot code while pilot mode is open. That is what stops a
    stranger on the office network enrolling a key for themselves. Every enrolment records who made it.
    The provisioning service answers only the office network, so enrol in the office. A key set up
    elsewhere still gets its short press; run this again in the office to enrol it.

    It needs the YubiKey Manager CLI (ykman) and installs it itself the first time: the newest x64
    installer from developers.yubico.com, run only if Windows confirms it is signed by Yubico AB.
    Windows asks once to allow that install unless the window is already elevated.
    The laptop's keyboard layout must be English (US), the same as the bench's first setup screen.

    The FIDO2 / passkey / smart-card parts of a key are NOT touched -- only the two OTP slots.
    Procedure: the review report, section 13, "Enrol a technician's YubiKey".

.PARAMETER Service
    The provisioning service. Default: the production one. Office network only.

.EXAMPLE
    irm https://raw.githubusercontent.com/ETS-MSE/yubikey-bench-setup/v1.2.0/Setup-YubiKeys.ps1 | iex
    Runs the published copy from Windows Terminal (Windows PowerShell or PowerShell 7), on any network.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Setup-YubiKeys.ps1
#>
[CmdletBinding()]
param(
    [string]$Service = 'https://func-ets-provision-cc.azurewebsites.net'
)
$ErrorActionPreference = 'Stop'
# Windows PowerShell 5.1 may still offer TLS 1.0 first; the service accepts 1.2 only.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# The start command. EXACTLY 38 characters: the most a YubiKey static slot holds.
$Command    = 'curl https://ets.azurewebsites.net|cmd'
# What keys set up before 2026-10-29 may type. Replaced without asking: it is ours, and dead.
$OldCommand = 'curl https://p.exchangetech.ca/b|cmd'
# A Yubico OTP: modhex letters only, 44 long (12 public id + 32).
$OtpPattern = '^[cbdefghijklnrtuv]{44}$'

# The oldest ykman this script is written against. A missing or older one is replaced by the newest.
$YkmanFloor   = [version]'5.0.0'
# Yubico's own release folder for the YubiKey Manager CLI; the signed Windows installer is published here.
$YkmanReleases = 'https://developers.yubico.com/yubikey-manager/Releases/'

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

function Install-Ykman {
    # The newest x64 installer Yubico publishes, from Yubico itself; run only if Windows says it is
    # signed by Yubico AB. Returns $true when msiexec reports success.
    $ProgressPreference = 'SilentlyContinue'   # Windows PowerShell 5.1 downloads ~10x slower with the bar
    $page = Invoke-WebRequest -Uri $YkmanReleases -UseBasicParsing
    $newest = [regex]::Matches($page.Content, 'yubikey-manager-(\d+\.\d+\.\d+)-win64\.msi(?!\.sig)') |
        ForEach-Object { [version]$_.Groups[1].Value } | Sort-Object -Descending | Select-Object -First 1
    if (-not $newest) {
        Write-Host "  Could not find the ykman installer on $YkmanReleases" -ForegroundColor Red
        return $false
    }
    $name = "yubikey-manager-$newest-win64.msi"
    $dir  = Join-Path $env:TEMP ('ets-ykman-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir | Out-Null
    $msi  = Join-Path $dir $name
    $log  = Join-Path $dir 'install.log'
    $ok   = $false
    try {
        Write-Host "  Downloading $name from Yubico ..."
        Invoke-WebRequest -Uri ($YkmanReleases + $name) -OutFile $msi -UseBasicParsing
        $sig = Get-AuthenticodeSignature -FilePath $msi
        $signer = '(none)'
        if ($sig.SignerCertificate) { $signer = $sig.SignerCertificate.Subject }
        if ($sig.Status -ne 'Valid' -or $signer -notmatch '(^|,\s*)O=Yubico AB(,|$)') {
            Write-Host "  REFUSED: the download is not validly signed by Yubico AB (signature $($sig.Status), signer $signer)." -ForegroundColor Red
            Write-Host '  Nothing was installed.' -ForegroundColor Red
            return $false
        }
        Write-Host "  Signature: Valid, signed by Yubico AB. Installing ykman $newest ..."
        $msiArgs = @('/i', "`"$msi`"", '/qn', '/norestart', '/l*v', "`"$log`"")
        $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        if ($admin) {
            $proc = Start-Process -FilePath msiexec.exe -ArgumentList $msiArgs -Wait -PassThru
        } else {
            Write-Host '  Windows will ask to allow the install (once per laptop): choose Yes.' -ForegroundColor Yellow
            try {
                $proc = Start-Process -FilePath msiexec.exe -ArgumentList $msiArgs -Verb RunAs -Wait -PassThru
            } catch {
                Write-Host '  The install was not allowed, so ykman is still missing. Run the line again and choose Yes.' -ForegroundColor Red
                return $false
            }
        }
        # 3010: installed, a restart is pending -- ykman works without it.
        if ($proc.ExitCode -notin @(0, 3010)) {
            Write-Host "  The ykman installer failed (msiexec exit $($proc.ExitCode)). Its log is kept at $log" -ForegroundColor Red
            return $false
        }
        $ok = $true
        return $true
    } finally {
        if ($ok) { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
        else     { Remove-Item -LiteralPath $msi -Force -ErrorAction SilentlyContinue }
    }
}

function Invoke-Ykman {
    param([string[]]$YkArgs)
    # Windows PowerShell 5.1: with ErrorActionPreference=Stop, a native command's stderr line
    # redirected by 2>&1 becomes a terminating error. ykman prints warnings there; read them instead.
    $ErrorActionPreference = 'Continue'
    $out = & $script:Ykman @YkArgs 2>&1 | ForEach-Object { "$_" } | Out-String
    return @{ Code = $LASTEXITCODE; Text = $out.Trim() }
}

function Read-Press {
    # The key types like a keyboard and ends with Enter, so Read-Host receives it. A slot that
    # holds nothing types nothing: the technician presses Enter. A value that is neither ours nor
    # an OTP may be somebody's static password, so it is classified and then dropped, never kept.
    param([string]$Prompt)
    $v = Read-Host $Prompt
    $v = ("$v").Trim()
    if ($v -eq '')                    { return @{ Kind = 'empty' } }
    if ($v -ceq $Command)             { return @{ Kind = 'command' } }
    if ($v -ceq $OldCommand)          { return @{ Kind = 'old-command' } }
    if ($v -cmatch $OtpPattern)       { return @{ Kind = 'otp'; Otp = $v } }
    return @{ Kind = 'other' }
}

function Read-BothPresses {
    Write-Host ''
    $s = Read-Press '  SHORT press now (tap, under 1.5 s). If nothing appears in 3 s, press Enter'
    $l = Read-Press '  LONG press now (hold about 3 s).    If nothing appears in 5 s, press Enter'
    return @{ Short = $s; Long = $l }
}

function Confirm-Overwrite {
    param([string]$Slot)
    Write-Host ''
    Write-Host "  Slot $Slot holds something that is NOT ours (perhaps a static password somebody uses)." -ForegroundColor Yellow
    Write-Host "  Writing the start command there deletes it for good." -ForegroundColor Yellow
    $a = Read-Host '  Type OVERWRITE to replace it, or press Enter to skip this key'
    return ($a -ceq 'OVERWRITE')
}

function Set-Static {
    param([int]$Slot)
    $r = Invoke-Ykman @('otp', 'static', "$Slot", $Command, '--keyboard-layout', 'US', '--force')
    if ($r.Code -ne 0) { throw "ykman could not write slot ${Slot}: $($r.Text)" }
}

function Invoke-Swap {
    $r = Invoke-Ykman @('otp', 'swap', '--force')
    if ($r.Code -ne 0) { throw "ykman could not swap the slots: $($r.Text)" }
}

function Get-Plan {
    # What to do, from what the two presses typed. Returns @{ Action; Why }.
    #   Action: done | swap | write2swap | write1 | ask2swap | ask1 | aside
    param($S, $L)
    $sk = $S.Kind; $lk = $L.Kind
    if ($sk -eq 'command' -and $lk -eq 'otp')   { return @{ Action = 'done';       Why = 'already set up' } }
    if ($sk -eq 'otp'     -and $lk -eq 'command') { return @{ Action = 'swap';     Why = 'set up but not swapped' } }
    if ($sk -eq 'otp'     -and $lk -in @('empty', 'old-command')) { return @{ Action = 'write2swap'; Why = 'new key (or the old command)' } }
    if ($lk -eq 'otp'     -and $sk -in @('empty', 'old-command')) { return @{ Action = 'write1';     Why = 'short press is empty or the old command' } }
    if ($sk -eq 'otp'     -and $lk -eq 'other')   { return @{ Action = 'ask2swap'; Why = 'long press holds something else' } }
    if ($lk -eq 'otp'     -and $sk -eq 'other')   { return @{ Action = 'ask1';     Why = 'short press holds something else' } }
    if ($sk -eq 'otp'     -and $lk -eq 'otp')     { return @{ Action = 'aside';    Why = 'both slots hold a Yubico OTP -- one of them is not the factory one; ask the operator' } }
    return @{ Action = 'aside'; Why = 'no Yubico OTP on either press -- the factory OTP was overwritten, so this key can never sign in here' }
}

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
    # box is not, and a plain Read-Host shows it to anyone behind the technician.
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
    # the key to YubiCloud once, here. Returns @{ Ok; Message }.
    param([string]$Otp, [string]$Holder, [string]$Serial)
    $body = @{ otp = $Otp; name = $Holder; serial = $Serial }
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
    if ($r.Ok -and $r.Body.already) { return @{ Ok = $true; Message = "already enrolled to $($r.Body.name)" } }
    if ($r.Ok -and $r.Body.enrolled) { return @{ Ok = $true; Message = "enrolled to $($r.Body.name)" } }
    return @{ Ok = $false; Message = $r.Error }
}

# ------------------------------------------------------------------------------------------- main
Write-Host ''
Write-Host '  ETS bench YubiKey setup' -ForegroundColor Cyan
$yk = Find-Ykman
if (-not $yk -or $yk.Version -lt $YkmanFloor) {
    if ($yk) { Write-Host "  ykman $($yk.Version) is older than $YkmanFloor; installing the newest from Yubico." }
    else     { Write-Host '  The YubiKey Manager CLI (ykman) is not on this laptop yet; installing it from Yubico (once per laptop).' }
    $installed = $false
    try { $installed = Install-Ykman }
    catch { Write-Host "  Could not install ykman: $($_.Exception.Message)" -ForegroundColor Red }
    if ($installed) { $yk = Find-Ykman }
    if (-not $yk -or $yk.Version -lt $YkmanFloor) {
        Write-Host '  ykman is not ready, so no key was touched. Run the line again; if it fails twice, call the operator.' -ForegroundColor Red
        # return, not exit: run as `irm ... | iex`, exit would close the technician's window.
        return
    }
}
$script:Ykman = $yk.Path
$lang = (Get-WinUserLanguageList)[0]
Write-Host "  ykman:  $($yk.Version) at $script:Ykman"
Write-Host "  start command a short press will type: $Command"
# 00000409 is the US layout, whatever the language (en-US 0409:00000409, en-CA 1009:00000409).
if (-not ($lang.InputMethodTips | Where-Object { $_ -like '*:00000409' })) {
    Write-Host "  WARNING: the keyboard layout is not English (US) ($($lang.LanguageTag)). Switch to it (Win+Space) before starting." -ForegroundColor Yellow
}

$script:Session = $null; $script:SessionUntil = Get-Date; $script:SignedInAs = $null
$script:Enrol = Connect-Service
if (-not $script:Enrol) {
    Write-Host '  NOT signed in: keys will be set up but NOT enrolled. Their short press works; their long press' -ForegroundColor Yellow
    Write-Host '  signs in only after you run this again, signed in, in the office.' -ForegroundColor Yellow
}

$done = New-Object System.Collections.ArrayList
while ($true) {
    Write-Host ''
    Write-Host '--------------------------------------------------------------------------------'
    Assert-Session
    $go = Read-Host '  Plug in ONE key (only one), then press Enter.  Q + Enter to finish'
    if ($go -match '^[qQ]') { break }

    $list = Invoke-Ykman @('list', '--serials')
    $serials = @($list.Text -split "`r?`n" | Where-Object { $_ -match '^\d+$' })
    if ($serials.Count -ne 1) {
        Write-Host "  Found $($serials.Count) keys. Leave exactly one plugged in." -ForegroundColor Yellow
        continue
    }
    $serial = $serials[0]
    Write-Host "  Key serial $serial"

    try {
        $p = Read-BothPresses
        $plan = Get-Plan $p.Short $p.Long
        Write-Host "  Short press: $($p.Short.Kind).  Long press: $($p.Long.Kind).  -> $($plan.Why)"

        switch ($plan.Action) {
            'done'       { }
            'swap'       { Invoke-Swap }
            'write2swap' { Set-Static 2; Invoke-Swap }
            'write1'     { Set-Static 1 }
            'ask2swap'   { if (Confirm-Overwrite 2) { Set-Static 2; Invoke-Swap } else { $plan.Action = 'skipped' } }
            'ask1'       { if (Confirm-Overwrite 1) { Set-Static 1 } else { $plan.Action = 'skipped' } }
        }
        if ($plan.Action -eq 'aside') {
            Write-Host "  SET THIS KEY ASIDE: $($plan.Why)." -ForegroundColor Red
            [void]$done.Add("  serial $serial  SET ASIDE")
            continue
        }
        if ($plan.Action -eq 'skipped') {
            Write-Host '  Skipped: nothing was changed on this key.' -ForegroundColor Yellow
            [void]$done.Add("  serial $serial  skipped, unchanged")
            continue
        }

        # Prove it the way the bench will use it.
        Write-Host '  Checking both presses again...'
        $v = Read-BothPresses
        if ($v.Short.Kind -ne 'command' -or $v.Long.Kind -ne 'otp') {
            Write-Host "  CHECK FAILED: short press = $($v.Short.Kind), long press = $($v.Long.Kind). Run this key again; if it fails twice, set it aside." -ForegroundColor Red
            [void]$done.Add("  serial $serial  CHECK FAILED")
            continue
        }
        $publicId = $v.Long.Otp.Substring(0, 12)
        $holder = (Read-Host '  Who will carry this key? Full name (blank = a spare, not enrolled yet)').Trim()
        if (-not $holder) {
            Write-Host "  READY as a SPARE: serial $serial, public id $publicId. Not enrolled: when it is handed to someone," -ForegroundColor Green
            Write-Host '  run this again with the key and type their name.' -ForegroundColor Green
            [void]$done.Add("  serial $serial  $publicId  spare, not enrolled")
            continue
        }
        if (-not $script:Enrol) {
            Write-Host "  READY but NOT ENROLLED: serial $serial, public id $publicId, for $holder (not signed in)." -ForegroundColor Yellow
            [void]$done.Add("  serial $serial  $publicId  $holder  NOT ENROLLED (not signed in)")
            continue
        }
        # The long press just read is unused; the service spends it with YubiCloud to prove the key.
        $e = Register-Key -Otp $v.Long.Otp -Holder $holder -Serial $serial
        if ($e.Ok) {
            Write-Host "  ENROLLED: serial $serial, public id $publicId, $($e.Message). Its long press signs in at the bench now." -ForegroundColor Green
            Write-Host "  Label the key with that name and serial."
            [void]$done.Add("  serial $serial  $publicId  $holder  ENROLLED")
        } else {
            Write-Host "  SET UP but NOT ENROLLED: $($e.Message)" -ForegroundColor Red
            Write-Host '  Run this key again to retry.'
            [void]$done.Add("  serial $serial  $publicId  $holder  NOT ENROLLED: $($e.Message)")
        }
    } catch {
        Write-Host "  ERROR on serial ${serial}: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host '  Nothing more was done to this key. Fix the cause and run it again.'
    }
}

Write-Host ''
Write-Host "  This run ($($done.Count) key(s)):" -ForegroundColor Cyan
if ($done.Count) { $done | ForEach-Object { Write-Host $_ } } else { Write-Host '  (none)' }
if ($script:SignedInAs) { Write-Host "  Enrolments are recorded against $($script:SignedInAs). Nothing to send anyone." }
