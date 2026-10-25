#!/bin/sh
# My Device Manager bootstrap installer for OpenWrt 25.12.x.
# Installs the existing LuCI source payload directly; no SDK or APK required.
set -eu

APP_NAME="My Device Manager"
# Pin the source bundle to an immutable commit so the installer never silently
# mixes its script with a changing set of source chunks.
SOURCE_REF="fd659704f3f5a236b8e0b3b2fabd121b10a65470"
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

validate_payload() {
    [ -d "$package_dir" ] || die "В архиве отсутствует каталог приложения."
    [ -f "$package_dir/root/usr/share/luci/menu.d/luci-app-my-device-manager.json" ] ||
        die "В архиве отсутствует запись меню LuCI."
    [ -f "$package_dir/root/usr/share/rpcd/acl.d/luci-app-my-device-manager.json" ] ||
        die "В архиве отсутствуют ACL rpcd."
    [ -d "$package_dir/root" ] || die "В архиве отсутствуют системные файлы приложения."
    if [ ! -d "$package_dir/htdocs" ] && [ ! -d "$package_dir/luasrc" ] && [ ! -d "$package_dir/ucode" ]; then
        die "В архиве отсутствуют файлы интерфейса LuCI."
    fi
}

do_check() {
    download_source
    validate_payload
    log "Проверка успешна: архив и обязательные файлы LuCI корректны."
}

do_install() {
    require_root
    command -v uci >/dev/null 2>&1 || die "Не похоже на OpenWrt: не найден uci."
    [ -d /www/luci-static ] || die "Не найден LuCI в /www/luci-static. Установи LuCI перед этим скриптом."

    download_source
    validate_payload

    mkdir -p "$STATE_DIR"
    touch "$STATE_DIR/original-files" "$STATE_DIR/new-files"

    log "Устанавливаю файлы LuCI..."
    install_tree "$package_dir/root" /
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
