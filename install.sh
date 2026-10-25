#!/bin/sh
# My Device Manager bootstrap installer for OpenWrt 25.12.x.
# Installs the existing LuCI source payload directly; no SDK or APK required.
set -eu

APP_NAME="My Device Manager"
# Pin the source bundle to an immutable commit so the installer never silently
# mixes its script with a changing set of source chunks.
SOURCE_REF="269211b675fd174053284591af1ec59e68cb2de0"
SOURCE_BASE="https://raw.githubusercontent.com/MakeHomeWiFiGood/my-device-manager/${SOURCE_REF}"
STATE_DIR="/root/.my-device-manager"
BACKUP_DIR="${STATE_DIR}/backup"

log() { printf '%s\n' "[My Device Manager] $*"; }
die() { log "ERROR: $*" >&2; exit 1; }

require_root() {
    [ "$(id -u)" -eq 0 ] || die "Запусти скрипт от root."
}

restart_services() {
    if [ -x /etc/init.d/rpcd ]; then
        /etc/init.d/rpcd restart || log "Предупреждение: rpcd не удалось перезапустить автоматически."
    fi
    # uhttpd serves files from disk; no restart is normally required.
}

has_line() {
    grep -Fqx "$1" "$2" 2>/dev/null
}

install_tree() {
    source_dir="$1"
    target_root="$2"
    [ -d "$source_dir" ] || return 0

    find "$source_dir" -type f -print | while IFS= read -r source_file; do
        relative_path="${source_file#"${source_dir}"/}"
        target_file="${target_root%/}/${relative_path}"

        # Keep an existing UCI config: reinstalling the package must not erase
        # settings the user has already created.
        case "$target_file" in
            /etc/config/my_device_manager)
                if [ -e "$target_file" ]; then
                    log "Сохраняю существующую конфигурацию: $target_file"
                    continue
                fi
                ;;
        esac

        mkdir -p "$(dirname "$target_file")"

        # Record the original state only once so a second install/update does
        # not replace the first backup with the previous app version.
        if [ -e "$target_file" ] || [ -L "$target_file" ]; then
            if ! has_line "$target_file" "${STATE_DIR}/original-files" &&
               ! has_line "$target_file" "${STATE_DIR}/new-files"; then
                backup_file="${BACKUP_DIR}${target_file}"
                mkdir -p "$(dirname "$backup_file")"
                cp -a "$target_file" "$backup_file"
                printf '%s\n' "$target_file" >> "${STATE_DIR}/original-files"
            fi
        else
            if ! has_line "$target_file" "${STATE_DIR}/original-files" &&
               ! has_line "$target_file" "${STATE_DIR}/new-files"; then
                printf '%s\n' "$target_file" >> "${STATE_DIR}/new-files"
            fi
        fi

        cp -a "$source_file" "$target_file"
    done
}

download_source() {
    command -v wget >/dev/null 2>&1 || die "Не найден wget."
    command -v base64 >/dev/null 2>&1 || die "Не найден base64."
    command -v tar >/dev/null 2>&1 || die "Не найден tar."
    command -v gzip >/dev/null 2>&1 || die "Не найден gzip."

    tmp_dir="$(mktemp -d /tmp/my-device-manager.XXXXXX)"
    trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM
    mkdir -p "$tmp_dir/source"

    log "Загружаю исходные файлы..."
    for part in 01 02 03 04 05 06 07 08 09; do
        wget -q -O "$tmp_dir/bundle.part${part}" "${SOURCE_BASE}/source/bundle.part${part}" ||
            die "Не удалось загрузить исходник bundle.part${part}. Проверь доступ к raw.githubusercontent.com."
    done

    cat "$tmp_dir"/bundle.part* > "$tmp_dir/source.tar.gz.b64"
    base64 -d "$tmp_dir/source.tar.gz.b64" > "$tmp_dir/source.tar.gz" ||
        die "Не удалось декодировать архив исходников."
    gzip -t "$tmp_dir/source.tar.gz" || die "Архив исходников повреждён."

    # BusyBox tar on OpenWrt does not implement GNU tar's --strip-components.
    # Validate archive paths, extract into a private temporary directory, then
    # locate the expected application directory regardless of the archive prefix.
    tar -tzf "$tmp_dir/source.tar.gz" > "$tmp_dir/archive.list" ||
        die "Не удалось прочитать список файлов в архиве."
    while IFS= read -r archive_entry; do
        case "$archive_entry" in
            /*|..|../*|*/../*|*/..)
                die "Небезопасный путь в архиве: $archive_entry"
                ;;
        esac
    done < "$tmp_dir/archive.list"

    tar -xzf "$tmp_dir/source.tar.gz" -C "$tmp_dir/source" ||
        die "Не удалось распаковать архив исходников."
    find "$tmp_dir/source" -type d -name luci-app-my-device-manager -print > "$tmp_dir/package-dir.list"
    [ -s "$tmp_dir/package-dir.list" ] || die "В архиве отсутствует каталог приложения."
    [ "$(wc -l < "$tmp_dir/package-dir.list" | tr -d ' ')" = "1" ] ||
        die "В архиве найдено несколько каталогов приложения; отказываюсь продолжать."
    package_dir="$(cat "$tmp_dir/package-dir.list")"
}

apply_device_hostname_precedence_fix() {
    local backend_file fixed_line legacy_count

    backend_file="$package_dir/root/usr/libexec/rpcd/luci.my_device_manager"
    [ -f "$backend_file" ] || die "Не найден обработчик списка устройств."

    fixed_line='if ($4 != "" && host[m] == "") host[m]=$4;'
    if grep -Fq "$fixed_line" "$backend_file"; then
        :
    else
        legacy_count=$(grep -Fc 'if ($4 != "") host[m]=$4;' "$backend_file" || true)
        [ "$legacy_count" = "1" ] ||
            die "Не удалось безопасно определить участок, отвечающий за имя устройства."
        sed 's/if (\$4 != "") host\[m\]=\$4;/if ($4 != "" \&\& host[m] == "") host[m]=$4;/' \
            "$backend_file" > "$tmp_dir/backend.patched" ||
            die "Не удалось исправить приоритет имени устройства."
        grep -Fq "$fixed_line" "$tmp_dir/backend.patched" ||
            die "Проверка исправления имени устройства не пройдена."
        mv "$tmp_dir/backend.patched" "$backend_file" ||
            die "Не удалось сохранить исправление имени устройства."
    fi

    sh -n "$backend_file" || die "RPCD-обработчик не прошёл проверку shell-синтаксиса."
}



apply_mac_validation_patch() {
    local backend_file mac_patch test_file

    backend_file="$package_dir/root/usr/libexec/rpcd/luci.my_device_manager"
    [ -f "$backend_file" ] || die "Не найден RPC-обработчик для исправления проверки MAC-адреса."

    if ! grep -Fq '# MDM_MAC_VALIDATOR_V3' "$backend_file"; then
        [ "$(grep -Fc 'mac_valid() {' "$backend_file" || true)" = "1" ] ||
            die "Не удалось однозначно найти общую проверку MAC-адреса."

        mac_patch="$tmp_dir/mac-validation.awk"
        cat > "$mac_patch" <<'MDM_MAC_VALIDATION'
function print_mac_validator() {
    print "mac_valid() {"
    print "    # MDM_MAC_VALIDATOR_V3: shell-only MAC shape and hex validation for BusyBox."
    print "    local candidate"
    print "    candidate=$(printf '%s' \"$1\" | tr 'ABCDEF' 'abcdef' | sed 's/-/:/g')"
    print "    case \"$candidate\" in"
    print "        ??:??:??:??:??:??) ;;"
    print "        *) return 1 ;;"
    print "    esac"
    print "    case \"$candidate\" in"
    print "        *[!0123456789abcdef:]*) return 1 ;;"
    print "    esac"
    print "    return 0"
    print "}"
}
$0 == "mac_valid() {" && !replaced {
    print_mac_validator()
    in_function = 1
    replaced = 1
    next
}
in_function {
    if ($0 ~ /^[[:space:]]*}[[:space:]]*$/) in_function = 0
    next
}
{ print }
END { if (!replaced || in_function) exit 1 }
MDM_MAC_VALIDATION

        awk -f "$mac_patch" "$backend_file" > "$tmp_dir/backend.mac" ||
            die "Не удалось заменить общую проверку MAC-адреса."
        grep -Fq '# MDM_MAC_VALIDATOR_V3' "$tmp_dir/backend.mac" ||
            die "Исправление проверки MAC-адреса не обнаружено."
        sh -n "$tmp_dir/backend.mac" ||
            die "RPC-обработчик после исправления проверки MAC не прошёл проверку shell-синтаксиса."
        mv "$tmp_dir/backend.mac" "$backend_file" ||
            die "Не удалось сохранить исправление проверки MAC-адреса."
    fi

    test_file="$tmp_dir/mac-validator-test.sh"
    sed -n '/^mac_valid() {/,/^}/p' "$backend_file" > "$test_file"
    grep -Fq '# MDM_MAC_VALIDATOR_V3' "$test_file" ||
        die "Не удалось подготовить тест общей проверки MAC-адреса."
    (
        . "$test_file"
        mac_valid 'aa:bb:cc:dd:ee:ff' || exit 1
        mac_valid 'AA:BB:CC:DD:EE:FF' || exit 1
        mac_valid 'aa-bb-cc-dd-ee-ff' || exit 1
        mac_valid 'e8:88:43:6f:fb:e3' || exit 1
        if mac_valid 'aa:bb:cc:dd:ee:gg'; then exit 1; fi
        if mac_valid 'aa:bb:cc:dd:ee'; then exit 1; fi
        if mac_valid '0:bb:cc:dd:ee:ff'; then exit 1; fi
        if mac_valid 'aa:bb:cc:dd:ee:ffff'; then exit 1; fi
        if mac_valid ''; then exit 1; fi
    ) || die "Проверка MAC-адреса не прошла тесты валидного и невалидного ввода."

    log "Проверка MAC-адреса прошла тесты стандартного формата и некорректного ввода."
}


