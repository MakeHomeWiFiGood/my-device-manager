# My Device Manager

An early LuCI package for OpenWrt 25.12.x. Current scope: device discovery, a persistent MAC-keyed friendly-name registry, and integration with standard OpenWrt DHCP static reservations.

## Install from a script

This project now provides a direct installer, so building an APK with the OpenWrt SDK is not required. Run the following commands in an SSH session as `root` on the router:

```sh
wget -O /tmp/mdm-install.sh https://raw.githubusercontent.com/MakeHomeWiFiGood/my-device-manager/main/install.sh
sh /tmp/mdm-install.sh install
```

The installer downloads the source bundle over HTTPS, checks the archive structure, backs up files it replaces, preserves an existing `/etc/config/my_device_manager`, and restarts `rpcd`. It requires LuCI and access to `raw.githubusercontent.com`.

To remove the app and restore files that existed before installation, run:

```sh
sh /tmp/mdm-install.sh uninstall
```

Keep `/tmp/mdm-install.sh` until you're sure you no longer need the uninstaller; files in `/tmp` do not survive a reboot. The installer's backup/manifest is kept under `/root/.my-device-manager` until uninstall.

## Current limitations

Wi-Fi band enforcement and per-device speed enforcement are not implemented yet. This project does not configure or bypass mwan3, Tachyon, proxy routing, or existing firewall rules.

See STATUS.md for current implementation status.
