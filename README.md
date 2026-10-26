# My Device Manager

An early LuCI application for OpenWrt 25.12.x. It discovers LAN/Wi-Fi clients, keeps a persistent MAC-keyed registry, integrates with ordinary OpenWrt DHCP reservations, and shows available device fingerprints and Wi-Fi link statistics.

## Device names and information

For unregistered clients, the interface uses a readable name announced by an mDNS service (for example, Google Cast or Android TV Remote), then an mDNS hostname, then the hostname from the current DHCP lease. If UFP is already installed and running, the list can additionally show its detected model/device and vendor fingerprint. A MAC vendor may identify a network module rather than the consumer device brand, so it is displayed as separate metadata instead of being treated as the device name. Devices that have not been registered in My Device Manager are explicitly marked **“Устройство не зарегистрировано”**.

For associated Wi-Fi clients, the app can display the radio/band, channel, signal level, Wi-Fi standard, RX/TX link rates and current association byte counters from hostapd. The counters may reset after a client reconnects.

## Two-level registration

- **«Зарегистрировать»** adds the device to My Device Manager only. It does not create or modify a static DHCP lease; the app's device settings and Wi-Fi band selector become available immediately.
- **«Зарегистрировать DHCP-запись»** is a separate action for an app-registered device with an IPv4 address when a static reservation is not detected. It validates the MAC and IP, refuses conflicts with existing static DHCP reservations, then creates a standard OpenWrt `dhcp host` entry and reloads dnsmasq. If applying the change fails, the previous DHCP configuration is restored where possible.
- Local registration intentionally skips the strict MAC-format validator after normalizing letter case and common separators. For manual registration, enter the device's actual MAC because the registry and Wi-Fi controls use it as the key. The separate DHCP step still validates MAC and IPv4 and checks reservation conflicts. The **«DHCP Регистрация»** button appears only for registered devices with an IP and is hidden when a static DHCP reservation is already detected.

## Per-device Wi-Fi band selection

Registered devices have a selector with three modes:

- **2,4 + 5 ГГц — выбор клиента (без ограничений MDM):** MDM removes the deny-list entries it created for that device. The client chooses its band as usual. Existing manually configured Wi-Fi ACLs remain in force.
- **Только 2,4 ГГц:** MDM adds that device's MAC address to deny-lists for active APs on other bands.
- **Только 5 ГГц:** MDM adds the device's MAC address to deny-lists for active APs on other bands.

Applying a restriction updates the relevant `wireless` UCI settings and can briefly reload Wi-Fi, interrupting clients. Before applying a restriction, MDM checks that each denied-band AP has an AP on the permitted band with the same SSID, encryption mode and key, so the client has a compatible network to rejoin. If that check fails, or if the existing Wi-Fi ACL uses an allow-list or a conflicting dormant MAC list, the operation is refused instead of silently overwriting the policy. MDM tracks the entries and filter settings it creates; switching back to both bands, unregistering a device, or uninstalling the app removes only MDM-owned restrictions where they are still identifiable.

Register the device's current Wi-Fi MAC address. If a client uses MAC randomization and changes its address, it may need to be registered again. Before registration, MAC input is normalized to a canonical lowercase colon-separated value; common colon, hyphen, dotted, compact, upper/lowercase and whitespace variants are accepted. Band selection is a Wi-Fi admission restriction, not a guarantee that a client will prefer a particular band while both are enabled.

## Install or update

Run these commands in an SSH session as `root` on the router:

```sh
wget -O /root/mdm-install.sh https://github.com/MakeHomeWiFiGood/my-device-manager/releases/download/v0.2.18/install.sh
sh /root/mdm-install.sh check
sh /root/mdm-install.sh install
```

The installer supports BusyBox `tar` on OpenWrt. It validates the source archive, patches the RPC backend and LuCI view for mDNS discovery, optional UFP fingerprints, Wi-Fi telemetry, band selection and the unregistered-device marker; explicitly sets executable permissions on the RPC handler; and backs up files it replaces. An existing `/etc/config/my_device_manager` is preserved. mDNS is optional and the installer does not install or enable it. UFP is also optional and is not installed by this app installer. Access to `raw.githubusercontent.com` is required.

To remove the app and restore files that existed before installation:

```sh
sh /root/mdm-install.sh uninstall
```

Keep `/root/mdm-install.sh` until you're sure you no longer need the uninstaller. Installer state and backups are kept under `/root/.my-device-manager`; the uninstaller intentionally leaves those backups on disk.

## Current limitations

The exact consumer model may not be detectable, especially when a device uses a randomized MAC address. Wi-Fi telemetry is a snapshot of the current hostapd station view rather than lifetime usage. Per-device speed enforcement is not implemented. My Device Manager does not change firewall rules, `tc`, mwan3, Tachyon, proxy routing, or other firewall policies. CI checks the installer and source bundle but does not perform a live installation on the target router.

See `STATUS.md` for current implementation status.