apply_mdns_discovery_patch() {
    local backend_file js_file mdns_helper mdns_patch ui_patch insert_helper

    backend_file="$package_dir/root/usr/libexec/rpcd/luci.my_device_manager"
    js_file="$package_dir/htdocs/luci-static/resources/view/my-device-manager/main.js"
    [ -f "$backend_file" ] || die "Не найден RPC-обработчик для mDNS-обнаружения."
    [ -f "$js_file" ] || die "Не найден интерфейс My Device Manager."

    # mDNS support is optional; DHCP discovery continues to work unchanged
    # if umdns is missing or not running.
    if ! grep -Fq 'json_add_string discovered_name "$discovered_name"' "$backend_file"; then
        [ "$(grep -Fc '    # Standard OpenWrt static DHCP reservations: expose reserved IPs even while' "$backend_file" || true)" = "1" ] ||
            die "Не найден безопасный участок для добавления mDNS-имён."
        [ "$(grep -Fc '            if ($3 != "") ip[m]=$3;' "$backend_file" || true)" = "1" ] ||
            die "Не удалось определить обработку IP-адресов устройств."
        [ "$(grep -Fc '        $1 == "R" {' "$backend_file" || true)" = "1" ] ||
            die "Не найден участок объединения списка устройств."
        [ "$(grep -Fc 'mode[m];' "$backend_file" || true)" = "1" ] ||
            die "Не найден формат списка устройств для расширения."
        [ "$(grep -Fc 'dns_name dhcp_mode; do' "$backend_file" || true)" = "1" ] ||
            die "Не найден разбор списка устройств."
        [ "$(grep -Fc 'json_add_string hostname "$host"' "$backend_file" || true)" = "1" ] ||
            die "Не найдено поле hostname в RPC-ответе."
        [ "$(grep -Fc '    local raw merged section mac name band down up iface lease_ip dns_name dhcp_mode host_section' "$backend_file" || true)" = "1" ] ||
            die "Не найден список локальных переменных RPC-обработчика."
        [ "$(grep -Fc '            for (i=1; i<=n; i++) {' "$backend_file" || true)" = "1" ] ||
            die "Не найден цикл формирования итогового списка устройств."

        mdns_helper="$tmp_dir/mdns-helper.sh"
        mdns_patch="$tmp_dir/mdns-backend.awk"
        if grep -Fq 'append_mdns_records() {' "$backend_file"; then
            insert_helper=0
        else
            insert_helper=1
            [ "$(grep -Fc 'list_devices() {' "$backend_file" || true)" = "1" ] ||
                die "Не найдено место для mDNS-помощника."
        fi

        cat > "$mdns_helper" <<'MDM_MDNS_HELPER'
append_mdns_records() {
    local output_file="$1" mdns_hosts_json mdns_services_json mdns_host_keys mdns_host_key mdns_host_ip mdns_label

    [ -n "$output_file" ] || return 0
    command -v ubus >/dev/null 2>&1 || return 0
    ubus -v list umdns >/dev/null 2>&1 || return 0

    # Refresh cached discovery, but do not alter service configuration or
    # enable autostart. Discovered information is only a read-only name source.
    ubus call umdns update >/dev/null 2>&1 || true
    sleep 1

    mdns_hosts_json=$(ubus call umdns hosts 2>/dev/null)
    if [ -n "$mdns_hosts_json" ] && json_load "$mdns_hosts_json" 2>/dev/null; then
        json_get_keys mdns_host_keys
        for mdns_host_key in $mdns_host_keys; do
            [ -n "$mdns_host_key" ] || continue
            # Skip UUID/hash-like hostnames which are not useful display names.
            case "$mdns_host_key" in
                ????????-????-????-????-????????????.local|Android_fdd????????????????????????????????.local)
                    continue ;;
            esac
            if ! json_select "$mdns_host_key" 2>/dev/null; then
                continue
            fi
            mdns_host_ip=""
            json_get_var mdns_host_ip ipv4
            json_select ..
            if ipv4_valid "$mdns_host_ip"; then
                mdns_label=${mdns_host_key%.local}
                mdns_label=$(name_clean "$mdns_label")
                case "$mdns_label" in
                    ''|localhost|unknown|Unknown) continue ;;
                esac
                printf 'H|%s|%s\n' "$mdns_host_ip" "$mdns_label" >> "$output_file"
            fi
        done
    fi

    mdns_services_json=$(ubus call umdns browse '{"array":true,"address":true}' 2>/dev/null)
    [ -n "$mdns_services_json" ] || return 0

    # Prefer human-facing service labels over generic hostnames:
    # Google Cast fn=, Android TV Remote, AirPlay, and similar names.
    printf '%s\n' "$mdns_services_json" | awk '
        function indent_level(line, prefix) {
            prefix = line
            sub(/[^ \t].*$/, "", prefix)
            gsub(/\t/, "    ", prefix)
            return length(prefix)
        }
        function flush_record(    label, priority, n, i, address) {
            if (instance == "") return
            label = ""
            priority = 0
            if (service == "_googlecast._tcp") {
                if (fn != "") { label = fn; priority = 100 }
            } else if (service == "_androidtvremote2._tcp") {
                label = instance; priority = 90
            } else if (service == "_airplay._tcp" ||
                       service == "_raop._tcp" ||
                       service == "_companion-link._tcp") {
                label = instance; priority = 80
            }
            if (label != "") {
                gsub(/[|\t\r\n]/, " ", label)
                n = split(ips, addresses, " ")
                for (i = 1; i <= n; i++) {
                    address = addresses[i]
                    if (address ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/)
                        printf "S|%s|%s|%d\n", address, label, priority
                }
            }
        }
        BEGIN {
            service = ""; instance = ""; fn = ""; ips = ""
            in_ipv4 = 0; service_indent = -1; record_indent = -1
        }
        {
            current_indent = indent_level($0)

            # Do not assume a fixed number of spaces: ubus JSON indentation
            # varies between builds and may use tabs.
            if ($0 ~ /^[[:space:]]*"_([^"]+\._tcp)"[[:space:]]*:[[:space:]]*\{/) {
                flush_record()
                service = $0
                sub(/^[[:space:]]*"/, "", service)
                sub(/".*$/, "", service)
                instance = ""; fn = ""; ips = ""; in_ipv4 = 0
                service_indent = current_indent
                record_indent = -1
                next
            }

            if (service != "" &&
                $0 ~ /^[[:space:]]*"[^"]*"[[:space:]]*:[[:space:]]*\{[[:space:]]*$/ &&
                current_indent > service_indent &&
                (record_indent < 0 || current_indent == record_indent)) {
                flush_record()
                instance = $0
                sub(/^[[:space:]]*"/, "", instance)
                sub(/"[[:space:]]*:[[:space:]]*\{[[:space:]]*$/, "", instance)
                if (record_indent < 0) record_indent = current_indent
                fn = ""; ips = ""; in_ipv4 = 0
                next
            }

            if (instance != "") {
                if ($0 ~ /"fn=/) {
                    fn = $0
                    sub(/^.*"fn=/, "", fn)
                    sub(/".*$/, "", fn)
                }
                if ($0 ~ /"ipv4"[[:space:]]*:[[:space:]]*\[/) {
                    in_ipv4 = 1
                    next
                }
                if (in_ipv4) {
                    if ($0 ~ /\]/) { in_ipv4 = 0; next }
                    if ($0 ~ /"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+"/) {
                        address = $0
                        sub(/^[[:space:]]*"/, "", address)
                        sub(/".*$/, "", address)
                        ips = ips (ips == "" ? "" : " ") address
                    }
                }
            }

            if ($0 ~ /^[[:space:]]*\}[,]?[[:space:]]*$/) {
                if (instance != "" && current_indent == record_indent) {
                    flush_record()
                    instance = ""; fn = ""; ips = ""; in_ipv4 = 0
                }
                if (service != "" && current_indent == service_indent) {
                    flush_record()
                    service = ""; instance = ""; fn = ""; ips = ""
                    in_ipv4 = 0; service_indent = -1; record_indent = -1
                }
            }
        }
        END { flush_record() }
    ' >> "$output_file"
}
MDM_MDNS_HELPER

        cat > "$mdns_patch" <<'MDM_MDNS_PATCH'
{
    if ($0 == "list_devices() {" && insert_helper == 1) {
        while ((getline helper_line < helper_file) > 0)
            print helper_line
        close(helper_file)
    }

    if ($0 == "    local raw merged section mac name band down up iface lease_ip dns_name dhcp_mode host_section")
        $0 = "    local raw merged section mac name band down up iface lease_ip dns_name dhcp_mode host_section discovered_name"

    if ($0 == "    # Standard OpenWrt static DHCP reservations: expose reserved IPs even while")
        print "    append_mdns_records \"$raw\""

    # Keep IPv6 neighbor records from overriding the IPv4 key used for mDNS joins.
    if ($0 == "            if ($3 != \"\") ip[m]=$3;")
        $0 = "            if ($3 ~ /^[0-9]+[.][0-9]+[.][0-9]+[.][0-9]+$/) ip[m]=$3;"

    if ($0 == "        $1 == \"R\" {") {
        print "        $1 == \"H\" {"
        print "            ip_key=$2"
        print "            if (ip_key ~ /^[0-9]+[.][0-9]+[.][0-9]+[.][0-9]+$/ && $3 != \"\" && mdns_hostname[ip_key] == \"\")"
        print "                mdns_hostname[ip_key]=$3"
        print "        }"
        print "        $1 == \"S\" {"
        print "            ip_key=$2"
        print "            priority=$4+0"
        print "            if (ip_key ~ /^[0-9]+[.][0-9]+[.][0-9]+[.][0-9]+$/ && $3 != \"\" && priority > service_priority[ip_key]) {"
        print "                service_label[ip_key]=$3"
        print "                service_priority[ip_key]=priority"
        print "            }"
        print "        }"
        print $0
        next
    }

    if ($0 == "            for (i=1; i<=n; i++) {") {
        print "            for (i=1; i<=n; i++) {"
        print "                m=order[i];"
        print "                if (online[m] == 1 && ip[m] ~ /^[0-9]+[.][0-9]+[.][0-9]+[.][0-9]+$/) {"
        print "                    key=ip[m] SUBSEP m;"
        print "                    if (!ip_mac_seen[key]++) ip_mac_count[ip[m]]++;"
        print "                }"
        print "            }"
        print ""
        print $0
        next
    }

    if (index($0, "mode[m];") > 0 && index($0, "printf") > 0) {
        print "                preferred=\"\";"
        print "                if (online[m] == 1 && ip[m] ~ /^[0-9]+[.][0-9]+[.][0-9]+[.][0-9]+$/ && ip_mac_count[ip[m]] == 1) {"
        print "                    preferred=service_label[ip[m]];"
        print "                    if (preferred == \"\") preferred=mdns_hostname[ip[m]];"
        print "                }"
        print "                printf \"%s|%s|%s|%s|%d|%d|%s|%s|%s|%s|%s|%s|%s\\n\", m, ip[m], host[m], iface[m], online[m]+0, registered[m]+0, name[m], band[m], down[m], up[m], dns[m], mode[m], preferred;"
        next
    }

    if (index($0, "dns_name dhcp_mode; do") > 0)
        sub(/dns_name dhcp_mode; do/, "dns_name dhcp_mode discovered_name; do")

    if (index($0, "json_add_string hostname \"$host\"") > 0) {
        print
        print "        json_add_string discovered_name \"$discovered_name\""
        next
    }

    print
}
MDM_MDNS_PATCH

        awk -v helper_file="$mdns_helper" -v insert_helper="$insert_helper" -f "$mdns_patch" "$backend_file" > "$tmp_dir/backend.mdns" ||
            die "Не удалось добавить mDNS-обнаружение в RPC-обработчик."
        grep -Fq 'append_mdns_records "$raw"' "$tmp_dir/backend.mdns" ||
            die "Не удалось подключить mDNS-обнаружение к списку устройств."
        grep -Fq 'mdns_hostname[ip_key]' "$tmp_dir/backend.mdns" ||
            die "Не удалось добавить обработку mDNS-имён хостов."
        grep -Fq 'service_label[ip_key]' "$tmp_dir/backend.mdns" ||
            die "Не удалось добавить обработку читаемых имён mDNS-служб."
        grep -Fq 'json_add_string discovered_name "$discovered_name"' "$tmp_dir/backend.mdns" ||
            die "Не удалось добавить discovered_name в RPC-ответ."
        sh -n "$tmp_dir/backend.mdns" ||
            die "RPC-обработчик с mDNS не прошёл проверку shell-синтаксиса."
        mv "$tmp_dir/backend.mdns" "$backend_file" ||
            die "Не удалось сохранить RPC-обработчик с mDNS."
    fi

    if ! grep -Fq 'return (d.discovered_name || "").trim()' "$js_file"; then
        [ "$(grep -Fc 'return usefulHostname(d) || localDeviceLabel(d);' "$js_file" || true)" = "1" ] ||
            die "Не найден участок выбора отображаемого имени в интерфейсе."
        [ "$(grep -Fc 'return !(d.name && d.name.trim()) && !usefulHostname(d);' "$js_file" || true)" = "1" ] ||
            die "Не найден участок определения неопознанных устройств."
        [ "$(grep -Fc 'var suggested = usefulHostname(d);' "$js_file" || true)" = "1" ] ||
            die "Не найдено поле предложенного имени для регистрации."
        [ "$(grep -Fc "var searchable = [name, d.hostname, d.mac, d.ip].join(' ').toLocaleLowerCase();" "$js_file" || true)" = "1" ] ||
            die "Не найдено поле поиска устройств."
        [ "$(grep -Fc 'У устройств без имени автоматически формируется подпись по типу подключения' "$js_file" || true)" = "1" ] ||
            die "Не найдено пояснение к автоматическим именам."

        ui_patch="$tmp_dir/mdns-ui.awk"
        cat > "$ui_patch" <<'MDM_MDNS_UI'
{
    if (index($0, "return !(d.name && d.name.trim()) && !usefulHostname(d);")) {
        prefix=$0
        sub(/return.*/, "", prefix)
        $0=prefix "return !(d.name && d.name.trim()) && !((d.discovered_name || \"\").trim()) && !usefulHostname(d);"
    }

    if (index($0, "return usefulHostname(d) || localDeviceLabel(d);")) {
        prefix=$0
        sub(/return.*/, "", prefix)
        $0=prefix "return (d.discovered_name || \"\").trim() || usefulHostname(d) || 'Неизвестное устройство';"
    }

    if (index($0, "var suggested = usefulHostname(d);")) {
        prefix=$0
        sub(/var suggested.*/, "", prefix)
        $0=prefix "var suggested = (d.discovered_name || \"\").trim() || usefulHostname(d);"
    }

    if (index($0, "var searchable = [name, d.hostname, d.mac, d.ip].join")) {
        prefix=$0
        sub(/var searchable.*/, "", prefix)
        $0=prefix "var searchable = [name, d.discovered_name, d.hostname, d.mac, d.ip].join(' ').toLocaleLowerCase();"
    }

    if (index($0, "function isLocalAutoLabel(d)"))
        sub(/isLocalAutoLabel/, "isUnidentifiedDevice")

    if (index($0, "isLocalAutoLabel(d) ?")) {
        sub(/isLocalAutoLabel/, "isUnidentifiedDevice")
        sub(/Автоимя · только в приложении/, "Имя не обнаружено в DHCP/mDNS")
    }

    if (index($0, "У устройств без имени автоматически формируется подпись по типу подключения и окончанию MAC-адреса.")) {
        sub(/У устройств без имени автоматически формируется подпись по типу подключения и окончанию MAC-адреса\. Это имя существует только в этом интерфейсе и не записывается в DHCP, hostname или системную конфигурацию\./,
            "Сначала используются читаемые имена mDNS-служб, затем имя хоста из mDNS и hostname из DHCP. Если имя не найдено, отображается «Неизвестное устройство». Обнаруженные имена не записываются автоматически в системную конфигурацию.")
    }
    print
}
MDM_MDNS_UI

        awk -f "$ui_patch" "$js_file" > "$tmp_dir/main.mdns.js" ||
            die "Не удалось обновить выбор имени в интерфейсе."
        grep -Fq 'return (d.discovered_name || "").trim()' "$tmp_dir/main.mdns.js" ||
            die "Проверка выбора имени из mDNS не пройдена."
        grep -Fq 'Имя не обнаружено в DHCP/mDNS' "$tmp_dir/main.mdns.js" ||
            die "Проверка подписи для неопознанных устройств не пройдена."
        grep -Fq 'var suggested = (d.discovered_name || "").trim() || usefulHostname(d);' "$tmp_dir/main.mdns.js" ||
            die "Не удалось использовать найденное имя в форме регистрации."
        mv "$tmp_dir/main.mdns.js" "$js_file" ||
            die "Не удалось сохранить интерфейс с поддержкой mDNS."
    fi

    # rpcd discovers executable handlers under /usr/libexec/rpcd. Some source
    # bundles store this script as 0644, and cp -a would preserve that mode.
    chmod 0755 "$backend_file" ||
        die "Не удалось выставить исполняемые права RPC-обработчика."
    [ -x "$backend_file" ] ||
        die "RPC-обработчик остался без права на исполнение."
}


apply_ufp_fingerprint_patch() {
    local backend_file js_file ufp_helper backend_patch ui_patch

    backend_file="$package_dir/root/usr/libexec/rpcd/luci.my_device_manager"
    js_file="$package_dir/htdocs/luci-static/resources/view/my-device-manager/main.js"
    [ -f "$backend_file" ] || die "Не найден RPC-обработчик для интеграции UFP."
    [ -f "$js_file" ] || die "Не найден интерфейс для интеграции UFP."

    if ! grep -Fq 'json_add_string fingerprint_device "$fingerprint_device"' "$backend_file"; then
        [ "$(grep -Fc 'list_devices() {' "$backend_file" || true)" = "1" ] ||
            die "Не найдено место для UFP-помощника."
        [ "$(grep -Fc '    append_mdns_records "$raw"' "$backend_file" || true)" = "1" ] ||
            die "Не найден вызов mDNS-помощника для подключения UFP."
        [ "$(grep -Fc '        $1 == "H" {' "$backend_file" || true)" = "1" ] ||
            die "Не найден парсер записей обнаружения для UFP."
        [ "$(grep -Fc 'preferred;' "$backend_file" || true)" = "1" ] ||
            die "Не найдено место формирования ответа со сведениями UFP."
        [ "$(grep -Fc 'dns_name dhcp_mode discovered_name; do' "$backend_file" || true)" = "1" ] ||
            die "Не найден разбор строки RPC-ответа для UFP."
        [ "$(grep -Fc 'json_add_string discovered_name "$discovered_name"' "$backend_file" || true)" = "1" ] ||
            die "Не найдено поле discovered_name для расширения ответа."

        ufp_helper="$tmp_dir/ufp-helper.sh"
        backend_patch="$tmp_dir/ufp-backend.awk"
        cat > "$ufp_helper" <<'MDM_UFP_HELPER'
append_ufp_records() {
    local output_file="$1" fingerprint_json fingerprint_keys fingerprint_key fingerprint_mac fingerprint_vendor fingerprint_device fingerprint_device_name

    [ -n "$output_file" ] || return 0
    command -v ubus >/dev/null 2>&1 || return 0
    ubus -v list fingerprint >/dev/null 2>&1 || return 0

    # UFP is optional. Read its current classification without changing
    # daemon settings or writing anything back to DHCP/UCI.
    fingerprint_json=$(ubus call fingerprint fingerprint '{}' 2>/dev/null) || return 0
    [ -n "$fingerprint_json" ] || return 0
    json_load "$fingerprint_json" 2>/dev/null || return 0
    json_get_keys fingerprint_keys

    # jshn replaces punctuation in JSON object keys with underscores
    # when json_get_keys is used. Select using that normalized key, while
    # restoring the canonical colon-separated MAC for cross-source matching.
    for fingerprint_key in $fingerprint_keys; do
        case "$fingerprint_key" in
            [0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F])
                fingerprint_mac="$fingerprint_key" ;;
            [0-9a-fA-F][0-9a-fA-F]_[0-9a-fA-F][0-9a-fA-F]_[0-9a-fA-F][0-9a-fA-F]_[0-9a-fA-F][0-9a-fA-F]_[0-9a-fA-F][0-9a-fA-F]_[0-9a-fA-F][0-9a-fA-F])
                fingerprint_mac=$(printf '%s' "$fingerprint_key" | tr '_' ':') ;;
            *) continue ;;
        esac

        fingerprint_vendor=""
        fingerprint_device=""
        fingerprint_device_name=""
        json_select "$fingerprint_key" 2>/dev/null || continue
        json_get_var fingerprint_vendor vendor
        json_get_var fingerprint_device device
        json_get_var fingerprint_device_name device_name
        json_select ..

        # These fields are pipe-delimited in the internal temporary file.
        fingerprint_vendor=$(printf '%s' "$fingerprint_vendor" | tr -d '\r\n|')
        fingerprint_device=$(printf '%s' "$fingerprint_device" | tr -d '\r\n|')
        fingerprint_device_name=$(printf '%s' "$fingerprint_device_name" | tr -d '\r\n|')
        if [ -n "$fingerprint_vendor" ] || [ -n "$fingerprint_device" ] || [ -n "$fingerprint_device_name" ]; then
            printf 'U|%s|%s|%s|%s\n' "$fingerprint_mac" "$fingerprint_vendor" "$fingerprint_device" "$fingerprint_device_name" >> "$output_file"
        fi
    done
    json_cleanup
}
MDM_UFP_HELPER

        cat > "$backend_patch" <<'MDM_UFP_PATCH'
{
    if ($0 == "list_devices() {") {
        while ((getline helper_line < helper_file) > 0)
            print helper_line
        close(helper_file)
    }

    if ($0 == "    local raw merged section mac name band down up iface lease_ip dns_name dhcp_mode host_section discovered_name")
        $0 = "    local raw merged section mac name band down up iface lease_ip dns_name dhcp_mode host_section discovered_name fingerprint_vendor fingerprint_device fingerprint_device_name"

    if ($0 == "    append_mdns_records \"$raw\"") {
        print
        print "    append_ufp_records \"$raw\""
        next
    }

    if ($0 == "        $1 == \"H\" {") {
        print "        $1 == \"U\" {"
        print "            mac_key=tolower($2)"
        print "            if (mac_key ~ /^[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]/) {"
        print "                if ($3 != \"\") ufp_vendor[mac_key]=$3"
        print "                if ($4 != \"\") ufp_device[mac_key]=$4"
        print "                if ($5 != \"\") ufp_device_name[mac_key]=$5"
        print "            }"
        print "        }"
        print
        next
    }

    if (index($0, "preferred;") > 0 && index($0, "printf") > 0) {
        $0 = "                printf \"%s|%s|%s|%s|%d|%d|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\\n\", m, ip[m], host[m], iface[m], online[m]+0, registered[m]+0, name[m], band[m], down[m], up[m], dns[m], mode[m], preferred, ufp_vendor[tolower(m)], ufp_device[tolower(m)], ufp_device_name[tolower(m)];"
    }

    if (index($0, "dns_name dhcp_mode discovered_name; do") > 0)
        sub(/dns_name dhcp_mode discovered_name; do/, "dns_name dhcp_mode discovered_name fingerprint_vendor fingerprint_device fingerprint_device_name; do")

    if (index($0, "json_add_string discovered_name \"$discovered_name\"") > 0) {
        print
        print "        json_add_string fingerprint_vendor \"$fingerprint_vendor\""
        print "        json_add_string fingerprint_device \"$fingerprint_device\""
        print "        json_add_string fingerprint_device_name \"$fingerprint_device_name\""
        next
    }

    print
}
MDM_UFP_PATCH

        awk -v helper_file="$ufp_helper" -f "$backend_patch" "$backend_file" > "$tmp_dir/backend.ufp" ||
            die "Не удалось добавить чтение отпечатков UFP в RPC-обработчик."
        grep -Fq 'append_ufp_records "$raw"' "$tmp_dir/backend.ufp" ||
            die "Не удалось подключить UFP к списку устройств."
        grep -Fq 'ufp_device[tolower(m)]' "$tmp_dir/backend.ufp" ||
            die "Не удалось сопоставить отпечаток UFP по MAC."
        grep -Fq 'for fingerprint_key in $fingerprint_keys; do' "$ufp_helper" ||
            die "Не удалось обойти нормализованные jshn-ключи UFP."
        grep -Fq 'json_select "$fingerprint_key" 2>/dev/null || continue' "$ufp_helper" ||
            die "Не удалось выбрать запись UFP по нормализованному ключу."
        grep -Fq "tr '_' ':'" "$ufp_helper" ||
            die "Не удалось восстановить MAC-адрес из ключа UFP."
        grep -Fq 'json_add_string fingerprint_device "$fingerprint_device"' "$tmp_dir/backend.ufp" ||
            die "Не удалось добавить модель UFP в RPC-ответ."
        expected_ufp_printf='printf "%s|%s|%s|%s|%d|%d|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n", m, ip[m]'
        grep -Fq "$expected_ufp_printf" "$tmp_dir/backend.ufp" ||
            die "Проверка разделителя строк UFP не пройдена: каждая запись должна завершаться переводом строки."
        sh -n "$tmp_dir/backend.ufp" ||
            die "RPC-обработчик с UFP не прошёл проверку shell-синтаксиса."
        mv "$tmp_dir/backend.ufp" "$backend_file" ||
            die "Не удалось сохранить RPC-обработчик с UFP."
    fi

    if ! grep -Fq 'd.fingerprint_device' "$js_file"; then
        [ "$(grep -Fc 'return (d.discovered_name || "").trim() || usefulHostname(d) ||' "$js_file" || true)" = "1" ] ||
            die "Не найден выбор отображаемого имени для расширения UFP."
        [ "$(grep -Fc 'var searchable = [name, d.discovered_name, d.hostname, d.mac, d.ip].join' "$js_file" || true)" = "1" ] ||
            die "Не найден поиск устройств для расширения UFP."

        ui_patch="$tmp_dir/ufp-ui.awk"
        cat > "$ui_patch" <<'MDM_UFP_UI'
{
    if (index($0, "return !(d.name && d.name.trim()) && !((d.discovered_name || \"\").trim()) && !usefulHostname(d);")) {
        prefix=$0
        sub(/return.*/, "", prefix)
        $0=prefix "return !(d.name && d.name.trim()) && !((d.discovered_name || d.fingerprint_device_name || \"\").trim()) && !usefulHostname(d);"
    }

    if (index($0, "return (d.discovered_name || \"\").trim() || usefulHostname(d) ||")) {
        prefix=$0
        sub(/return.*/, "", prefix)
        $0=prefix "return (d.discovered_name || d.fingerprint_device_name || \"\").trim() || usefulHostname(d) || 'Неизвестное устройство';"
    }

    if (index($0, "var suggested = (d.discovered_name || \"\").trim() || usefulHostname(d);")) {
        prefix=$0
        sub(/var suggested.*/, "", prefix)
        $0=prefix "var suggested = (d.discovered_name || d.fingerprint_device_name || \"\").trim() || usefulHostname(d);"
    }

    if (index($0, "var searchable = [name, d.discovered_name, d.hostname, d.mac, d.ip].join")) {
        prefix=$0
        sub(/var searchable.*/, "", prefix)
        $0=prefix "var searchable = [name, d.discovered_name, d.fingerprint_device_name, d.fingerprint_device, d.fingerprint_vendor, d.hostname, d.mac, d.ip].join(' ').toLocaleLowerCase();"
    }

    if (index($0, "E('td', {}, [E('strong', {}, name), isUnidentifiedDevice(d)") > 0 &&
        index($0, "d.registered && d.dhcp_mode") > 0 &&
        index($0, "d.fingerprint_device") == 0) {
        marker = ", d.registered && d.dhcp_mode ?"
        at = index($0, marker)
        if (at > 0) {
            prefix = substr($0, 1, at - 1)
            suffix = substr($0, at)
            meta = ", (d.fingerprint_device || d.fingerprint_vendor) ? E('div', { 'class': 'mdm-muted' }, (d.fingerprint_device ? 'Модель: ' + d.fingerprint_device : '') + (d.fingerprint_vendor ? (d.fingerprint_device ? ' · ' : '') + 'Производитель по MAC: ' + d.fingerprint_vendor : '')) : ''"
            $0 = prefix meta suffix
        }
    }

    if (index($0, "Сначала используются читаемые имена mDNS-служб")) {
        sub(/Обнаруженные имена не записываются автоматически в системную конфигурацию\./,
            "Отпечатки UFP (если служба установлена) дополнительно показывают модель и производителя по сетевым признакам; производитель MAC может относиться к сетевому модулю, а не к бренду устройства. Автоматически в системную конфигурацию ничего не записывается.")
    }

    print
}
MDM_UFP_UI

        awk -f "$ui_patch" "$js_file" > "$tmp_dir/main.ufp.js" ||
            die "Не удалось обновить интерфейс для сведений UFP."
        grep -Fq 'd.fingerprint_device' "$tmp_dir/main.ufp.js" ||
            die "Проверка отображения модели UFP не пройдена."
        grep -Fq 'Производитель по MAC:' "$tmp_dir/main.ufp.js" ||
            die "Проверка отображения производителя UFP не пройдена."
        mv "$tmp_dir/main.ufp.js" "$js_file" ||
            die "Не удалось сохранить интерфейс со сведениями UFP."
    fi

    chmod 0755 "$backend_file" ||
        die "Не удалось выставить исполняемые права RPC-обработчика."
    [ -x "$backend_file" ] ||
        die "RPC-обработчик остался без права на исполнение."
}


