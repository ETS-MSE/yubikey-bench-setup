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
      4. checks both presses again, and records the key in a CSV for enrolment.

    The CSV goes to the operator, who enrols every key in it in one step.
    Until a key is enrolled its SHORT press already works (the start command); its LONG press signs
    in only after enrolment.

    Needs the YubiKey Manager CLI (ykman):  winget install --id Yubico.YubiKeyManagerCLI -e
    The laptop's keyboard layout must be English (US), the same as the bench's first setup screen.

    The FIDO2 / passkey / smart-card parts of a key are NOT touched -- only the two OTP slots.
    Procedure: the review report, section 13, "Enrol a technician's YubiKey".

.PARAMETER Csv
    Where to record the keys. Default: yubikeys-<date>.csv on the Desktop. Appends if it exists.

.EXAMPLE
    irm https://raw.githubusercontent.com/ETS-MSE/yubikey-bench-setup/v1.0.0/Setup-YubiKeys.ps1 | iex
    Runs the published copy from Windows Terminal (Windows PowerShell or PowerShell 7), on any network.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Setup-YubiKeys.ps1
#>
[CmdletBinding()]
param(
    [string]$Csv = (Join-Path ([Environment]::GetFolderPath('Desktop')) ("yubikeys-{0}.csv" -f (Get-Date -Format 'yyyy-MM-dd')))
)
$ErrorActionPreference = 'Stop'

# The start command. EXACTLY 38 characters: the most a YubiKey static slot holds.
$Command    = 'curl https://ets.azurewebsites.net|cmd'
# What keys set up before 2026-10-29 may type. Replaced without asking: it is ours, and dead.
$OldCommand = 'curl https://p.exchangetech.ca/b|cmd'
# A Yubico OTP: modhex letters only, 44 long (12 public id + 32).
$OtpPattern = '^[cbdefghijklnrtuv]{44}$'

function Find-Ykman {
    $c = Get-Command ykman.exe -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    foreach ($root in @("$env:ProgramFiles\Yubico", "${env:ProgramFiles(x86)}\Yubico")) {
        if (Test-Path $root) {
            $f = Get-ChildItem -Path $root -Filter ykman.exe -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($f) { return $f.FullName }
        }
    }
    return $null
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

function Add-CsvRow {
    param([hashtable]$Row)
    $o = New-Object PSObject -Property $Row | Select-Object date, serial, public_id, holder, result, otp
    if (Test-Path $Csv) { $o | Export-Csv -Path $Csv -NoTypeInformation -Append -Encoding ASCII }
    else                { $o | Export-Csv -Path $Csv -NoTypeInformation -Encoding ASCII }
}

# ------------------------------------------------------------------------------------------- main
$script:Ykman = Find-Ykman
if (-not $script:Ykman) {
    Write-Host 'YubiKey Manager CLI (ykman) is not installed. Install it, then run this again:' -ForegroundColor Red
    Write-Host '    winget install --id Yubico.YubiKeyManagerCLI -e'
    # return, not exit: run as `irm ... | iex`, exit would close the technician's window.
    return
}
$lang = (Get-WinUserLanguageList)[0]
Write-Host ''
Write-Host '  ETS bench YubiKey setup' -ForegroundColor Cyan
Write-Host "  ykman:  $script:Ykman"
Write-Host "  record: $Csv"
Write-Host "  start command a short press will type: $Command"
# 00000409 is the US layout, whatever the language (en-US 0409:00000409, en-CA 1009:00000409).
if (-not ($lang.InputMethodTips | Where-Object { $_ -like '*:00000409' })) {
    Write-Host "  WARNING: the keyboard layout is not English (US) ($($lang.LanguageTag)). Switch to it (Win+Space) before starting." -ForegroundColor Yellow
}

$n = 0
while ($true) {
    Write-Host ''
    Write-Host '--------------------------------------------------------------------------------'
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
            Add-CsvRow @{ date = (Get-Date -Format s); serial = $serial; public_id = ''; holder = ''; result = 'set-aside'; otp = '' }
            continue
        }
        if ($plan.Action -eq 'skipped') {
            Write-Host '  Skipped: nothing was changed on this key.' -ForegroundColor Yellow
            Add-CsvRow @{ date = (Get-Date -Format s); serial = $serial; public_id = ''; holder = ''; result = 'skipped'; otp = '' }
            continue
        }

        # Prove it the way the bench will use it.
        Write-Host '  Checking both presses again...'
        $v = Read-BothPresses
        if ($v.Short.Kind -ne 'command' -or $v.Long.Kind -ne 'otp') {
            Write-Host "  CHECK FAILED: short press = $($v.Short.Kind), long press = $($v.Long.Kind). Run this key again; if it fails twice, set it aside." -ForegroundColor Red
            Add-CsvRow @{ date = (Get-Date -Format s); serial = $serial; public_id = ''; holder = ''; result = 'check-failed'; otp = '' }
            continue
        }
        $publicId = $v.Long.Otp.Substring(0, 12)
        $holder = (Read-Host '  Who will carry this key? Full name (blank = a spare, not enrolled yet)').Trim()
        # The OTP is single-use; the operator's enrolment spends it with YubiCloud to prove the key.
        Add-CsvRow @{ date = (Get-Date -Format s); serial = $serial; public_id = $publicId; holder = $holder; result = 'ready'; otp = $v.Long.Otp }
        $n++
        $who = if ($holder) { $holder } else { 'SPARE' }
        Write-Host "  READY: serial $serial, public id $publicId, for $who. Label the key with that name and serial." -ForegroundColor Green
    } catch {
        Write-Host "  ERROR on serial ${serial}: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host '  Nothing more was done to this key. Fix the cause and run it again.'
    }
}

Write-Host ''
Write-Host "  $n key(s) ready this run. Send this file to the operator for enrolment:" -ForegroundColor Cyan
Write-Host "    $Csv"
Write-Host '  It holds no password. Each key''s code in it works once, for its enrolment.'
