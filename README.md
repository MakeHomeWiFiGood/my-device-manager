# My Device Manager

An early LuCI application for OpenWrt 25.12.x. Current scope: device discovery, a persistent MAC-keyed friendly-name registry, and integration with standard OpenWrt DHCP static reservations.

For unregistered clients, the interface first uses a readable name announced by an mDNS service (for example, Google Cast's friendly name or an Android TV Remote service name), then an mDNS hostname, then the hostname from the current DHCP lease. Static DHCP reservation names are not allowed to overwrite a hostname reported by the device. If no useful name is available, the interface displays “Неизвестное устройство” instead of inventing a label from the Wi-Fi band and MAC suffix. Discovered names are read-only and are not written to DHCP, UCI, or the device hostname.

## Install or update from a script

Run these commands in an SSH session as `root` on the router:

```sh
wget -O /root/mdm-install.sh https://github.com/MakeHomeWiFiGood/my-device-manager/releases/download/v0.2.5/install.sh
sh /root/mdm-install.sh check
sh /root/mdm-install.sh install
```

The installer supports BusyBox `tar` on OpenWrt. It validates the source archive, safely patches the RPC backend and LuCI view to merge mDNS service names/hostnames by IPv4 address, preserves DHCP-hostname precedence over static reservation labels, backs up replaced files, preserves an existing `/etc/config/my_device_manager`, and restarts `rpcd`. mDNS discovery is optional and uses `umdns` only when that service is installed and running; the installer does not install it or change its startup settings. The installer requires LuCI and access to `raw.githubusercontent.com`.

To remove the app and restore files that existed before installation, run:

```sh
sh /root/mdm-install.sh uninstall
```

Keep `/root/mdm-install.sh` until you're sure you no longer need the uninstaller. Installer state and backups are kept under `/root/.my-device-manager`; the uninstaller intentionally leaves those backups on disk.

## Current limitations

A device name is shown only when it is available from mDNS or DHCP; routers cannot infer an exact self-reported name from a MAC address alone. Wi-Fi band enforcement and per-device speed enforcement are not implemented yet. This project does not configure or bypass mwan3, Tachyon, proxy routing, or existing firewall rules. CI checks the installer and source bundle but does not perform a live installation on the router.

See `STATUS.md` for current implementation status.