apply_wifi_client_stats_patch() {
    local backend_file js_file wifi_helper wifi_patch ui_patch

    backend_file="$package_dir/root/usr/libexec/rpcd/luci.my_device_manager"
    js_file="$package_dir/htdocs/luci-static/resources/view/my-device-manager/main.js"
    [ -f "$backend_file" ] || die "Не найден RPC-обработчик для статистики Wi-Fi."
    [ -f "$js_file" ] || die "Не найден интерфейс для статистики Wi-Fi."

    if ! grep -Fq 'json_add_string wifi_signal_dbm "$wifi_signal_dbm"' "$backend_file"; then
        [ "$(grep -Fc 'list_devices() {' "$backend_file" || true)" = "1" ] ||
            die "Не найдено место для помощника статистики Wi-Fi."
        [ "$(grep -Fc '    append_ufp_records "$raw"' "$backend_file" || true)" = "1" ] ||
            die "Не найден вызов UFP-помощника для подключения статистики Wi-Fi."
        [ "$(grep -Fc '        $1 == "U" {' "$backend_file" || true)" = "1" ] ||
            die "Не найден парсер записей UFP для добавления статистики Wi-Fi."
        [ "$(grep -Fc 'ufp_device_name[tolower(m)]' "$backend_file" || true)" = "1" ] ||
            die "Не найдено место формирования строки устройства для статистики Wi-Fi."
        [ "$(grep -Fc 'dns_name dhcp_mode discovered_name fingerprint_vendor fingerprint_device fingerprint_device_name; do' "$backend_file" || true)" = "1" ] ||
            die "Не найден список полей ответа RPC для расширения статистикой Wi-Fi."
        [ "$(grep -Fc 'json_add_string fingerprint_device_name "$fingerprint_device_name"' "$backend_file" || true)" = "1" ] ||
            die "Не найдены поля UFP перед добавлением статистики Wi-Fi."

        wifi_helper="$tmp_dir/wifi-helper.sh"
        wifi_patch="$tmp_dir/wifi-backend.awk"
        cat > "$wifi_helper" <<'MDM_WIFI_HELPER'
append_wifi_client_records() {
    local output_file="$1" wifi_objects wifi_iface wifi_json wifi_freq wifi_client_keys wifi_client_key wifi_mac
    local wifi_signal wifi_ht wifi_vht wifi_he wifi_standard wifi_rate_rx wifi_rate_tx wifi_bytes_rx wifi_bytes_tx
    local wifi_rx_rate_mbps wifi_tx_rate_mbps

    [ -n "$output_file" ] || return 0
    command -v ubus >/dev/null 2>&1 || return 0
    command -v json_load >/dev/null 2>&1 || return 0

    # Read hostapd station stats only. This is optional and read-only: no
    # wireless config, radio state, routing, or firewall settings are changed.
    wifi_objects=$(ubus list 2>/dev/null | sed -n 's/^hostapd\.//p')
    [ -n "$wifi_objects" ] || return 0

    for wifi_iface in $wifi_objects; do
        case "$wifi_iface" in
            *[!A-Za-z0-9_.-]*) continue ;;
        esac
        wifi_json=$(ubus call "hostapd.$wifi_iface" get_clients '{}' 2>/dev/null) || continue
        [ -n "$wifi_json" ] || continue
        json_load "$wifi_json" 2>/dev/null || continue
        wifi_freq=""
        json_get_var wifi_freq freq
        wifi_freq=$(printf '%s' "$wifi_freq" | tr -cd '0-9')
        json_select clients 2>/dev/null || { json_cleanup; continue; }
        wifi_client_keys=""
        json_get_keys wifi_client_keys

        for wifi_client_key in $wifi_client_keys; do
            case "$wifi_client_key" in
                [0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F])
                    wifi_mac="$wifi_client_key" ;;
                [0-9a-fA-F][0-9a-fA-F]_[0-9a-fA-F][0-9a-fA-F]_[0-9a-fA-F][0-9a-fA-F]_[0-9a-fA-F][0-9a-fA-F]_[0-9a-fA-F][0-9a-fA-F]_[0-9a-fA-F][0-9a-fA-F])
                    wifi_mac=$(printf '%s' "$wifi_client_key" | tr '_' ':') ;;
                *) continue ;;
            esac

            json_select "$wifi_client_key" 2>/dev/null || continue
            wifi_signal=""
            wifi_ht=""
            wifi_vht=""
            wifi_he=""
            wifi_rate_rx=""
            wifi_rate_tx=""
            wifi_bytes_rx=""
            wifi_bytes_tx=""
            json_get_var wifi_signal signal
            json_get_var wifi_ht ht
            json_get_var wifi_vht vht
            json_get_var wifi_he he

            if json_select rate 2>/dev/null; then
                json_get_var wifi_rate_rx rx
                json_get_var wifi_rate_tx tx
                json_select ..
            fi
            if json_select bytes 2>/dev/null; then
                json_get_var wifi_bytes_rx rx
                json_get_var wifi_bytes_tx tx
                json_select ..
            fi
            json_select ..

            wifi_signal=$(printf '%s' "$wifi_signal" | tr -cd '0-9-')
            wifi_rate_rx=$(printf '%s' "$wifi_rate_rx" | tr -cd '0-9')
            wifi_rate_tx=$(printf '%s' "$wifi_rate_tx" | tr -cd '0-9')
            wifi_bytes_rx=$(printf '%s' "$wifi_bytes_rx" | tr -cd '0-9')
            wifi_bytes_tx=$(printf '%s' "$wifi_bytes_tx" | tr -cd '0-9')

            wifi_standard=""
            case "$wifi_he" in
                1|true|TRUE) wifi_standard="ax" ;;
                *)
                    case "$wifi_vht" in
                        1|true|TRUE) wifi_standard="ac" ;;
                        *)
                            case "$wifi_ht" in
                                1|true|TRUE) wifi_standard="n" ;;
                            esac
                            ;;
                    esac
                    ;;
            esac

            # OpenWrt/driver versions expose rates in either bit/s or kbit/s.
            # Normalize both representations to Mbit/s.
            wifi_rx_rate_mbps=""
            wifi_tx_rate_mbps=""
            if [ -n "$wifi_rate_rx" ] && [ "$wifi_rate_rx" -gt 0 ] 2>/dev/null; then
                wifi_rx_rate_mbps=$(awk -v r="$wifi_rate_rx" 'BEGIN { if (r >= 1000000) printf "%.1f", r / 1000000; else if (r >= 1000) printf "%.1f", r / 1000; else printf "%.1f", r }')
            fi
            if [ -n "$wifi_rate_tx" ] && [ "$wifi_rate_tx" -gt 0 ] 2>/dev/null; then
                wifi_tx_rate_mbps=$(awk -v r="$wifi_rate_tx" 'BEGIN { if (r >= 1000000) printf "%.1f", r / 1000000; else if (r >= 1000) printf "%.1f", r / 1000; else printf "%.1f", r }')
            fi

            printf 'W|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
                "$wifi_mac" "$wifi_iface" "$wifi_freq" "$wifi_signal" "$wifi_standard" \
                "$wifi_rx_rate_mbps" "$wifi_tx_rate_mbps" "$wifi_bytes_rx" "$wifi_bytes_tx" >> "$output_file"
        done
        json_cleanup
    done
}
MDM_WIFI_HELPER

        cat > "$wifi_patch" <<'MDM_WIFI_PATCH'
{
    if ($0 == "list_devices() {") {
        while ((getline helper_line < helper_file) > 0)
            print helper_line
        close(helper_file)
    }

    if ($0 == "    local raw merged section mac name band down up iface lease_ip dns_name dhcp_mode host_section discovered_name fingerprint_vendor fingerprint_device fingerprint_device_name")
        $0 = "    local raw merged section mac name band down up iface lease_ip dns_name dhcp_mode host_section discovered_name fingerprint_vendor fingerprint_device fingerprint_device_name wifi_iface wifi_frequency_mhz wifi_signal_dbm wifi_standard wifi_rx_rate_mbps wifi_tx_rate_mbps wifi_rx_bytes wifi_tx_bytes"

    if ($0 == "    append_ufp_records \"$raw\"") {
        print
        print "    append_wifi_client_records \"$raw\""
        next
    }

    if ($0 == "        $1 == \"U\" {") {
        print "        $1 == \"W\" {"
        print "            mac_key=tolower($2)"
        print "            if (mac_key ~ /^[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]/) {"
        print "                if ($3 != \"\") wifi_iface[mac_key]=$3"
        print "                if ($4 ~ /^[0-9]+$/) wifi_frequency_mhz[mac_key]=$4"
        print "                if ($5 ~ /^-?[0-9]+$/) wifi_signal_dbm[mac_key]=$5"
        print "                if ($6 != \"\") wifi_standard[mac_key]=$6"
        print "                if ($7 ~ /^[0-9]+([.][0-9]+)?$/) wifi_rx_rate_mbps[mac_key]=$7"
        print "                if ($8 ~ /^[0-9]+([.][0-9]+)?$/) wifi_tx_rate_mbps[mac_key]=$8"
        print "                if ($9 ~ /^[0-9]+$/) wifi_rx_bytes[mac_key]=$9"
        print "                if ($10 ~ /^[0-9]+$/) wifi_tx_bytes[mac_key]=$10"
        print "            }"
        print "        }"
        print
        next
    }

    if (index($0, "ufp_device_name[tolower(m)]") > 0 && index($0, "printf") > 0) {
        print "                printf \"%s|%s|%s|%s|%d|%d|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\\n\", m, ip[m], host[m], iface[m], online[m]+0, registered[m]+0, name[m], band[m], down[m], up[m], dns[m], mode[m], preferred, ufp_vendor[tolower(m)], ufp_device[tolower(m)], ufp_device_name[tolower(m)], wifi_iface[tolower(m)], wifi_frequency_mhz[tolower(m)], wifi_signal_dbm[tolower(m)], wifi_standard[tolower(m)], wifi_rx_rate_mbps[tolower(m)], wifi_tx_rate_mbps[tolower(m)], wifi_rx_bytes[tolower(m)], wifi_tx_bytes[tolower(m)];"
        next
    }

    if (index($0, "dns_name dhcp_mode discovered_name fingerprint_vendor fingerprint_device fingerprint_device_name; do") > 0)
        sub(/dns_name dhcp_mode discovered_name fingerprint_vendor fingerprint_device fingerprint_device_name; do/, "dns_name dhcp_mode discovered_name fingerprint_vendor fingerprint_device fingerprint_device_name wifi_iface wifi_frequency_mhz wifi_signal_dbm wifi_standard wifi_rx_rate_mbps wifi_tx_rate_mbps wifi_rx_bytes wifi_tx_bytes; do")

    if ($0 == "        json_add_string fingerprint_device_name \"$fingerprint_device_name\"") {
        print
        print "        json_add_string wifi_iface \"$wifi_iface\""
        print "        json_add_string wifi_frequency_mhz \"$wifi_frequency_mhz\""
        print "        json_add_string wifi_signal_dbm \"$wifi_signal_dbm\""
        print "        json_add_string wifi_standard \"$wifi_standard\""
        print "        json_add_string wifi_rx_rate_mbps \"$wifi_rx_rate_mbps\""
        print "        json_add_string wifi_tx_rate_mbps \"$wifi_tx_rate_mbps\""
        print "        json_add_string wifi_rx_bytes \"$wifi_rx_bytes\""
        print "        json_add_string wifi_tx_bytes \"$wifi_tx_bytes\""
        next
    }

    print
}
MDM_WIFI_PATCH

        awk -v helper_file="$wifi_helper" -f "$wifi_patch" "$backend_file" > "$tmp_dir/backend.wifi" ||
            die "Не удалось добавить сбор статистики Wi-Fi в RPC-обработчик."
        grep -Fq 'append_wifi_client_records "$raw"' "$tmp_dir/backend.wifi" ||
            die "Не удалось подключить сбор статистики Wi-Fi."
        grep -Fq 'wifi_signal_dbm[mac_key]=$5' "$tmp_dir/backend.wifi" ||
            die "Не удалось добавить разбор уровня сигнала Wi-Fi."
        grep -Fq 'json_add_string wifi_signal_dbm "$wifi_signal_dbm"' "$tmp_dir/backend.wifi" ||
            die "Не удалось добавить уровень сигнала в ответ RPC."
        grep -Fq 'wifi_tx_bytes[tolower(m)]' "$tmp_dir/backend.wifi" ||
            die "Не удалось сопоставить статистику Wi-Fi по MAC."
        grep -Fq 'wifi_rx_bytes wifi_tx_bytes; do' "$tmp_dir/backend.wifi" ||
            die "Не удалось добавить поля Wi-Fi-статистики в цикл чтения строк."
        wifi_stats_decl_count=$(grep -Fc 'wifi_signal_dbm wifi_standard' "$tmp_dir/backend.wifi" || true)
        [ "$wifi_stats_decl_count" -ge 1 ] ||
            die "Статистика Wi-Fi не добавлена в структуру ответа. Проверяю локальные объявления: $(grep -n 'local raw merged section' "$tmp_dir/backend.wifi" || true)"
        sh -n "$tmp_dir/backend.wifi" ||
            die "RPC-обработчик со статистикой Wi-Fi не прошёл проверку shell-синтаксиса."
        mv "$tmp_dir/backend.wifi" "$backend_file" ||
            die "Не удалось сохранить RPC-обработчик со статистикой Wi-Fi."
    fi

    if ! grep -Fq 'function wifiDetailsText(d)' "$js_file"; then
        [ "$(grep -Fc 'function rpcErrorMessage(err) {' "$js_file" || true)" = "1" ] ||
            die "Не найдено место для отображения статистики Wi-Fi."
        [ "$(grep -Fc 'd.fingerprint_device || d.fingerprint_vendor' "$js_file" || true)" = "1" ] ||
            die "Не найден блок сведений UFP для вставки статистики Wi-Fi."
        grep -Fq 'json_add_string wifi_tx_bytes "$wifi_tx_bytes"' "$backend_file" ||
            die "Поле счётчика Wi-Fi-трафика не найдено в RPC-обработчике."

        ui_patch="$tmp_dir/wifi-ui.awk"
        cat > "$ui_patch" <<'MDM_WIFI_UI'
{
    if ($0 == "function rpcErrorMessage(err) {") {
        print "function formatTrafficBytes(value) {"
        print "        var n = Number(value);"
        print "        if (!isFinite(n) || n <= 0) return '0 Б';"
        print "        var units = ['Б', 'КиБ', 'МиБ', 'ГиБ', 'ТиБ'];"
        print "        var i = 0;"
        print "        while (n >= 1024 && i < units.length - 1) { n /= 1024; i++; }"
        print "        return n.toFixed(i === 0 || n >= 100 ? 0 : (n >= 10 ? 1 : 2)) + ' ' + units[i];"
        print "}"
        print ""
        print "function wifiDetailsText(d) {"
        print "        if (!d.wifi_iface) return '';"
        print "        var parts = [];"
        print "        if (d.wifi_standard) parts.push('802.11' + d.wifi_standard);"
        print "        var freq = Number(d.wifi_frequency_mhz);"
        print "        if (freq === 2484) parts.push('канал 14');"
        print "        else if (freq >= 5955) parts.push('канал ' + Math.round((freq - 5950) / 5));"
        print "        else if (freq >= 5000) parts.push('канал ' + Math.round((freq - 5000) / 5));"
        print "        else if (freq >= 2412 && freq <= 2472) parts.push('канал ' + Math.round((freq - 2407) / 5));"
        print "        if (d.wifi_signal_dbm !== undefined && d.wifi_signal_dbm !== null && d.wifi_signal_dbm !== '') parts.push('сигнал ' + d.wifi_signal_dbm + ' dBm');"
        print "        var rxRate = Number(d.wifi_rx_rate_mbps);"
        print "        var txRate = Number(d.wifi_tx_rate_mbps);"
        print "        if (isFinite(rxRate) && rxRate > 0) parts.push('RX ' + rxRate.toFixed(1) + ' Мбит/с');"
        print "        if (isFinite(txRate) && txRate > 0) parts.push('TX ' + txRate.toFixed(1) + ' Мбит/с');"
        print "        var rxBytes = Number(d.wifi_rx_bytes);"
        print "        var txBytes = Number(d.wifi_tx_bytes);"
        print "        if ((isFinite(rxBytes) && rxBytes > 0) || (isFinite(txBytes) && txBytes > 0)) parts.push('трафик RX ' + formatTrafficBytes(rxBytes) + ' / TX ' + formatTrafficBytes(txBytes));"
        print "        return parts.join(' · ');"
        print "}"
        print ""
    }

    if (index($0, "E('td', {}, [E('strong', {}, name), isUnidentifiedDevice(d)") > 0 &&
        index($0, "d.fingerprint_device || d.fingerprint_vendor") > 0 &&
        index($0, "d.registered && d.dhcp_mode") > 0 &&
        index($0, "wifiDetailsText(d)") == 0) {
        marker = ", d.registered && d.dhcp_mode ?"
        at = index($0, marker)
        if (at > 0) {
            prefix = substr($0, 1, at - 1)
            suffix = substr($0, at)
            meta = ", wifiDetailsText(d) ? E('div', { 'class': 'mdm-muted' }, wifiDetailsText(d)) : ''"
            $0 = prefix meta suffix
        }
    }
    print
}
MDM_WIFI_UI

        awk -f "$ui_patch" "$js_file" > "$tmp_dir/main.wifi.js" ||
            die "Не удалось обновить интерфейс со статистикой Wi-Fi."
        grep -Fq 'function wifiDetailsText(d)' "$tmp_dir/main.wifi.js" ||
            die "Не удалось добавить отображение статистики Wi-Fi."
        grep -Fq 'RX ' "$tmp_dir/main.wifi.js" ||
            die "Не найдено отображение скорости Wi-Fi."
        grep -Fq 'трафик RX ' "$tmp_dir/main.wifi.js" ||
            die "Не найдено отображение счётчиков трафика."
        grep -Fq "wifiDetailsText(d) ? E('div'" "$tmp_dir/main.wifi.js" ||
            die "Не удалось подключить статистику к строке устройства."
        mv "$tmp_dir/main.wifi.js" "$js_file" ||
            die "Не удалось сохранить интерфейс со статистикой Wi-Fi."
    fi

    chmod 0755 "$backend_file" ||
        die "Не удалось выставить исполняемые права RPC-обработчика."
    [ -x "$backend_file" ] ||
        die "RPC-обработчик остался без права на исполнение."
}


