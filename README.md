# ETS bench YubiKey setup

One PowerShell script, `Setup-YubiKeys.ps1`, that Exchange Technology Services technicians run on the
provisioning laptop to prepare the YubiKeys used at the device-provisioning bench.

## Run it

Open **Windows Terminal** (Windows PowerShell 5.1 or PowerShell 7) and paste:

```powershell
irm https://raw.githubusercontent.com/ETS-MSE/yubikey-bench-setup/v1.2.0/Setup-YubiKeys.ps1 | iex
```

The address names a release tag, so the line always runs the same reviewed copy. Each new version gets a
new tag and a new line; nothing changes under an existing one.

That one line is all. The script needs the YubiKey Manager CLI (`ykman`) and installs it itself the first
time on a laptop (or when the one there is older than 5.0.0): it downloads the newest x64 installer from
Yubico's own release folder, [developers.yubico.com/yubikey-manager/Releases](https://developers.yubico.com/yubikey-manager/Releases/),
and runs it only if Windows reports a **Valid** signature from **Yubico AB**. Anything else is refused before
the installer starts, and the download is deleted. Windows asks once to allow the install unless the window
is already elevated.

## What it does

First it asks for one sign-in, the same one the bench uses: a long press of your own enrolled key, or the
pilot code while pilot mode is open. That sign-in is what allows the session to enrol keys. Press Enter
alone to set keys up without enrolling them. Enrolling works only on the ETS office network.

Then, for each key, one at a time, it reads what a short press and a long press type today, then:

| What the presses typed | What the script does |
|---|---|
| short: a Yubico code, long: nothing | New key: writes the bench start command and swaps the slots |
| short: the start command, long: a code | Already set up: changes nothing |
| short: a code, long: something else | Asks first; type `OVERWRITE` to replace it |
| no Yubico code on either press | Set it aside: it can never sign in at the bench |

It then proves both presses, asks who will carry the key, and **enrols it there and then**: from that
moment its long press signs in at the bench. Nothing is written to disk and there is no file to send
anyone. A key left without a holder is a spare; run the script again with it when it is handed to someone.
Enrolment only ever adds a key: one already enrolled to someone else, or disabled, is refused.

On the key it touches **only the two OTP slots**. FIDO2, passkeys, PIV / smart card and OATH on the key are not
read or changed. It contains no secret: the only value it writes is the bench start command, which is
what a short press of a set-up key types anyway.

## Verify

| Release | File | SHA-256 |
|---|---|---|
| v1.2.0 | `Setup-YubiKeys.ps1` | `74b2eb432b6f529fac6a8e681e15d57b6a6f24c52953824295911b3b16917509` |
| v1.1.0 | `Setup-YubiKeys.ps1` | `6bb23493630946db4029c4fae3a7067a5392aeb6671732bda577bf98b01d3667` |
| v1.0.0 | `Setup-YubiKeys.ps1` | `a88414f695a5f620bf4bb787e4ed2de8d4cdad37e656f957a297a538f0f35b37` |

```powershell
(Get-FileHash .\Setup-YubiKeys.ps1 -Algorithm SHA256).Hash
```

## Licence

MIT. See [LICENSE](LICENSE).
