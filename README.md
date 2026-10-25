# My Device Manager

An early LuCI application for OpenWrt 25.12.x. Current scope: device discovery, a persistent MAC-keyed friendly-name registry, and integration with standard OpenWrt DHCP static reservations.

For an unregistered client, the interface prefers the hostname the device actually announces in its current DHCP lease. That value takes precedence over a static DHCP reservation name. Only when no useful hostname is reported does the interface show a local fallback based on connection type and MAC suffix. This fallback stays inside LuCI and is not written to the device, DHCP, UCI, or hostname configuration.

## Install or update from a script

Run these commands in an SSH session as `root` on the router:

```sh
wget -O /root/mdm-install.sh https://github.com/MakeHomeWiFiGood/my-device-manager/releases/download/v0.2.4/install.sh
sh /root/mdm-install.sh check
sh /root/mdm-install.sh install
```

The installer supports BusyBox `tar` on OpenWrt. It validates the source archive, applies a guarded fix to ensure the device-reported DHCP hostname wins over a static DHCP label, backs up files it replaces, preserves an existing `/etc/config/my_device_manager`, and restarts `rpcd`. It requires LuCI and access to `raw.githubusercontent.com`.

To remove the app and restore files that existed before installation, run:

```sh
sh /root/mdm-install.sh uninstall
```

Keep `/root/mdm-install.sh` until you're sure you no longer need the uninstaller. Installer state and backups are kept under `/root/.my-device-manager`; the uninstaller intentionally leaves those backups on disk.

## Current limitations

If a device does not announce a hostname in DHCP, the router cannot infer that exact self-reported name from the lease alone; the interface uses a local fallback. Wi-Fi band enforcement and per-device speed enforcement are not implemented yet. This project does not configure or bypass mwan3, Tachyon, proxy routing, or existing firewall rules. CI checks the installer and source bundle but does not perform a live installation on the router.

See `STATUS.md` for current implementation status.