apply_band_selection_patch() {
    local backend_file js_file acl_file helper_file dispatch_patch schema_patch ui_patch acl_patch unregister_patch

    backend_file="$package_dir/root/usr/libexec/rpcd/luci.my_device_manager"
    js_file="$package_dir/htdocs/luci-static/resources/view/my-device-manager/main.js"
    acl_file="$package_dir/root/usr/share/rpcd/acl.d/luci-app-my-device-manager.json"
    [ -f "$backend_file" ] || die "Не найден RPC-обработчик для выбора диапазона Wi-Fi."
    [ -f "$js_file" ] || die "Не найден интерфейс для выбора диапазона Wi-Fi."
    [ -f "$acl_file" ] || die "Не найден ACL rpcd для выбора диапазона Wi-Fi."

    if ! grep -Fq 'band_mode_apply_locked() {' "$backend_file"; then
        [ "$(grep -Fc 'list_devices() {' "$backend_file" || true)" = "1" ] ||
            die "Не найдено безопасное место для функций выбора диапазона Wi-Fi."
        [ "$(grep -Fc '        case "$method" in' "$backend_file" || true)" = "1" ] ||
            die "Не найден диспетчер RPC для выбора диапазона Wi-Fi."

        helper_file="$tmp_dir/band-helpers.sh"
        cat > "$helper_file" <<'MDM_BAND_HELPERS'
wifi_ap_sections() {
    uci -q show wireless 2>/dev/null | sed -n 's/^wireless\.\([^=]*\)=wifi-iface$/\1/p'
}

wifi_section_band() {
    local section="$1" radio band hwmode
    radio=$(uci -q get "wireless.$section.device" 2>/dev/null || true)
    [ -n "$radio" ] || return 1
    [ "$(uci -q get "wireless.$radio.disabled" 2>/dev/null || true)" != "1" ] || return 1
    band=$(uci -q get "wireless.$radio.band" 2>/dev/null || true)
    case "$band" in
        2g|5g|6g) printf '%s\n' "$band"; return 0 ;;
    esac
    hwmode=$(uci -q get "wireless.$radio.hwmode" 2>/dev/null || true)
    case "$hwmode" in
        *g*|*b*) printf '2g\n'; return 0 ;;
        *a*) printf '5g\n'; return 0 ;;
    esac
    return 1
}

