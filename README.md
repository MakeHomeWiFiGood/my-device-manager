# My Device Manager

An early LuCI application for OpenWrt 25.12.x. Current scope: device discovery, a persistent MAC-keyed friendly-name registry, and integration with standard OpenWrt DHCP static reservations.

For unregistered clients, the interface first uses a readable name announced by an mDNS service (for example, Google Cast's friendly name or an Android TV Remote service name), then an mDNS hostname, then the hostname from the current DHCP lease. If UFP is installed and running, the list can additionally show its detected device/model and vendor fingerprint. The vendor may identify a network module or MAC OUI rather than the consumer device brand; it is displayed as separate metadata, not treated as the announced device name. Static DHCP reservation names are not allowed to overwrite a hostname reported by the device. If no useful name is available, the interface displays “Неизвестное устройство” instead of inventing a label from the Wi-Fi band and MAC suffix. Discovered names and fingerprint metadata are read-only and are not written to DHCP, UCI, or the device hostname.

## Install or update from a script

Run these commands in an SSH session as `root` on the router:

```sh
wget -O /root/mdm-install.sh https://github.com/MakeHomeWiFiGood/my-device-manager/releases/download/v0.2.9/install.sh
sh /root/mdm-install.sh check
sh /root/mdm-install.sh install
```

The installer supports BusyBox `tar` on OpenWrt. It validates the source archive, safely patches the RPC backend and LuCI view to merge mDNS service names/hostnames by IPv4 address, parses `umdns browse` regardless of JSON indentation, explicitly sets executable permissions on the RPC handler so `rpcd` can register it, preserves DHCP-hostname precedence over static reservation labels, backs up replaced files, preserves an existing `/etc/config/my_device_manager`, and restarts `rpcd`. mDNS discovery is optional and uses `umdns` only when that service is installed and running; the installer does not install it or change its startup settings. The installer requires LuCI and access to `raw.githubusercontent.com`.

To remove the app and restore files that existed before installation, run:

```sh
sh /root/mdm-install.sh uninstall
```

Keep `/root/mdm-install.sh` until you're sure you no longer need the uninstaller. Installer state and backups are kept under `/root/.my-device-manager`; the uninstaller intentionally leaves those backups on disk.

## Current limitations

A device's exact self-reported name is shown only when available from mDNS or DHCP. UFP may provide a model or MAC vendor, but it cannot guarantee the exact consumer device model, especially when the device uses a randomized MAC and does not expose other fingerprintable data. Wi-Fi band enforcement and per-device speed enforcement are not implemented yet. This project does not configure or bypass mwan3, Tachyon, proxy routing, or existing firewall rules. CI checks the installer and source bundle but does not perform a live installation on the router.

See `STATUS.md` for current implementation status.
