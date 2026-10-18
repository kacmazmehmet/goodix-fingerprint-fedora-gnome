# Goodix Fingerprint on Fedora GNOME

A small, **unofficial** Fedora 44 GNOME installation helper for the USB Goodix fingerprint sensor **`27c6:5125`**. It builds the open-source driver from [sorguido/goodix-27c6-5125](https://github.com/sorguido/goodix-27c6-5125), then exposes its `libfprint` runtime **only to Fedora's `fprintd` service**, without installing KDE/Plasma components or replacing the distribution's `/usr/lib64/libfprint`.

> **Status: community proof of concept.** Manually validated on one Huawei MateBook (BOD-WXX9), Fedora Linux 44 x86_64, GNOME 50.5, Goodix USB `27c6:5125`, October 2026. Enrollment (21 accepted samples), `fprintd-verify` (`verify-match`), and GNOME screen unlock succeeded. **This script packages the successful manual procedure but has not itself been tested end-to-end on a clean Fedora host.** GDM login after reboot, all firmware versions, SELinux policy variants, future Fedora versions, and Windows dual-boot interactions are not independently validated here.

## Supported target and prerequisites

- Fedora **44 x86_64**, GNOME, a working local password login, sudo permissions and network access.
- USB fingerprint sensor **`27c6:5125`** (check using `lsusb`). Other Goodix device IDs are **not supported** by this helper.
- Upstream currently recognizes reader firmware `GF_ST411SEC_APP_12508` and `GF_ST411SEC_APP_12509`, but this helper does **not** determine the installed firmware version before starting.
- The Fedora 44 build is deliberately version-locked by the upstream production builder; do **not** bypass its compatibility checks.

**Risk:** This installs an experimental security-sensitive library into the authentication path. Review the source before executing, retain working password/TTY access, keep backups, and do not use it on production-critical machines. On first use the upstream driver may provision persistent sensor pairing state (not a firmware flash). Dual-boot/Windows Hello behavior is **not** guaranteed by this helper.

## Installation

Clone/download this repository, review `fingerprint.sh`, and run it as your **regular user** (do **not** use `sudo bash fingerprint.sh`):

```bash
bash fingerprint.sh status
bash fingerprint.sh install
```

The installation:

1. Confirms Fedora 44 x86_64 and USB ID `27c6:5125`; refuses an existing private Goodix installation rather than overwriting it.
2. Installs the Fedora build prerequisites; clones the **upstream main branch** into a private temporary directory; executes upstream `production/build-public.py`.
3. Ensures `/var/lib/fprint/goodix-5125-state-v2` exists with restricted permissions and expected SELinux label **without copying its contents**.
4. Copies the built runtime to `/usr/local/lib64/goodix-27c6-5125`, and creates only `/etc/systemd/system/fprintd.service.d/90-goodix-5125-runtime.conf` with `LD_LIBRARY_PATH` for `fprintd`.
5. Restarts `fprintd`. It does not edit GDM, GNOME Shell, KDE, authselect or PAM.

A successful run ends in `INSTALL=PASS`. The package manager, compiler, and service must all succeed. If a post-build installation step fails, the script attempts to restore the original `fprintd`; report any incomplete rollback. **Never blindly pipe a remote script to `sudo bash`.**

### Enroll and verify

```bash
fprintd-enroll -f right-index-finger
fprintd-list "$USER"
fprintd-verify
```

Lift and reposition the finger after each `enroll-stage-passed`. The tested version required **21** accepted samples. Do not interrupt until `enroll-completed` appears. Expect `verify-match` from `fprintd-verify` before enabling authentication.

### Enable fingerprint authentication in GNOME

Check the active policy first:

```bash
authselect current
sudo authselect check
```

If the configuration is valid but does not list `with-fingerprint`, enable it **only after successful verification**:

```bash
sudo authselect enable-feature with-fingerprint
sudo authselect apply-changes
```

This is often **already enabled** on Fedora, so changing it may be unnecessary. Keep password authentication working. Test the lock screen with `loginctl lock-session`, then test cold login separately after reboot. A password-encrypted GNOME Keyring may still request the password.

## Inspect and remove

```bash
bash fingerprint.sh status
bash fingerprint.sh uninstall
```

The uninstaller removes **only files marked as managed by this script**, restarts the stock `fprintd`, and **does not delete pairing keys, fingerprint templates, or change PAM/authselect**. It will refuse to remove a pre-existing/manual installation that it did not create.

If you followed the **earlier manual setup** using the same paths (rather than this script), remove only your manual override and private library **after** inspecting them:

```bash
sudo rm -f /etc/systemd/system/fprintd.service.d/90-goodix-5125-runtime.conf
sudo systemctl daemon-reload
sudo systemctl restart fprintd.service
```

The above manual commands restore Fedora's standard library selection but leave the private runtime files in place. Avoid deleting sensitive pairing state or templates just to uninstall the driver.

## Troubleshooting

```bash
lsusb -d 27c6:5125
systemctl show fprintd.service -p Environment
sudo journalctl -u fprintd -b -n 60 --no-pager
fprintd-verify
```

- `No devices available`: the driver may not be loaded, the firmware may be incompatible, or the reader could be unavailable.
- `NoEnrolledPrints`: finish enrollment; a `Ctrl+C` before `enroll-completed` leaves no registered print.
- `enroll-stage-passed`: expected progress, **not an error**.
- Fedora update breaks authentication: check the fprintd service and version compatibility; do not reinstall or overwrite system libraries blindly.
- GNOME login issues: use the password fallback or a text console, and uninstall this helper's integration.

## Privacy and attribution

- **Never commit** `/var/lib/fprint/`, host pairing state, USB captures, biometric templates, device secrets, private firmware, or personal logs to GitHub.
- The source driver is written and maintained by [sorguido/goodix-27c6-5125](https://github.com/sorguido/goodix-27c6-5125) and contributors. See their [license](https://github.com/sorguido/goodix-27c6-5125/blob/main/LICENSE), [source/build process](https://github.com/sorguido/goodix-27c6-5125/blob/main/production/build-public.py), and [supported configurations](https://github.com/sorguido/goodix-27c6-5125/blob/main/docs/VALIDATION.md).
- This repository **does not bundle or claim authorship of the upstream driver**; it only contains an original helper script and documentation, offered under the MIT license. Upstream source and binary have their own licenses.
- The manually successful upstream source build printed `GOODIX_BUILD=PASS SOURCE_ID=e67de418620282d54de2ecbd56eb7c74ffd3deec27176cad629e0c55a67e9e18`. **SOURCE_ID is a build/source inventory hash, not a Git commit ID.** The helper clones `main`, which may evolve; a later build is not guaranteed to have the same hash.

Contributions and independently reproduced results are welcome; please specify hardware USB ID, Fedora/GNOME versions, firmware (if known), and whether enroll, verify and screen unlock worked, without sharing sensitive data.