wifi_ap_enabled() {
    [ "$(uci -q get "wireless.$1.mode" 2>/dev/null || true)" = "ap" ] || return 1
    [ "$(uci -q get "wireless.$1.disabled" 2>/dev/null || true)" != "1" ] || return 1
    wifi_section_band "$1" >/dev/null 2>&1
}

wifi_section_has_maclist() {
    uci -q show "wireless.$1" 2>/dev/null | grep -Fq '.maclist='
}

wifi_maclist_has() {
    uci -q show "wireless.$1" 2>/dev/null | awk -F"'" -v wanted="$2" '
        /\.maclist=/ {
            mac=tolower($2)
            gsub(/-/, ":", mac)
            if (mac == wanted) found=1
        }
        END { exit(found ? 0 : 1) }
    '
}

band_safe_key() {
    printf '%s' "$1" | tr -c 'A-Za-z0-9_' '_'
}

band_remove_acl_entries() {
    local registry_section="$1" mac="$2" safe_keys safe iface original current_filter
    safe_keys=$(uci -q show "$PACKAGE.$registry_section" 2>/dev/null |
        sed -n "s/^$PACKAGE\.$registry_section\.band_acl_added_\([^=]*\)=.*/\1/p")
    for safe in $safe_keys; do
        iface=$(uci -q get "$PACKAGE.$registry_section.band_acl_section_$safe" 2>/dev/null || true)
        original=$(uci -q get "$PACKAGE.$registry_section.band_acl_filter_changed_$safe" 2>/dev/null || true)
        if [ -n "$iface" ] && uci -q get "wireless.$iface" >/dev/null 2>&1; then
            current_filter=$(uci -q get "wireless.$iface.macfilter" 2>/dev/null || true)
            # Remove only an MDM-owned entry while it is still a deny-list.
            # If an administrator changed the filter to allow-list, preserve it.
            if [ "$current_filter" = "deny" ] && wifi_maclist_has "$iface" "$mac"; then
                uci -q del_list "wireless.$iface.maclist=$mac" >/dev/null 2>&1 || return 1
            fi
            if [ "$current_filter" = "deny" ] && [ -n "$original" ] && [ "$original" != "none" ] &&
               ! wifi_section_has_maclist "$iface"; then
                case "$original" in
                    missing) uci -q delete "wireless.$iface.macfilter" >/dev/null 2>&1 || return 1 ;;
                    disable) uci set "wireless.$iface.macfilter=disable" >/dev/null 2>&1 || return 1 ;;
                esac
            fi
        fi
        uci -q delete "$PACKAGE.$registry_section.band_acl_added_$safe" >/dev/null 2>&1 || true
        uci -q delete "$PACKAGE.$registry_section.band_acl_section_$safe" >/dev/null 2>&1 || true
        uci -q delete "$PACKAGE.$registry_section.band_acl_filter_changed_$safe" >/dev/null 2>&1 || true
    done
    return 0
}

band_preflight_peer() {
    local target="$1" allowed="$2" target_ssid target_encryption target_key peer peer_band peer_ssid peer_encryption peer_key found
    target_ssid=$(uci -q get "wireless.$target.ssid" 2>/dev/null || true)
    target_encryption=$(uci -q get "wireless.$target.encryption" 2>/dev/null || true)
    target_key=$(uci -q get "wireless.$target.key" 2>/dev/null || true)
    found=0
    for peer in $(wifi_ap_sections); do
        wifi_ap_enabled "$peer" || continue
        peer_band=$(wifi_section_band "$peer") || continue
        [ "$peer_band" = "$allowed" ] || continue
        peer_ssid=$(uci -q get "wireless.$peer.ssid" 2>/dev/null || true)
        peer_encryption=$(uci -q get "wireless.$peer.encryption" 2>/dev/null || true)
        peer_key=$(uci -q get "wireless.$peer.key" 2>/dev/null || true)
        if [ "$peer_ssid" = "$target_ssid" ] &&
           [ "$peer_encryption" = "$target_encryption" ] &&
           [ "$peer_key" = "$target_key" ]; then
            found=1
            break
        fi
    done
    [ "$found" = "1" ]
}

band_apply_acl() {
    local registry_section="$1" mac="$2" mode="$3"
    local iface wifi_band filter original safe found

    [ "$mode" = "auto" ] && return 0

    found=0
    for iface in $(wifi_ap_sections); do
        wifi_ap_enabled "$iface" || continue
        wifi_band=$(wifi_section_band "$iface") || continue
        [ "$wifi_band" = "$mode" ] && found=1
    done
    [ "$found" = "1" ] || return 11

    # Don't strand a client: every AP being denied must have a matching AP
    # on the permitted band with the same SSID, encryption mode and key.
    for iface in $(wifi_ap_sections); do
        wifi_ap_enabled "$iface" || continue
        wifi_band=$(wifi_section_band "$iface") || continue
        [ "$wifi_band" = "$mode" ] && continue
        band_preflight_peer "$iface" "$mode" || return 16
    done

    for iface in $(wifi_ap_sections); do
        wifi_ap_enabled "$iface" || continue
        wifi_band=$(wifi_section_band "$iface") || continue
        [ "$wifi_band" = "$mode" ] && continue

        filter=$(uci -q get "wireless.$iface.macfilter" 2>/dev/null || true)
        case "$filter" in
            allow) return 12 ;;
            deny) original=none ;;
            disable|'')
                # Enabling a dormant maclist could unexpectedly activate
                # manual entries, so refuse rather than change its semantics.
                if wifi_section_has_maclist "$iface"; then return 13; fi
                if [ -n "$filter" ]; then original=disable; else original=missing; fi
                ;;
            *) return 14 ;;
        esac
        if wifi_maclist_has "$iface" "$mac"; then return 15; fi

        if [ "$filter" != "deny" ]; then
            uci set "wireless.$iface.macfilter=deny" >/dev/null 2>&1 || return 14
        fi
        uci add_list "wireless.$iface.maclist=$mac" >/dev/null 2>&1 || return 14

        safe=$(band_safe_key "$iface")
        uci set "$PACKAGE.$registry_section.band_acl_added_$safe=1" >/dev/null 2>&1 || return 14
        uci set "$PACKAGE.$registry_section.band_acl_section_$safe=$iface" >/dev/null 2>&1 || return 14
        uci set "$PACKAGE.$registry_section.band_acl_filter_changed_$safe=$original" >/dev/null 2>&1 || return 14
    done
    return 0
}

band_transaction_rollback() {
    local dir="$1" reload_wifi="$2"
    uci revert wireless >/dev/null 2>&1 || true
    uci revert "$PACKAGE" >/dev/null 2>&1 || true
    cp -p "$dir/wireless" /etc/config/wireless 2>/dev/null || true
    cp -p "$dir/my_device_manager" "/etc/config/$PACKAGE" 2>/dev/null || true
    if [ "$reload_wifi" = "1" ] && command -v wifi >/dev/null 2>&1; then
        wifi reload >/dev/null 2>&1 || true
    fi
    rm -rf "$dir"
}

