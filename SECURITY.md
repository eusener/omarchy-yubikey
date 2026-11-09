# Security

This plugin edits PAM stacks as root, handles TOTP secrets, and configures
SSH, so a bug here can be a security bug.

## Reporting a vulnerability

Please report it privately through GitHub:
**Security → Report a vulnerability** on this repository
(<https://github.com/eusener/omarchy-yubikey/security/advisories/new>).
Do not open a public issue for it.

Include what you ran, what happened, and the output of
`bin/omarchy-yubikey doctor` with serial numbers removed.

## What the plugin does with privileges and secrets

- **Root** is used only for writing `/etc/pam.d/*` and `/etc/fido2/fido2`,
  enabling `pcscd.socket`, installing packages, and `systemd-cryptenroll`.
  It goes through `sudo` in a terminal or `pkexec` from the panel, so every
  use asks for your password. PAM edits only ever add or remove one
  `auth sufficient pam_u2f.so` line, back the file up first, and restore it
  if the result comes out empty.
- **TOTP secrets** never appear as command-line arguments. The panel hands
  them over in the environment, the script feeds them to `ykman` on stdin,
  and the QR-code screenshot is written to `$XDG_RUNTIME_DIR` and deleted
  right away.
- **PINs, PUKs and touches** are always entered in a terminal, by `ykman` or
  `ssh-keygen` themselves. The panel never sees them.
- **Nothing is sent over the network.** The only outbound action is opening
  a provider's settings page in your browser.

The script lives in your plugin directory, which you own. Anything able to
modify it as your user could also change what runs the next time you approve
a `sudo`/`pkexec` prompt from the panel, so keep the plugin directory
writable only by you (the default).
