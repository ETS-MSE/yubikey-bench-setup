# ETS bench YubiKey setup

One PowerShell script, `Setup-YubiKeys.ps1`, that Exchange Technology Services technicians run on the
provisioning laptop to prepare the YubiKeys used at the device-provisioning bench.

## Run it

Open **Windows Terminal** (Windows PowerShell 5.1 or PowerShell 7) and paste:

```powershell
irm https://raw.githubusercontent.com/ETS-MSE/yubikey-bench-setup/v1.0.0/Setup-YubiKeys.ps1 | iex
```

The address names a release tag, so the line always runs the same reviewed copy. Each new version gets a
new tag and a new line; nothing changes under an existing one.

It needs the YubiKey Manager CLI once per laptop:

```powershell
winget install --id Yubico.YubiKeyManagerCLI -e
```

## What it does

For each key, one at a time, it reads what a short press and a long press type today, then:

| What the presses typed | What the script does |
|---|---|
| short: a Yubico code, long: nothing | New key: writes the bench start command and swaps the slots |
| short: the start command, long: a code | Already set up: changes nothing |
| short: a code, long: something else | Asks first; type `OVERWRITE` to replace it |
| no Yubico code on either press | Set it aside: it can never sign in at the bench |

It then proves both presses and appends the key's serial, public id and holder to
`yubikeys-<date>.csv` on the Desktop.

It touches **only the two OTP slots**. FIDO2, passkeys, PIV / smart card and OATH on the key are not
read or changed. It contains no secret: the only value it writes is the bench start command, which is
what a short press of a set-up key types anyway.

## Verify

| Release | File | SHA-256 |
|---|---|---|
| v1.0.0 | `Setup-YubiKeys.ps1` | `a88414f695a5f620bf4bb787e4ed2de8d4cdad37e656f957a297a538f0f35b37` |

```powershell
(Get-FileHash .\Setup-YubiKeys.ps1 -Algorithm SHA256).Hash
```

## Licence

MIT. See [LICENSE](LICENSE).