band_mode_apply_locked() {
    local mac="$1" new_mode="$2" section stored old_mode tx_dir rc wireless_changes reload_needed
    BAND_ERROR=band_mode_apply_failed
    mac=$(mac_normalize "$mac")
    if ! mac_valid "$mac"; then BAND_ERROR=invalid_mac; return 1; fi
    case "$new_mode" in
        auto|2g|5g) ;;
        *) BAND_ERROR=band_mode_invalid; return 1 ;;
    esac

    section=$(section_for_mac "$mac")
    stored=$(uci -q get "$PACKAGE.$section.mac" 2>/dev/null || true)
    if [ "$stored" != "$mac" ]; then BAND_ERROR=device_not_registered; return 1; fi
    old_mode=$(uci -q get "$PACKAGE.$section.band_mode" 2>/dev/null || true)
    [ -n "$old_mode" ] || old_mode=auto
    [ "$old_mode" != "$new_mode" ] || return 0

    if [ -n "$(uci changes wireless 2>/dev/null)" ] ||
       [ -n "$(uci changes "$PACKAGE" 2>/dev/null)" ]; then
        BAND_ERROR=wireless_config_busy
        return 1
    fi
    command -v wifi >/dev/null 2>&1 || { BAND_ERROR=wifi_reload_unavailable; return 1; }

    tx_dir=$(mktemp -d /tmp/mdm-band-tx.XXXXXX) || { BAND_ERROR=backup_failed; return 1; }
    cp -p /etc/config/wireless "$tx_dir/wireless" 2>/dev/null &&
    cp -p "/etc/config/$PACKAGE" "$tx_dir/my_device_manager" 2>/dev/null || {
        rm -rf "$tx_dir"
        BAND_ERROR=backup_failed
        return 1
    }

    band_remove_acl_entries "$section" "$mac" || {
        band_transaction_rollback "$tx_dir" 0
        BAND_ERROR=band_mode_apply_failed
        return 1
    }

    if band_apply_acl "$section" "$mac" "$new_mode"; then
        :
    else
        rc=$?
        case "$rc" in
            11) BAND_ERROR=wifi_band_not_found ;;
            12) BAND_ERROR=wireless_allowlist_conflict ;;
            13) BAND_ERROR=wireless_disabled_maclist_conflict ;;
            14) BAND_ERROR=band_mode_apply_failed ;;
            15) BAND_ERROR=wireless_maclist_conflict ;;
            16) BAND_ERROR=wifi_band_pair_not_found ;;
            *) BAND_ERROR=band_mode_apply_failed ;;
        esac
        band_transaction_rollback "$tx_dir" 0
        return 1
    fi

    uci set "$PACKAGE.$section.band_mode=$new_mode" >/dev/null 2>&1 || {
        band_transaction_rollback "$tx_dir" 0
        BAND_ERROR=band_mode_apply_failed
        return 1
    }

    wireless_changes=$(uci changes wireless 2>/dev/null)
    reload_needed=0
    if [ -n "$wireless_changes" ]; then
        if ! uci commit wireless >/dev/null 2>&1; then
            band_transaction_rollback "$tx_dir" 0
            BAND_ERROR=band_mode_apply_failed
            return 1
        fi
        reload_needed=1
    fi
    if ! uci commit "$PACKAGE" >/dev/null 2>&1; then
        band_transaction_rollback "$tx_dir" 0
        BAND_ERROR=band_mode_apply_failed
        return 1
    fi

    if [ "$reload_needed" = "1" ] && ! wifi reload >/dev/null 2>&1; then
        band_transaction_rollback "$tx_dir" 1
        BAND_ERROR=wifi_reload_failed
        return 1
    fi
    rm -rf "$tx_dir"
    return 0
}

MDM_BAND_HELPERS

        awk -v helper_file="$helper_file" '
            BEGIN {
                while ((getline line < helper_file) > 0) helper[++count] = line
                close(helper_file)
            }
            $0 == "list_devices() {" && !inserted {
                for (i = 1; i <= count; i++) print helper[i]
                inserted = 1
            }
            { print }
            END { if (!inserted) exit 1 }
        ' "$backend_file" > "$tmp_dir/backend.band" ||
            die "Не удалось добавить обработчик политик диапазона Wi-Fi."
        mv "$tmp_dir/backend.band" "$backend_file" ||
            die "Не удалось сохранить обработчик политик диапазона Wi-Fi."
    fi

    if ! grep -Fq 'band_mode_apply_locked "$mac" auto' "$backend_file"; then
        unregister_patch="$tmp_dir/band-unregister.awk"
        cat > "$unregister_patch" <<'MDM_BAND_UNREGISTER'
/^unregister_device\(\) \{$/ { in_unreg=1 }
in_unreg && $0 == "    backup_configs || { emit_error 'backup_failed'; return 1; }" && !done {
    print "    saved_band_mode=$(uci -q get \"$PACKAGE.$section.band_mode\" 2>/dev/null || true)"
    print "    if [ -n \"$saved_band_mode\" ] && [ \"$saved_band_mode\" != \"auto\" ]; then"
    print "        if ! band_mode_apply_locked \"$mac\" auto; then"
    print "            emit_error \"$BAND_ERROR\""
    print "            return 1"
    print "        fi"
    print "    fi"
    done=1
}
{ print }
MDM_BAND_UNREGISTER
        awk -f "$unregister_patch" "$backend_file" > "$tmp_dir/backend.unregister" ||
            die "Не удалось добавить снятие ограничений при отмене регистрации."
        grep -Fq 'band_mode_apply_locked "$mac" auto' "$tmp_dir/backend.unregister" ||
            die "Не удалось подключить снятие ограничений перед отменой регистрации."
        mv "$tmp_dir/backend.unregister" "$backend_file" ||
            die "Не удалось сохранить снятие ограничений при отмене регистрации."
    fi

    if ! grep -Fq 'set_band_mode)' "$backend_file"; then
        dispatch_patch="$tmp_dir/band-dispatch.awk"
        cat > "$dispatch_patch" <<'MDM_BAND_DISPATCH'
{
    if ($0 == "            unregister)") {
        print "            set_band_mode)"
        print "                mac=$(read_arg mac)"
        print "                band_mode=$(read_arg band_mode)"
        print "                if ! lock_begin; then"
        print "                    emit_error 'configuration_busy'"
        print "                elif band_mode_apply_locked \"$mac\" \"$band_mode\"; then"
        print "                    printf '{\"ok\":true,\"mac\":\"%s\",\"band_mode\":\"%s\"}\\n' \"$(mac_normalize \"$mac\")\" \"$band_mode\""
        print "                else"
        print "                    emit_error \"$BAND_ERROR\""
        print "                fi"
        print "                lock_end"
        print "                ;;"
    }
    print
}
MDM_BAND_DISPATCH
        awk -f "$dispatch_patch" "$backend_file" > "$tmp_dir/backend.dispatch" ||
            die "Не удалось добавить RPC-метод выбора диапазона Wi-Fi."
        grep -Fq 'set_band_mode)' "$tmp_dir/backend.dispatch" ||
            die "Не удалось добавить RPC-метод выбора диапазона Wi-Fi."
        mv "$tmp_dir/backend.dispatch" "$backend_file" ||
            die "Не удалось сохранить RPC-метод выбора диапазона Wi-Fi."
    fi

    if ! grep -Fq '"set_band_mode":{"mac":"str","band_mode":"str"}' "$backend_file"; then
        schema_patch="$tmp_dir/band-schema.awk"
        cat > "$schema_patch" <<'MDM_BAND_SCHEMA'
{
    old = "\"unregister\":{\"mac\":\"str\"}"
    new = old ",\"set_band_mode\":{\"mac\":\"str\",\"band_mode\":\"str\"}"
    if (index($0, old) > 0 && index($0, "set_band_mode") == 0) sub(old, new)
    print
}
MDM_BAND_SCHEMA
        awk -f "$schema_patch" "$backend_file" > "$tmp_dir/backend.schema" ||
            die "Не удалось обновить описание RPC-методов."
        grep -Fq '"set_band_mode":{"mac":"str","band_mode":"str"}' "$tmp_dir/backend.schema" ||
            die "Описание RPC-метода выбора диапазона Wi-Fi не добавлено."
        mv "$tmp_dir/backend.schema" "$backend_file" ||
            die "Не удалось сохранить описание RPC-методов."
    fi

    if ! grep -Fq 'callSetBandMode' "$js_file"; then
        ui_patch="$tmp_dir/band-ui.awk"
        cat > "$ui_patch" <<'MDM_BAND_UI'
{
    if (index($0, "var STYLE = ") > 0 && !call_added) {
        print "var callSetBandMode = rpc.declare({"
        print "        object: 'luci.my_device_manager',"
        print "        method: 'set_band_mode',"
        print "        params: ['mac', 'band_mode']"
        print "});"
        print ""
        call_added=1
    }

    if (index($0, "@media(max-width:600px)") > 0 && index($0, "mdm-unregistered") == 0) {
        print ".mdm-unregistered{display:inline-block;border-left:3px solid #f0c541;padding-left:7px;margin-top:4px;color:#f0d575;font-size:.82em}\\"
    }
    if (index($0, "@media(max-width:600px)") > 0 && index($0, "mdm-band-select") == 0) {
        print ".mdm-band-select{min-width:205px;max-width:260px}\\"
    }

    if (index($0, "E('p', { 'style': 'margin:12px 0 0' }") > 0) {
        $0 = "\t\t\tE('p', { 'style': 'margin:12px 0 0' }, 'Для зарегистрированных устройств можно выбрать только 2,4 ГГц, только 5 ГГц или оба диапазона без ограничений со стороны My Device Manager. В режиме двух диапазонов выбор остаётся за клиентом.'),"
    }

    if (index($0, "Приложение не меняет firewall") > 0) {
        sub(/Приложение не меняет firewall, Wi-Fi ACL, tc, mwan3 или Tachyon\./,
            "Выбор диапазона использует Wi-Fi ACL только для выбранного устройства и может кратковременно перезапустить точки доступа. Firewall, tc, mwan3 и Tachyon не меняются.")
    }

    if (index($0, "E('td', {}, E('span', { 'class': statusClass }, status)),") > 0 &&
        index($0, "mdm-unregistered") == 0) {
        old = "E('td', {}, E('span', { 'class': statusClass }, status)),"
        new = "E('td', {}, [E('span', { 'class': statusClass }, status), !d.registered ? E('div', { 'class': 'mdm-unregistered' }, 'Устройство не зарегистрировано') : '']),"
        at = index($0, old)
        if (at > 0) $0 = substr($0, 1, at - 1) new substr($0, at + length(old))
    }

    if ($0 == "\t\tvar actions = [registerButton];" && !select_added) {
        print
        print "\t\t\tif (d.registered) {"
        print "\t\t\t\tvar savedBandMode = d.band_mode || 'auto';"
        print "\t\t\t\tvar bandSelect = E('select', { 'class': 'cbi-input-select mdm-band-select', 'aria-label': 'Диапазон Wi-Fi для ' + name }, ["
        print "\t\t\t\t\tE('option', { 'value': 'auto' }, '2,4 + 5 ГГц — выбор клиента (без ограничений MDM)'),"
        print "\t\t\t\t\tE('option', { 'value': '2g' }, 'Только 2,4 ГГц'),"
        print "\t\t\t\t\tE('option', { 'value': '5g' }, 'Только 5 ГГц')"
        print "\t\t\t\t]);"
        print "\t\t\t\tbandSelect.value = savedBandMode;"
        print "\t\t\t\tbandSelect.addEventListener('change', function() {"
        print "\t\t\t\t\tvar selectedMode = bandSelect.value;"
        print "\t\t\t\t\tif (!window.confirm('Применение выбора кратковременно перезапустит Wi-Fi. Устройство будет запрещено на другом диапазоне и должно переподключиться к разрешённому. Продолжить?')) {"
        print "\t\t\t\t\t\tbandSelect.value = savedBandMode;"
        print "\t\t\t\t\t\treturn;"
        print "\t\t\t\t\t}"
        print "\t\t\t\t\tbandSelect.disabled = true;"
        print "\t\t\t\t\tcallSetBandMode(d.mac, selectedMode).then(function(result) {"
        print "\t\t\t\t\t\tif (result && result.ok === false) {"
        print "\t\t\t\t\t\t\tui.addNotification(null, E('p', {}, operationErrorMessage(result.error)), 'error');"
        print "\t\t\t\t\t\t\tbandSelect.disabled = false;"
        print "\t\t\t\t\t\t\tbandSelect.value = savedBandMode;"
        print "\t\t\t\t\t\t\treturn;"
        print "\t\t\t\t\t\t}"
        print "\t\t\t\t\t\twindow.location.reload();"
        print "\t\t\t\t\t}).catch(function(err) {"
        print "\t\t\t\t\t\tui.addNotification(null, E('p', {}, rpcErrorMessage(err)), 'error');"
        print "\t\t\t\t\t\tbandSelect.disabled = false;"
        print "\t\t\t\t\t\tbandSelect.value = savedBandMode;"
        print "\t\t\t\t\t});"
        print "\t\t\t\t});"
        print "\t\t\t\tactions.push(bandSelect);"
        print "\t\t\t}"
        select_added=1
        next
    }

    if (index($0, "device_not_registered:") > 0 && index($0, "wifi_band_not_found:") == 0) {
        print "\t\twifi_band_not_found: 'Не найдена активная точка доступа выбранного диапазона.',"
        print "\t\twifi_band_pair_not_found: 'Не найден такой же SSID с совпадающей защитой на выбранном диапазоне. Во избежание потери доступа настройка не изменена.',"
        print "\t\twireless_allowlist_conflict: 'В Wi-Fi настроен список разрешённых MAC-адресов. Существующая политика не изменена.',"
        print "\t\twireless_disabled_maclist_conflict: 'У этой точки доступа есть неактивный список MAC-адресов. Сначала проверь его в настройках Wi-Fi.',"
        print "\t\twireless_maclist_conflict: 'MAC-адрес уже есть в ручном Wi-Fi-списке. MDM не стал изменять это правило.',"
        print "\t\twireless_config_busy: 'Есть несохранённые изменения Wi-Fi или My Device Manager. Сохрани или отмени их и повтори.',"
        print "\t\twifi_reload_unavailable: 'Не найдена команда wifi для применения настроек.',"
        print "\t\twifi_reload_failed: 'Не удалось применить Wi-Fi-конфигурацию; выполнена попытка восстановить прежнюю конфигурацию.',"
        print "\t\tband_mode_invalid: 'Выбран неизвестный режим диапазона Wi-Fi.',"
        print "\t\tband_mode_apply_failed: 'Не удалось применить выбор диапазона Wi-Fi; изменения отменены.',"
    }

    print
}
MDM_BAND_UI
        awk -f "$ui_patch" "$js_file" > "$tmp_dir/main.band.js" ||
            die "Не удалось добавить выбор диапазона Wi-Fi в LuCI."
        grep -Fq 'callSetBandMode' "$tmp_dir/main.band.js" ||
            die "Не удалось подключить выбор диапазона Wi-Fi к RPC."
        grep -Fq 'Устройство не зарегистрировано' "$tmp_dir/main.band.js" ||
            die "Не удалось добавить пометку для незарегистрированных устройств."
        grep -Fq 'mdm-band-select' "$tmp_dir/main.band.js" ||
            die "Не удалось добавить селектор диапазона Wi-Fi."
        grep -Fq 'wifi_band_pair_not_found:' "$tmp_dir/main.band.js" ||
            die "Не добавлена ошибка проверки совместимости Wi-Fi."
        if command -v node >/dev/null 2>&1; then
            node --check "$tmp_dir/main.band.js" ||
                die "JavaScript интерфейса выбора диапазона Wi-Fi не прошёл синтаксическую проверку."
        fi
        mv "$tmp_dir/main.band.js" "$js_file" ||
            die "Не удалось сохранить интерфейс выбора диапазона Wi-Fi."
    fi

    if ! grep -Fq '"set_band_mode"' "$acl_file"; then
        acl_patch="$tmp_dir/band-acl.awk"
        cat > "$acl_patch" <<'MDM_BAND_ACL'
{
    if (index($0, "\"unregister\"") > 0 && index($0, "set_band_mode") == 0)
        sub("\"unregister\"", "\"unregister\", \"set_band_mode\"")
    print
}
MDM_BAND_ACL
        awk -f "$acl_patch" "$acl_file" > "$tmp_dir/acl.band.json" ||
            die "Не удалось обновить ACL rpcd для выбора диапазона Wi-Fi."
        grep -Fq '"set_band_mode"' "$tmp_dir/acl.band.json" ||
            die "ACL rpcd не содержит право на выбор диапазона Wi-Fi."
        mv "$tmp_dir/acl.band.json" "$acl_file" ||
            die "Не удалось сохранить ACL rpcd."
    fi

    grep -Fq 'band_mode_apply_locked() {' "$backend_file" ||
        die "Функция применения политики диапазона Wi-Fi отсутствует."
    grep -Fq 'set_band_mode)' "$backend_file" ||
        die "RPC-метод выбора диапазона Wi-Fi отсутствует."
    grep -Fq '"set_band_mode":{"mac":"str","band_mode":"str"}' "$backend_file" ||
        die "Описание RPC-метода выбора диапазона Wi-Fi отсутствует."
    grep -Fq 'wifi reload' "$backend_file" ||
        die "Не найден механизм применения Wi-Fi-политики."
    grep -Fq 'band_mode_apply_locked "$mac" auto' "$backend_file" ||
        die "Не подключено снятие ограничений перед отменой регистрации."
    sh -n "$backend_file" ||
        die "RPC-обработчик выбора диапазона Wi-Fi не прошёл проверку shell-синтаксиса."
    chmod 0755 "$backend_file" ||
        die "Не удалось выставить исполняемые права RPC-обработчика."
}


