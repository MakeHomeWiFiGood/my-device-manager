# My Device Manager

An early LuCI application for OpenWrt 25.12.x. Current scope: device discovery, a persistent MAC-keyed friendly-name registry, and integration with standard OpenWrt DHCP static reservations.

## Install from a script

The project uses a direct installer, so building an APK with the OpenWrt SDK is not required. Run these commands in an SSH session as `root` on the router:

```sh
wget -O /root/mdm-install.sh https://raw.githubusercontent.com/MakeHomeWiFiGood/my-device-manager/main/install.sh
sh /root/mdm-install.sh install
```

The installer downloads the source bundle over HTTPS, checks the archive and required LuCI files, backs up files it replaces, preserves an existing `/etc/config/my_device_manager`, and restarts `rpcd`. It requires LuCI and access to `raw.githubusercontent.com`.

To remove the app and restore files that existed before installation, run:

```sh
sh /root/mdm-install.sh uninstall
```

Keep `/root/mdm-install.sh` until you're sure you no longer need the uninstaller. Installer state and backups are kept under `/root/.my-device-manager`; the uninstaller intentionally leaves those backups on disk.

## Current limitations

Wi-Fi band enforcement and per-device speed enforcement are not implemented yet. This project does not configure or bypass mwan3, Tachyon, proxy routing, or existing firewall rules. The GitHub Actions check validates the installer syntax and bundled source, but it does not perform a live installation on the router.

See `STATUS.md` for current implementation status.