apply_two_level_registration_patch() {
    local backend_file js_file acl_file helper_file helper_patch local_patch dispatch_patch schema_patch ui_patch acl_patch

    backend_file="$package_dir/root/usr/libexec/rpcd/luci.my_device_manager"
    js_file="$package_dir/htdocs/luci-static/resources/view/my-device-manager/main.js"
    acl_file="$package_dir/root/usr/share/rpcd/acl.d/luci-app-my-device-manager.json"
    [ -f "$backend_file" ] || die "Не найден RPC-обработчик для двухуровневой регистрации."
    [ -f "$js_file" ] || die "Не найден интерфейс для двухуровневой регистрации."
    [ -f "$acl_file" ] || die "Не найден ACL rpcd для DHCP-регистрации."

    # The ordinary Register action stores only the My Device Manager record.
    # Keep MAC-format validation; band selection and the registry are MAC-keyed.
    if ! grep -Fq '# MDM_TWO_LEVEL_LOCAL_REGISTER' "$backend_file"; then
        local_patch="$tmp_dir/registration-local.awk"
        cat > "$local_patch" <<'MDM_LOCAL_REGISTER'
{
    if ($0 == "            register)") in_register = 1
    print
    if (in_register && index($0, "ip=$(read_arg ip)") > 0 && !added) {
        print "                ip=\"\" # MDM_TWO_LEVEL_LOCAL_REGISTER"
        added = 1
    }
    if (in_register && $0 == "                ;;") in_register = 0
}
END { if (!added) exit 1 }
MDM_LOCAL_REGISTER
        awk -f "$local_patch" "$backend_file" > "$tmp_dir/backend.local-register" ||
            die "Не удалось отделить регистрацию в приложении от DHCP. Контекст: $(grep -n -A18 -B5 -E \"register|read_arg ip|register_device\" \"$backend_file\" | head -n 100 | tr \"\\n\" \"|\")"
        grep -Fq '# MDM_TWO_LEVEL_LOCAL_REGISTER' "$tmp_dir/backend.local-register" ||
            die "Обычная регистрация всё ещё может передавать IP в DHCP."
        sh -n "$tmp_dir/backend.local-register" ||
            die "RPC-обработчик локальной регистрации не прошёл проверку shell-синтаксиса."
        mv "$tmp_dir/backend.local-register" "$backend_file" ||
            die "Не удалось сохранить режим регистрации только в My Device Manager."
    fi

    # The explicit DHCP action validates both the app registry and the static
    # lease target. It only edits /etc/config/dhcp and reloads dnsmasq.
    if ! grep -Fq 'register_dhcp_locked() {' "$backend_file"; then
        helper_file="$tmp_dir/dhcp-register-helper.sh"
        helper_patch="$tmp_dir/dhcp-register-helper.awk"
        cat > "$helper_file" <<'MDM_DHCP_REGISTER_HELPER'
register_dhcp_locked() {
    local mac="$1" ip="$2" name="$3" registry_section stored host_section host_mac host_ip normalized_host_mac
    local dns_name dhcp_section tx_dir

    DHCP_REGISTER_ERROR=dhcp_registration_failed
    mac=$(mac_normalize "$mac")
    if ! mac_valid "$mac"; then
        DHCP_REGISTER_ERROR=invalid_mac
        return 1
    fi
    if ! ipv4_valid "$ip"; then
        DHCP_REGISTER_ERROR=dhcp_ip_invalid
        return 1
    fi

    registry_section=$(section_for_mac "$mac")
    [ -n "$registry_section" ] || {
        DHCP_REGISTER_ERROR=device_not_registered
        return 1
    }
    stored=$(uci -q get "$PACKAGE.$registry_section.mac" 2>/dev/null || true)
    if [ "$stored" != "$mac" ]; then
        DHCP_REGISTER_ERROR=device_not_registered
        return 1
    fi

    if [ -n "$(uci changes dhcp 2>/dev/null)" ] ||
       [ -n "$(uci changes "$PACKAGE" 2>/dev/null)" ]; then
        DHCP_REGISTER_ERROR=configuration_busy
        return 1
    fi
    [ -f /etc/config/dhcp ] || {
        DHCP_REGISTER_ERROR=dhcp_registration_failed
        return 1
    }

    for host_section in $(uci -q show dhcp 2>/dev/null | sed -n 's/^dhcp\.\\([^=]*\\)=host$/\\1/p'); do
        host_mac=$(uci -q get "dhcp.$host_section.mac" 2>/dev/null || true)
        host_ip=$(uci -q get "dhcp.$host_section.ip" 2>/dev/null || true)
        normalized_host_mac=$(mac_normalize "$host_mac")
        if [ "$normalized_host_mac" = "$mac" ]; then
            if [ "$host_ip" = "$ip" ]; then
                # Idempotent: a static reservation for this exact pair already exists.
                return 0
            fi
            DHCP_REGISTER_ERROR=dhcp_mac_conflict
            return 1
        fi
        if [ -n "$host_ip" ] && [ "$host_ip" = "$ip" ]; then
            DHCP_REGISTER_ERROR=dhcp_ip_conflict
            return 1
        fi
    done

    tx_dir=$(mktemp -d /tmp/mdm-dhcp-register.XXXXXX) || {
        DHCP_REGISTER_ERROR=dhcp_registration_failed
        return 1
    }
    if ! cp -p /etc/config/dhcp "$tx_dir/dhcp"; then
        rm -rf "$tx_dir"
        DHCP_REGISTER_ERROR=dhcp_registration_failed
        return 1
    fi

    [ -n "$name" ] || name=$(uci -q get "$PACKAGE.$registry_section.name" 2>/dev/null || true)
    dns_name=$(dns_name_for "$mac" "$name")
    [ -n "$dns_name" ] || dns_name=device
    dhcp_section=$(uci add dhcp host 2>/dev/null) || {
        rm -rf "$tx_dir"
        DHCP_REGISTER_ERROR=dhcp_registration_failed
        return 1
    }
    if ! uci set "dhcp.$dhcp_section.name=$dns_name" >/dev/null 2>&1 ||
       ! uci set "dhcp.$dhcp_section.mac=$mac" >/dev/null 2>&1 ||
       ! uci set "dhcp.$dhcp_section.ip=$ip" >/dev/null 2>&1 ||
       ! uci commit dhcp >/dev/null 2>&1; then
        uci revert dhcp >/dev/null 2>&1 || true
        cp -p "$tx_dir/dhcp" /etc/config/dhcp 2>/dev/null || true
        rm -rf "$tx_dir"
        DHCP_REGISTER_ERROR=dhcp_registration_failed
        return 1
    fi

    if [ -x /etc/init.d/dnsmasq ] && ! /etc/init.d/dnsmasq reload >/dev/null 2>&1; then
        uci revert dhcp >/dev/null 2>&1 || true
        cp -p "$tx_dir/dhcp" /etc/config/dhcp 2>/dev/null || true
        /etc/init.d/dnsmasq reload >/dev/null 2>&1 || true
        rm -rf "$tx_dir"
        DHCP_REGISTER_ERROR=dhcp_reload_failed
        return 1
    fi

    rm -rf "$tx_dir"
    return 0
}

MDM_DHCP_REGISTER_HELPER

        awk -v helper_file="$helper_file" '
            BEGIN {
                while ((getline line < helper_file) > 0) helper[++count] = line
                close(helper_file)
            }
            $0 == "list_devices() {" && !inserted {
                for (i = 1; i <= count; i++) print helper[i]
                inserted = 1
            }
            { print }
            END { if (!inserted) exit 1 }
        ' "$backend_file" > "$tmp_dir/backend.dhcp-register-helper" ||
            die "Не удалось добавить отдельную DHCP-регистрацию."
        grep -Fq 'register_dhcp_locked() {' "$tmp_dir/backend.dhcp-register-helper" ||
            die "Функция DHCP-регистрации не добавлена."
        sh -n "$tmp_dir/backend.dhcp-register-helper" ||
            die "Помощник DHCP-регистрации не прошёл проверку shell-синтаксиса."
        mv "$tmp_dir/backend.dhcp-register-helper" "$backend_file" ||
            die "Не удалось сохранить помощник DHCP-регистрации."
    fi

    if ! grep -Fq 'register_dhcp)' "$backend_file"; then
        dispatch_patch="$tmp_dir/dhcp-register-dispatch.awk"
        cat > "$dispatch_patch" <<'MDM_DHCP_REGISTER_DISPATCH'
{
    if ($0 == "            set_band_mode)") {
        print "            register_dhcp)"
        print "                mac=$(read_arg mac)"
        print "                ip=$(read_arg ip)"
        print "                name=$(read_arg name)"
        print "                if ! lock_begin; then"
        print "                    emit_error 'configuration_busy'"
        print "                elif register_dhcp_locked \"$mac\" \"$ip\" \"$name\"; then"
        print "                    printf '{\"ok\":true,\"mac\":\"%s\",\"ip\":\"%s\"}\\n' \"$(mac_normalize \"$mac\")\" \"$ip\""
        print "                else"
        print "                    emit_error \"$DHCP_REGISTER_ERROR\""
        print "                fi"
        print "                lock_end"
        print "                ;;"
    }
    print
}
MDM_DHCP_REGISTER_DISPATCH
        awk -f "$dispatch_patch" "$backend_file" > "$tmp_dir/backend.dhcp-register-dispatch" ||
            die "Не удалось добавить RPC-метод DHCP-регистрации."
        grep -Fq 'register_dhcp)' "$tmp_dir/backend.dhcp-register-dispatch" ||
            die "RPC-метод DHCP-регистрации не добавлен."
        mv "$tmp_dir/backend.dhcp-register-dispatch" "$backend_file" ||
            die "Не удалось сохранить RPC-метод DHCP-регистрации."
    fi

    if ! grep -Fq '"register_dhcp":{"mac":"str","ip":"str","name":"str"}' "$backend_file"; then
        schema_patch="$tmp_dir/dhcp-register-schema.awk"
        cat > "$schema_patch" <<'MDM_DHCP_REGISTER_SCHEMA'
{
    old = "\"set_band_mode\":{\"mac\":\"str\",\"band_mode\":\"str\"}"
    new = old ",\"register_dhcp\":{\"mac\":\"str\",\"ip\":\"str\",\"name\":\"str\"}"
    if (index($0, old) > 0 && index($0, "\"register_dhcp\"") == 0) sub(old, new)
    print
}
MDM_DHCP_REGISTER_SCHEMA
        awk -f "$schema_patch" "$backend_file" > "$tmp_dir/backend.dhcp-register-schema" ||
            die "Не удалось обновить схему RPC для DHCP-регистрации."
        grep -Fq '"register_dhcp":{"mac":"str","ip":"str","name":"str"}' "$tmp_dir/backend.dhcp-register-schema" ||
            die "Схема RPC DHCP-регистрации не добавлена."
        mv "$tmp_dir/backend.dhcp-register-schema" "$backend_file" ||
            die "Не удалось сохранить схему RPC DHCP-регистрации."
    fi

    if ! grep -Fq '"register_dhcp"' "$acl_file"; then
        acl_patch="$tmp_dir/dhcp-register-acl.awk"
        cat > "$acl_patch" <<'MDM_DHCP_REGISTER_ACL'
{
    if (index($0, "\"set_band_mode\"") > 0 && index($0, "\"register_dhcp\"") == 0)
        sub("\"set_band_mode\"", "\"set_band_mode\", \"register_dhcp\"")
    print
}
MDM_DHCP_REGISTER_ACL
        awk -f "$acl_patch" "$acl_file" > "$tmp_dir/acl.dhcp-register" ||
            die "Не удалось добавить разрешение RPC на DHCP-регистрацию."
        grep -Fq '"register_dhcp"' "$tmp_dir/acl.dhcp-register" ||
            die "ACL rpcd не содержит метод DHCP-регистрации."
        mv "$tmp_dir/acl.dhcp-register" "$acl_file" ||
            die "Не удалось сохранить ACL rpcd DHCP-регистрации."
    fi

    if ! grep -Fq 'var callRegisterDhcp = rpc.declare({' "$js_file"; then
        ui_patch="$tmp_dir/dhcp-register-ui.awk"
        cat > "$ui_patch" <<'MDM_DHCP_REGISTER_UI'
{
    if ($0 == "var callSetBandMode = rpc.declare({") {
        print "var callRegisterDhcp = rpc.declare({"
        print "        object: 'luci.my_device_manager',"
        print "        method: 'register_dhcp',"
        print "        params: ['mac', 'ip', 'name']"
        print "});"
        print ""
    }

    if (index($0, "actions.push(bandSelect);") > 0 && index($0, "registerDhcpButton") == 0) {
        print
        print "\t\t\t\tvar dhcpMode = String(d.dhcp_mode || '').toLowerCase();"
        print "\t\t\t\tvar hasDhcpReservation = /static|reserved|reservation|registered|host/.test(dhcpMode);"
        print "\t\t\t\tif (d.ip && !hasDhcpReservation) {"
        print "\t\t\t\t\tvar dhcpRegisterButton = E('button', { 'class': 'cbi-button cbi-button-action', 'click': function() {"
        print "\t\t\t\t\t\tif (!window.confirm('Создать статическую DHCP-резервацию для ' + d.mac + ' с IP ' + d.ip + '?')) return;"
        print "\t\t\t\t\t\tdhcpRegisterButton.disabled = true;"
        print "\t\t\t\t\t\tcallRegisterDhcp(d.mac, d.ip, d.name || name).then(function(result) {"
        print "\t\t\t\t\t\t\tif (result && result.ok === false) {"
        print "\t\t\t\t\t\t\t\tui.addNotification(null, E('p', {}, operationErrorMessage(result.error)), 'error');"
        print "\t\t\t\t\t\t\t\tdhcpRegisterButton.disabled = false;"
        print "\t\t\t\t\t\t\t\treturn;"
        print "\t\t\t\t\t\t\t}"
        print "\t\t\t\t\t\t\twindow.location.reload();"
        print "\t\t\t\t\t\t}).catch(function(err) {"
        print "\t\t\t\t\t\t\tui.addNotification(null, E('p', {}, rpcErrorMessage(err)), 'error');"
        print "\t\t\t\t\t\t\tdhcpRegisterButton.disabled = false;"
        print "\t\t\t\t\t\t});"
        print "\t\t\t\t\t} }, 'DHCP Регистрация');"
        print "\t\t\t\t\tactions.push(dhcpRegisterButton);"
        print "\t\t\t\t}"
        next
    }

    if (index($0, "device_not_registered:") > 0 && index($0, "dhcp_ip_invalid:") == 0) {
        print "\t\tdhcp_ip_invalid: 'Для DHCP-регистрации нужен корректный IPv4-адрес.',"
        print "\t\tdhcp_mac_conflict: 'Этот MAC уже связан с другой DHCP-резервацией. Сначала проверь раздел DHCP и DNS.',"
        print "\t\tdhcp_ip_conflict: 'Этот IP уже зарезервирован для другого MAC-адреса.',"
        print "\t\tdhcp_registration_failed: 'Не удалось создать DHCP-резервацию; конфигурация восстановлена.',"
        print "\t\tdhcp_reload_failed: 'Не удалось применить DHCP-резервацию; выполнена попытка восстановления прежней конфигурации.',"
    }

    print
}
MDM_DHCP_REGISTER_UI
        awk -f "$ui_patch" "$js_file" > "$tmp_dir/main.dhcp-register.js" ||
            die "Не удалось добавить кнопку DHCP-регистрации."
        grep -Fq 'callRegisterDhcp' "$tmp_dir/main.dhcp-register.js" ||
            die "Не удалось подключить кнопку DHCP-регистрации к RPC."
        grep -Fq 'DHCP Регистрация' "$tmp_dir/main.dhcp-register.js" ||
            die "Не удалось добавить подпись DHCP-регистрации."
        grep -Fq 'dhcp_ip_conflict:' "$tmp_dir/main.dhcp-register.js" ||
            die "Не добавлены сообщения ошибок DHCP-регистрации."
        if command -v node >/dev/null 2>&1; then
            node --check "$tmp_dir/main.dhcp-register.js" ||
                die "JavaScript DHCP-регистрации не прошёл проверку синтаксиса."
        fi
        mv "$tmp_dir/main.dhcp-register.js" "$js_file" ||
            die "Не удалось сохранить кнопку DHCP-регистрации."
    fi

    grep -Fq '# MDM_TWO_LEVEL_LOCAL_REGISTER' "$backend_file" ||
        die "Обычная регистрация не отделена от DHCP."
    grep -Fq 'register_dhcp_locked() {' "$backend_file" ||
        die "Отдельная функция DHCP-регистрации отсутствует."
    grep -Fq 'register_dhcp)' "$backend_file" ||
        die "RPC-метод DHCP-регистрации отсутствует."
    grep -Fq '"register_dhcp":{"mac":"str","ip":"str","name":"str"}' "$backend_file" ||
        die "Схема RPC DHCP-регистрации отсутствует."
    grep -Fq '"register_dhcp"' "$acl_file" ||
        die "ACL rpcd не разрешает DHCP-регистрацию."
    grep -Fq 'MDM_TWO_LEVEL_LOCAL_REGISTER' "$backend_file" ||
        die "Обычная регистрация не помечена как локальная."
    sh -n "$backend_file" ||
        die "RPC-обработчик двухуровневой регистрации не прошёл проверку shell-синтаксиса."
    chmod 0755 "$backend_file" ||
        die "Не удалось выставить исполняемые права RPC-обработчика."
}


validate_payload() {
    [ -d "$package_dir" ] || die "В архиве отсутствует каталог приложения."
    [ -f "$package_dir/root/usr/share/luci/menu.d/luci-app-my-device-manager.json" ] ||
        die "В архиве отсутствует запись меню LuCI."
    [ -f "$package_dir/root/usr/share/rpcd/acl.d/luci-app-my-device-manager.json" ] ||
        die "В архиве отсутствуют ACL rpcd."
    [ -f "$package_dir/root/usr/libexec/rpcd/luci.my_device_manager" ] ||
        die "В архиве отсутствует RPC-обработчик устройств."
    [ -d "$package_dir/root" ] || die "В архиве отсутствуют системные файлы приложения."
    if [ ! -d "$package_dir/htdocs" ] && [ ! -d "$package_dir/luasrc" ] && [ ! -d "$package_dir/ucode" ]; then
        die "В архиве отсутствуют файлы интерфейса LuCI."
    fi
}

do_check() {
    download_source
    apply_mac_validation_patch
    apply_device_hostname_precedence_fix
    apply_mdns_discovery_patch
    apply_ufp_fingerprint_patch
    apply_wifi_client_stats_patch
    apply_band_selection_patch
    apply_two_level_registration_patch
    validate_payload
    log "Проверка успешна: архив, DHCP/mDNS, UFP, статистика Wi-Fi, выбор диапазона и пометка незарегистрированных устройств корректны."
}

do_install() {
    require_root
    command -v uci >/dev/null 2>&1 || die "Не похоже на OpenWrt: не найден uci."
    [ -d /www/luci-static ] || die "Не найден LuCI в /www/luci-static. Установи LuCI перед этим скриптом."

    download_source
    apply_mac_validation_patch
    apply_device_hostname_precedence_fix
    apply_mdns_discovery_patch
    apply_ufp_fingerprint_patch
    apply_wifi_client_stats_patch
    apply_band_selection_patch
    apply_two_level_registration_patch
    validate_payload

    mkdir -p "$STATE_DIR"
    touch "$STATE_DIR/original-files" "$STATE_DIR/new-files"

    log "Устанавливаю файлы LuCI..."
    install_tree "$package_dir/root" /
    # Be defensive: rpcd handlers must be executable regardless of archive mode.
    chmod 0755 /usr/libexec/rpcd/luci.my_device_manager ||
        die "Не удалось выставить исполняемые права RPC-обработчика."
    [ -x /usr/libexec/rpcd/luci.my_device_manager ] ||
        die "RPC-обработчик не исполняемый; rpcd не сможет зарегистрировать объект."
    install_tree "$package_dir/htdocs" /www
    install_tree "$package_dir/luasrc" /usr/lib/lua/luci
    install_tree "$package_dir/ucode" /usr/share/ucode/luci

    restart_services
    log "Установка завершена. Обнови страницу LuCI или выйди и войди снова."
    log "Для удаления и восстановления прежних файлов выполни: sh $0 uninstall"
}
do_uninstall() {
    require_root
    [ -d "$STATE_DIR" ] || die "Резервные данные установки не найдены."

    # Remove MDM-owned Wi-Fi ACL entries before removing the app files.
    # If cleanup fails, abort uninstall instead of leaving silent restrictions.
    if [ -x /usr/libexec/rpcd/luci.my_device_manager ] && command -v uci >/dev/null 2>&1; then
        for section in $(uci -q show my_device_manager 2>/dev/null | sed -n 's/^my_device_manager\.\([^.]*\)\.band_mode=.*/\1/p'); do
            band_mode=$(uci -q get "my_device_manager.$section.band_mode" 2>/dev/null || true)
            mac=$(uci -q get "my_device_manager.$section.mac" 2>/dev/null || true)
            if [ -n "$mac" ] && [ -n "$band_mode" ] && [ "$band_mode" != "auto" ]; then
                if ! printf '{"mac":"%s","band_mode":"auto"}\n' "$mac" | /usr/libexec/rpcd/luci.my_device_manager call set_band_mode >/dev/null 2>&1; then
                    die "Не удалось снять ограничение Wi-Fi для $mac; приложение оставлено установленным для исправления."
                fi
            fi
        done
    fi

    log "Восстанавливаю файлы, существовавшие до установки..."
    if [ -f "$STATE_DIR/original-files" ]; then
        while IFS= read -r target_file; do
            [ -n "$target_file" ] || continue
            backup_file="${BACKUP_DIR}${target_file}"
            if [ -e "$backup_file" ] || [ -L "$backup_file" ]; then
                mkdir -p "$(dirname "$target_file")"
                rm -f "$target_file"
                cp -a "$backup_file" "$target_file"
            fi
        done < "$STATE_DIR/original-files"
    fi

    log "Удаляю файлы, добавленные установщиком..."
    if [ -f "$STATE_DIR/new-files" ]; then
        while IFS= read -r target_file; do
            [ -n "$target_file" ] || continue
            # The app's UCI config may contain user edits; keep it on uninstall.
            case "$target_file" in
                /etc/config/my_device_manager)
                    log "Оставляю пользовательскую конфигурацию: $target_file"
                    continue
                    ;;
            esac
            rm -f "$target_file"
        done < "$STATE_DIR/new-files"
    fi

    rm -rf "$STATE_DIR"
    restart_services
    log "Удаление завершено. Пустые каталоги не трогал; пакеты OpenWrt не удалялись."
}

case "${1:-install}" in
    install) do_install ;;
    check|verify) do_check ;;
    uninstall|remove) do_uninstall ;;
    -h|--help|help)
        printf 'Usage: sh install.sh [install|uninstall|check]\n'
        ;;
    *) die "Неизвестная команда: $1 (используй install или uninstall)." ;;
esac
