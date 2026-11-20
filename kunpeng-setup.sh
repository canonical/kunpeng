#!/usr/bin/env bash

set -u
set -o pipefail
export LC_ALL=C

readonly PPA="huawei-kunpeng-ubuntu/kunpeng-stable"
readonly KERNEL_4K_PACKAGE="linux-kunpeng-devel"
readonly KERNEL_64K_PACKAGE="linux-kunpeng-devel-64k"
readonly QEMU_PACKAGE="qemu-system-arm"
readonly -a LIBVIRT_PACKAGES=("libvirt-daemon-system" "libvirt-clients")
readonly OPENSSL_PACKAGE="openssl"
readonly RASDAEMON_PACKAGE="rasdaemon"
readonly HIKPTOOL_PACKAGE="hikptool"
PREVIEW_MODE=0
readonly PPA_URI_AWK='
    function matches_uri(uri, host) {
        if (uri !~ /^https?:\/\//) return 0
        sub(/^https?:\/\//, "", uri)
        sub(/^[^/]*@/, "", uri)
        host = uri
        sub(/\/.*/, "", host)
        sub(/:[0-9]+$/, "", host)
        host = tolower(host)
        if (host != "ppa.launchpad.net" &&
            host != "ppa.launchpadcontent.net" &&
            host != "private-ppa.launchpad.net" &&
            host != "private-ppa.launchpadcontent.net") return 0
        sub(/^[^/]*\//, "", uri)
        sub(/\/$/, "", uri)
        return uri == ppa "/ubuntu"
    }
'

as_root() {
    if (( PREVIEW_MODE )); then
        printf 'PREVIEW: privileged command blocked; no changes were made.\n' >&2
        return 1
    fi
    if (( EUID == 0 )); then
        "$@"
    else
        sudo "$@"
    fi
}

confirm() {
    local answer
    read -r -p "$1 [y/N]: " answer || return 1
    [[ "$answer" == "y" || "$answer" == "Y" ]]
}

require_root_access() {
    if (( PREVIEW_MODE )); then
        printf 'PREVIEW: this action is blocked. No packages or system settings were changed.\n' >&2
        return 1
    fi
    if (( EUID != 0 )); then
        if ! command -v sudo >/dev/null 2>&1; then
            printf 'Error: sudo is required, or run this script as root.\n' >&2
            return 1
        fi
        sudo -v || return 1
    fi
}

require_arm64() {
    if (( PREVIEW_MODE )); then
        return 0
    fi
    local architecture
    architecture=$(dpkg --print-architecture) || {
        printf 'Error: cannot determine the native package architecture.\n' >&2
        return 1
    }
    if [[ "$architecture" != "arm64" ]]; then
        printf 'Error: installation requires native ARM64 Ubuntu; this system is %s.\n' "$architecture" >&2
        printf 'Adding arm64 as a foreign architecture does not make ARM64 applications runnable.\n' >&2
        printf 'Use --preview for local inspection, or test installation on an ARM64 system.\n' >&2
        return 1
    fi
}

require_kunpeng_ppa() {
    local result
    if ppa_is_imported; then
        return 0
    else
        result=$?
    fi
    if (( result == 1 )); then
        printf 'Error: ppa:%s is not enabled. Import it using menu option 1 first.\n' "$PPA" >&2
    else
        printf 'Error: cannot determine whether the Kunpeng PPA is enabled.\n' >&2
    fi
    return 1
}

refresh_apt_indexes() {
    if ! as_root apt-get -o APT::Update::Error-Mode=any update; then
        printf 'Error: APT index refresh failed; installation stopped to avoid using stale indexes.\n' >&2
        printf 'Check the repository URL, publication status, network access, and the APT errors above.\n' >&2
        printf 'HTTP 403 means repository access was denied; retry after access or publication is fixed.\n' >&2
        printf 'No alternate PPA will be selected and signature verification will not be disabled.\n' >&2
        return 1
    fi
}

show_running_kernel() {
    local release page_size label
    release=$(uname -r) || return 1
    page_size=$(getconf PAGESIZE) || return 1
    case "$page_size" in
        4096) label="4K" ;;
        65536) label="64K" ;;
        *) label="$page_size bytes" ;;
    esac
    printf 'Running kernel: %s | Page size: %s\n' "$release" "$label"
}

kernel_image_package() {
    local ownership package
    ownership=$(dpkg-query -S "/boot/vmlinuz-$1") || return 1
    if [[ "$ownership" == *$'\n'* || "$ownership" != *": /boot/vmlinuz-$1" ]]; then
        printf 'Error: cannot identify a unique kernel image package.\n' >&2
        return 1
    fi
    package="${ownership%: /boot/vmlinuz-$1}"
    if [[ "$package" == *,* ]]; then
        printf 'Error: the kernel image has multiple package owners.\n' >&2
        return 1
    fi
    printf '%s\n' "$package"
}

grub_has_kernel() {
    as_root awk -v image="vmlinuz-$1" '
        $1 == "linux" || $1 == "linuxefi" {
            path = $2
            sub(/^.*\//, "", path)
            if (path == image) found = 1
        }
        END { exit !found }
    ' /boot/grub/grub.cfg
}

switch_kernel() {
    local target_package="$1" target_pages="$2" target_release
    local target_version image_meta image_package details dependencies source_label
    local running_release old_package new_package removal_plan package image
    running_release=$(uname -r) || return 1

    printf '\nTarget package: %s | Page size: %s\n' "$target_package" "$target_pages"
    printf 'The old kernel image package will be removed after the new kernel is verified.\n'
    printf 'WARNING: removing the running kernel may break module loading until reboot.\n'
    printf 'WARNING: the old kernel will no longer be available as a boot fallback.\n'
    confirm "Switch to the $target_pages kernel and remove the running kernel?" || return 0
    require_arm64 || return 1
    require_root_access || return 1
    require_kunpeng_ppa || return 1
    if ! command -v update-grub >/dev/null 2>&1 || [[ ! -f /boot/grub/grub.cfg ]]; then
        printf 'Error: this kernel replacement workflow requires an existing GRUB configuration.\n' >&2
        return 1
    fi
    old_package=$(kernel_image_package "$running_release") || return 1
    refresh_apt_indexes || return 1
    target_version=$(latest_repository_version "$target_package" ppa) || return 1
    image_meta="${target_package/linux-/linux-image-}"
    for package in "$target_package" "$image_meta"; do
        source_label=$(package_metadata "$package" source "$target_version") || return 1
        if [[ "$source_label" != "Kunpeng PPA" ]]; then
            printf 'Error: %s version %s is not uniquely available from the configured Kunpeng PPA.\n' "$package" "$target_version" >&2
            return 1
        fi
    done
    details=$(apt-cache show "$image_meta=$target_version") || return 1
    dependencies=$(printf '%s\n' "$details" | awk '/^Depends:/ { print }') || return 1
    image_package=$(printf '%s\n' "$dependencies" |
        grep -oE 'linux-image(-unsigned)?-[0-9][a-zA-Z0-9.+-]*' | sort -u) || return 1
    if [[ -z "$image_package" || "$image_package" == *$'\n'* ]]; then
        printf 'Error: cannot resolve a unique versioned kernel image dependency.\n' >&2
        return 1
    fi
    target_release="${image_package#linux-image-}"
    target_release="${target_release#unsigned-}"
    case "$target_pages:$target_release" in
        4K:*-kunpeng-devel|64K:*-kunpeng-devel-64k) ;;
        *)
            printf 'Error: the image dependency does not match the requested kernel flavor.\n' >&2
            return 1
            ;;
    esac
    if [[ "$target_release" == "$running_release" ]]; then
        printf 'Error: the selected target is the running kernel; refusing replacement.\n' >&2
        return 1
    fi
    source_label=$(package_metadata "$image_package" source "$target_version") || return 1
    if [[ "$source_label" != "Kunpeng PPA" ]]; then
        printf 'Error: the target kernel image is not uniquely available from the configured PPA.\n' >&2
        return 1
    fi
    printf 'Resolved target release: %s | Package version: %s\n' "$target_release" "$target_version"
    as_root apt-get --no-remove install "$target_package=$target_version" \
        "$image_meta=$target_version" "$image_package=$target_version" || return 1

    for image in "/boot/vmlinuz-$target_release" \
        "/boot/initrd.img-$target_release" "/boot/config-$target_release"; do
        if [[ ! -s "$image" ]]; then
            printf 'Error: required target kernel file is missing or empty: %s\n' "$image" >&2
            return 1
        fi
    done
    if [[ ! -d "/lib/modules/$target_release" ]]; then
        printf 'Error: target kernel modules are missing.\n' >&2
        return 1
    fi
    if ! grep -qx "CONFIG_ARM64_${target_pages}_PAGES=y" "/boot/config-$target_release"; then
        printf 'Error: the target kernel configuration does not match the requested page size.\n' >&2
        return 1
    fi
    new_package=$(kernel_image_package "$target_release") || return 1
    if [[ "$new_package" == "$old_package" ]]; then
        printf 'Error: old and new images belong to the same package; refusing removal.\n' >&2
        return 1
    fi
    if [[ "${new_package%%:*}" != "$image_package" ]]; then
        printf 'Error: the installed image is not owned by the expected package.\n' >&2
        return 1
    fi
    as_root update-grub || return 1
    if ! grub_has_kernel "$target_release"; then
        printf 'Error: the target kernel was not found in the generated GRUB configuration.\n' >&2
        return 1
    fi

    # Direct replacement must leave no other kernel that could become GRUB's default.
    for image in /boot/vmlinuz-*; do
        [[ -f "$image" ]] || continue
        if [[ "$image" != "/boot/vmlinuz-$running_release" &&
              "$image" != "/boot/vmlinuz-$target_release" ]]; then
            printf 'Error: another kernel is present: %s\n' "$image" >&2
            printf 'The new kernel is installed; old kernel removal was not attempted.\n' >&2
            return 1
        fi
    done
    if [[ -f /etc/default/grub ]] &&
        ! as_root bash -c '
            source /etc/default/grub || exit 1
            for file in /etc/default/grub.d/*.cfg; do
                [[ -f "$file" ]] || continue
                source "$file" || exit 1
            done
            [[ "${GRUB_DEFAULT:-0}" == "0" ]]
        '; then
        printf 'Error: a custom GRUB default is configured; old kernel removal was not attempted.\n' >&2
        return 1
    fi

    removal_plan=$(as_root apt-get --simulate remove "$old_package") || return 1
    printf '\n%s\n' "$removal_plan"
    while read -r package; do
        [[ -n "$package" ]] || continue
        if [[ "${package%%:*}" == "${new_package%%:*}" ||
              "${package%%:*}" == "$target_package" ||
              "${package%%:*}" == "$image_meta" ]]; then
            printf 'Error: APT would remove the target kernel; refusing removal.\n' >&2
            return 1
        fi
        case "${package%%:*}" in
            linux-image-*|linux-modules-*|linux-headers-*|linux-kunpeng-*) ;;
            *)
                printf 'Error: APT would remove a non-kernel package: %s\n' "$package" >&2
                return 1
                ;;
        esac
    done < <(printf '%s\n' "$removal_plan" | awk '$1 == "Remv" { print $2 }')

    printf '\nWARNING: removing the running kernel can break further module loading before reboot.\n'
    printf 'WARNING: the old kernel will no longer be available as a boot fallback.\n'
    confirm "Remove $old_package and the kernel packages shown above?" || return 0
    as_root apt-get remove "$old_package" || return 1
    as_root update-grub || return 1
    if [[ ! -s "/boot/vmlinuz-$target_release" ||
          ! -s "/boot/initrd.img-$target_release" ||
          ! -d "/lib/modules/$target_release" ]] ||
        ! grub_has_kernel "$target_release"; then
        printf 'Error: post-removal verification failed; repair the target kernel before rebooting.\n' >&2
        return 1
    fi
    if [[ -e "/boot/vmlinuz-$running_release" ]]; then
        printf 'Error: the old kernel image still exists; review the removal before rebooting.\n' >&2
        return 1
    fi
    printf 'Kernel replacement completed. Reboot to run %s (%s).\n' "$target_release" "$target_pages"
    printf 'Until reboot, the running kernel remains %s.\n' "$running_release"
    if confirm "Reboot now?"; then
        require_root_access || return 1
        as_root systemctl reboot || return 1
    else
        printf 'Reboot postponed. Reboot manually for the kernel switch to take effect.\n'
    fi
}

kernel_menu() {
    local page_size
    show_running_kernel || return 1
    page_size=$(getconf PAGESIZE) || return 1
    case "$page_size" in
        4096) switch_kernel "$KERNEL_64K_PACKAGE" "64K" ;;
        65536) switch_kernel "$KERNEL_4K_PACKAGE" "4K" ;;
        *)
            printf 'Error: the running kernel does not use a supported 4K/64K page size.\n' >&2
            return 1
            ;;
    esac
}

ppa_is_imported() {
    local source_directory="${1:-/etc/apt}"
    local file
    local -a source_files=()
    for file in "$source_directory/sources.list" \
        "$source_directory"/sources.list.d/*.list \
        "$source_directory"/sources.list.d/*.sources; do
        [[ -f "$file" ]] || continue
        if [[ ! -r "$file" ]]; then
            printf 'Error: cannot read APT source file: %s\n' "$file" >&2
            return 2
        fi
        source_files+=("$file")
    done
    (( ${#source_files[@]} > 0 )) || return 1

    awk -v ppa="$PPA" "$PPA_URI_AWK"'
        function check_stanza(uris, count, i) {
            if (tolower(values["enabled"]) != "no" &&
                (" " values["types"] " ") ~ /[ \t]deb[ \t]/) {
                count = split(values["uris"], uris, /[ \t]+/)
                for (i = 1; i <= count; i++)
                    if (matches_uri(uris[i])) found = 1
            }
            for (i in values) delete values[i]
            field = ""
        }
        FNR == 1 {
            check_stanza()
            deb822 = FILENAME ~ /\.sources$/
        }
        {
            sub(/\r$/, "")
            if ($0 ~ /^[ \t]*#/) next
            if (!deb822) {
                if ($1 != "deb") next
                i = 2
                if ($i ~ /^\[/) {
                    while (i <= NF && $i !~ /\]$/) i++
                    i++
                }
                if (i <= NF && matches_uri($i)) found = 1
                next
            }
            if ($0 ~ /^[ \t]*$/) {
                check_stanza()
                next
            }
            if ($0 ~ /^[ \t]/) {
                value = $0
                sub(/^[ \t]+/, "", value)
                sub(/[ \t]+$/, "", value)
                if (field != "") values[field] = values[field] " " value
            } else if (index($0, ":") > 0) {
                field = tolower(substr($0, 1, index($0, ":") - 1))
                value = substr($0, index($0, ":") + 1)
                sub(/^[ \t]+/, "", value)
                sub(/[ \t]+$/, "", value)
                values[field] = value
            }
        }
        END {
            check_stanza()
            exit !found
        }
    ' "${source_files[@]}"
}

package_metadata() {
    local policy repositories=""
    policy=$(apt-cache policy "$1") || return 2
    if [[ "${2:-state}" == "ubuntu" || "${2:-state}" == "source" ]]; then
        repositories=$(apt-cache policy) || return 2
    fi
    if [[ -z "$policy" ]]; then
        case "${2:-state}" in
            state) printf 'none\tnone\tUnknown\tUnknown\n' ;;
            ppa|ubuntu) return 1 ;;
            source) printf 'Unknown\n' ;;
        esac
        return 0
    fi
    printf '%s\n' "$policy" |
        awk -v ppa="$PPA" -v mode="${2:-state}" -v requested="${3:-}" \
            -v repositories="$repositories" "$PPA_URI_AWK"'
            BEGIN {
                count = split(repositories, lines, "\n")
                for (i = 1; i <= count; i++) {
                    line = lines[i]
                    sub(/^[ \t]+/, "", line)
                    split(line, fields, /[ \t]+/)
                    if (fields[1] ~ /^[0-9]+$/ && fields[2] ~ /^(https?|file):/)
                        key = fields[2] SUBSEP fields[3]
                    else if (fields[1] == "release" &&
                             line ~ /(^|[ ,])o=Ubuntu(,|$)/)
                        official[key] = 1
                }
            }
            function source_label(version) {
                if (kunpeng[version] && other[version]) return "Multiple repositories"
                if (ubuntu[version] && nonubuntu[version]) return "Multiple repositories"
                if (kunpeng[version]) return "Kunpeng PPA"
                if (ubuntu[version]) return "Ubuntu repository"
                if (other[version]) return "System/other repository"
                return "Unknown"
            }
            $1 == "Installed:" { installed = $2; saw_installed = 1; next }
            $1 == "Candidate:" { candidate = $2; saw_candidate = 1; next }
            $1 == "***" && $3 ~ /^[0-9]+$/ { version = $2; next }
            NF == 2 && $2 ~ /^[0-9]+$/ { version = $1; next }
            $1 ~ /^[0-9]+$/ && $2 ~ /^(https?|file):/ {
                if (matches_uri($2)) kunpeng[version] = 1
                else other[version] = 1
                if (official[$2 SUBSEP $3]) ubuntu[version] = 1
                else nonubuntu[version] = 1
            }
            END {
                if (!saw_installed || !saw_candidate) exit 2
                if (mode == "ppa" || mode == "ubuntu") {
                    for (version in other) available[version] = 1
                    for (version in kunpeng) available[version] = 1
                    for (version in available) {
                        if ((mode == "ppa" && kunpeng[version]) ||
                            (mode == "ubuntu" && ubuntu[version])) {
                            print version
                            found = 1
                        }
                    }
                    exit !found
                }
                if (mode == "source") {
                    print source_label(requested)
                    exit
                }
                if (installed == "(none)") installed = "none"
                if (candidate == "(none)") candidate = "none"
                printf "%s\t%s\t%s\t%s\n", installed, candidate,
                    source_label(installed), source_label(candidate)
            }
        '
}

latest_repository_version() {
    local versions version newest="" result
    local mode="${2:-ppa}"
    if versions=$(package_metadata "$1" "$mode"); then
        while read -r version; do
            if [[ -z "$newest" ]]; then
                newest="$version"
            elif dpkg --compare-versions "$version" gt "$newest"; then
                newest="$version"
            else
                result=$?
                (( result == 1 )) || return 2
            fi
        done <<< "$versions"
        printf '%s\n' "$newest"
    else
        result=$?
        if (( result == 1 )); then
            printf 'Error: no %s version of %s is available in the cached indexes.\n' "$mode" "$1" >&2
        else
            printf 'Error: cannot read APT metadata for %s.\n' "$1" >&2
        fi
        return 1
    fi
}

show_package_status() {
    local metadata installed candidate installed_source candidate_source
    metadata=$(package_metadata "$1") || {
        printf 'Error: cannot read APT metadata for %s.\n' "$1" >&2
        return 1
    }
    IFS=$'\t' read -r installed candidate installed_source candidate_source <<< "$metadata"
    if [[ "$installed" == "none" ]]; then
        printf '%s: Not installed\n' "$1"
    else
        printf '%s: %s | Available from: %s\n' "$1" "$installed" "$installed_source"
    fi
    printf '  APT candidate: %s | Available from: %s\n' "$candidate" "$candidate_source"
}

show_software_status() {
    local package
    printf 'Software status uses cached APT indexes.\n'
    for package in "$QEMU_PACKAGE" "${LIBVIRT_PACKAGES[@]}" "$OPENSSL_PACKAGE" \
        "$RASDAEMON_PACKAGE" "$HIKPTOOL_PACKAGE"; do
        show_package_status "$package" || return 1
    done
}

manage_packages() {
    local label="$1" source_mode="$2"
    shift 2
    local package metadata installed candidate installed_source candidate_source
    local target target_source result needs_change=0 downgrade=0 plan
    local -a specifications=() targets=()
    printf '\n--- %s ---\n' "$label"
    for package in "$@"; do
        show_package_status "$package" || return 1
    done
    if [[ "$source_mode" == "kunpeng" ]]; then
        confirm "Install or update $label from the Kunpeng PPA?" || return 0
    elif [[ "$source_mode" == "ubuntu" ]]; then
        confirm "Switch $label to the Ubuntu official version?" || return 0
    else
        confirm "Install or update $label?" || return 0
    fi
    require_arm64 || return 1
    require_root_access || return 1
    if [[ "$source_mode" == "kunpeng" ]]; then
        require_kunpeng_ppa || return 1
    fi
    printf 'Refreshing APT indexes before selecting package versions...\n'
    refresh_apt_indexes || return 1
    if [[ "$label" == "OpenSSL" && "$source_mode" != "default" ]]; then
        local repository_mode="ppa" details dependencies dependency
        [[ "$source_mode" == "ubuntu" ]] && repository_mode="ubuntu"
        target=$(latest_repository_version "$OPENSSL_PACKAGE" "$repository_mode") || return 1
        details=$(apt-cache show "$OPENSSL_PACKAGE=$target") || return 1
        dependencies=$(printf '%s\n' "$details" | awk '
            /^Depends:/ {
                count = split(substr($0, 9), groups, ",")
                for (i = 1; i <= count; i++) {
                    item = groups[i]
                    sub(/^[ \t]+/, "", item)
                    split(item, words, /[ \t]+/)
                    sub(/:.*/, "", words[1])
                    if (words[1] ~ /^libssl[0-9][a-zA-Z0-9.+-]*$/) {
                        if (item ~ /\|/) exit 1
                        if (!seen[words[1]]++) print words[1]
                    }
                }
            }
        ') || {
            printf 'Error: ambiguous OpenSSL library dependencies.\n' >&2
            return 1
        }
        while read -r dependency; do
            [[ -n "$dependency" ]] || continue
            set -- "$@" "$dependency"
            show_package_status "$dependency" || return 1
        done <<< "$dependencies"
    fi
    for package in "$@"; do
        metadata=$(package_metadata "$package") || return 1
        IFS=$'\t' read -r installed candidate installed_source candidate_source <<< "$metadata"
        if [[ "$source_mode" == "kunpeng" || "$source_mode" == "ubuntu" ]]; then
            local mode="ppa" expected_source="Kunpeng PPA"
            if [[ "$source_mode" == "ubuntu" ]]; then
                mode="ubuntu"
                expected_source="Ubuntu repository"
            fi
            target=$(latest_repository_version "$package" "$mode") || return 1
            target_source=$(package_metadata "$package" source "$target") || return 1
            if [[ "$target_source" != "$expected_source" ]]; then
                printf 'Error: %s version %s cannot be uniquely selected from %s.\n' "$package" "$target" "$expected_source" >&2
                return 1
            fi
        else
            target="$candidate"
            target_source="$candidate_source"
        fi
        if [[ "$target" == "none" ]]; then
            printf 'Error: %s has no APT candidate. Check repositories and refresh indexes.\n' "$package" >&2
            return 1
        fi
        specifications+=("$package=$target")
        targets+=("$target")
        printf '  Selected target: %s | Available from: %s\n' "$target" "$target_source"
        if [[ "$installed" != "$target" ]]; then
            needs_change=1
            if [[ "$installed" != "none" ]]; then
                if dpkg --compare-versions "$target" lt "$installed"; then
                    downgrade=1
                else
                    result=$?
                    (( result == 1 )) || return 1
                fi
            fi
        fi
    done
    if (( needs_change == 0 )); then
        printf '%s is already at the selected version. No change is needed.\n' "$label"
        return 0
    fi
    if (( downgrade )); then
        printf 'WARNING: the selected target includes a package downgrade.\n'
    fi
    if [[ "$label" == "OpenSSL" && "$source_mode" != "default" ]]; then
        printf 'WARNING: switching OpenSSL also selects matching-repository libssl dependencies and may affect services.\n'
        printf 'Repository preferences are not changed; later upgrades may select another repository again.\n'
    fi
    printf 'APT may update dependencies and restart affected services.\n'
    local -a options=(--no-remove)
    if (( downgrade )); then
        options+=(--allow-downgrades)
    fi
    plan=$(apt-get --simulate "${options[@]}" install "${specifications[@]}") || return 1
    printf '\n%s\n' "$plan"
    confirm "Apply the displayed $label installation/update plan?" || return 0
    require_root_access || return 1
    as_root apt-get "${options[@]}" install "${specifications[@]}" || return 1

    local index=0
    for package in "$@"; do
        metadata=$(package_metadata "$package") || return 1
        IFS=$'\t' read -r installed candidate installed_source candidate_source <<< "$metadata"
        if [[ "$installed" != "${targets[index]}" ]]; then
            printf 'Error: %s is not installed at the requested version after APT completed.\n' "$package" >&2
            return 1
        fi
        (( index += 1 ))
    done
    printf '%s installation/update completed.\n' "$label"
}

openssl_menu() {
    local choice
    printf '\nSwitch OpenSSL package source: Ubuntu official repositories or Kunpeng PPA.\n'
    printf 'This selects package versions; it does not change global APT source settings.\n'
    show_package_status "$OPENSSL_PACKAGE" || return 1
    printf '%s\n' \
        '1. Switch to Kunpeng PPA OpenSSL' \
        '2. Switch back to Ubuntu official OpenSSL' \
        '0. Back'
    read -r -p "Select an OpenSSL source: " choice || return 0
    case "$choice" in
        1) manage_packages "OpenSSL" kunpeng "$OPENSSL_PACKAGE" ;;
        2) manage_packages "OpenSSL" ubuntu "$OPENSSL_PACKAGE" ;;
        0) return 0 ;;
        *) printf 'Invalid OpenSSL option.\n' >&2; return 1 ;;
    esac
}

import_ppa() {
    printf '\nKunpeng PPA: ppa:%s\n' "$PPA"
    printf 'This modifies APT sources and may install software-properties-common.\n'
    printf 'This public PPA does not require Launchpad login or a subscription.\n'
    confirm "Continue?" || return 0

    require_root_access || return 1

    if ! command -v add-apt-repository >/dev/null 2>&1; then
        refresh_apt_indexes || return 1
        as_root apt-get install software-properties-common || return 1
    fi

    as_root add-apt-repository --no-update "ppa:$PPA" || return 1
    refresh_apt_indexes || return 1
    printf 'PPA imported and package indexes refreshed successfully.\n'
    printf '%s\n' \
        'Available software from the Kunpeng stable PPA: qemu, libvirt, rasdaemon, openssl, hikptool.'
    printf '\n%s\n' \
        'Optional packages are also available from the Kunpeng GCC PPA:' \
        'https://launchpad.net/~huawei-kunpeng-ubuntu/+archive/ubuntu/kunpeng-gcc' \
        'You may choose to add that PPA and install its packages manually.' \
        'This script does not support adding that PPA or managing its optional packages.'
}

show_help() {
    printf '\n'
    printf '%s\n' \
        'Run: bash kunpeng-setup.sh' \
        'Read-only preview: bash kunpeng-setup.sh --preview' \
        'Preview blocks privileged actions, including package installation and removal.' \
        'Software installation and kernel switching require native ARM64 Ubuntu.' \
        'Preview skips the native ARM64 check but still blocks every system-changing action.' \
        'Foreign arm64 architecture on an amd64 system is suitable for metadata inspection only.' \
        "Configured PPA: ppa:$PPA" \
        'PPA page: https://launchpad.net/~huawei-kunpeng-ubuntu/+archive/ubuntu/kunpeng-stable' \
        'Available software from the Kunpeng stable PPA: qemu, libvirt, rasdaemon, openssl, hikptool.' \
        'All software installation/update entries select versions from the Kunpeng stable PPA.' \
        'The Kunpeng stable PPA is public and does not require Launchpad login.' \
        'Imported means an enabled binary APT source exists for this PPA.' \
        'Imported does not mean that the PPA is currently accessible or its indexes are up to date.' \
        'This status does not verify credentials, network access, or package availability.' \
        'Do not paste private credentials into this script or commit them to Git.' \
        'Kernel switching selects the opposite page size using the stable PPA kernel metapackages.' \
        'Kernel versions and releases are resolved from APT metadata after refreshing indexes.' \
        'Kernel replacement installs the target and removes the old image package.' \
        'Other packages are removed only if APT requires them and the removal is confirmed.' \
        'Only a standard GRUB default with no third kernel is supported for replacement.' \
        'Installed kernels may differ from the running kernel until the next reboot.' \
        'QEMU, libvirt, OpenSSL, rasdaemon, and hikptool use explicit Kunpeng PPA package versions.' \
        'A newer Ubuntu version will not override the selected PPA version for these operations.' \
        'Software Configuration offers separate OpenSSL source switching: Ubuntu or Kunpeng.' \
        'Ubuntu versions are identified by the APT Release Origin Ubuntu, including official mirrors.' \
        'OpenSSL switching also selects required libssl packages from the chosen repository.' \
        'OpenSSL source selection is not pinned; future upgrades may select the PPA again.' \
        'Package source labels describe available repositories, not historical install provenance.' \
        'APT indexes are refreshed after installation/update is requested, before selecting versions.' \
        'Any repository download error stops installation; cached indexes are not used as a fallback.' \
        'Fix HTTP 403 or other repository errors before retrying; no alternate PPA is selected.' \
        'Package updates show an APT simulation and require confirmation.' \
        'Software installation refuses plans that remove existing packages.' \
        'Software installation does not modify user group membership or customize services.' \
        'Kernel switching offers a reboot only after successful replacement and explicit confirmation.' \
        'No automatic system upgrades are performed.'
}

show_info() {
    printf '\n'
    printf 'Ubuntu: %s\n' "$PRETTY_NAME"
    printf 'Architecture: '
    dpkg --print-architecture || return 1
    show_running_kernel || return 1
    printf 'Configured PPA: ppa:%s\n' "$PPA"
    show_software_status || return 1
}

show_menu() {
    local status color result kernel_status kernel_line border ppa_label width=44
    local openssl_metadata openssl_version openssl_source openssl_status openssl_line
    local source_title='[ Software Sources: Ubuntu Official / Kunpeng PPA ]'
    if ppa_is_imported; then
        status="Imported"
        color=$'\033[32m'
    else
        result=$?
        if (( result != 1 )); then
            printf 'Error: failed to detect PPA status.\n' >&2
            return 1
        fi
        status="Not imported"
        color=$'\033[31m'
    fi

    printf '\n'
    if (( PREVIEW_MODE )); then
        printf '=== READ-ONLY PREVIEW: system-changing actions are blocked ===\n'
        printf 'Native ARM64 architecture check is skipped in preview mode.\n'
    fi
    kernel_status=$(show_running_kernel) || return 1
    kernel_status="${kernel_status#Running kernel: }"
    kernel_status="${kernel_status/ | Page size: / / }"
    kernel_line="2. Switch to 4K/64K kernel [Now using: $kernel_status]"
    (( ${#kernel_line} <= width )) || width=${#kernel_line}
    openssl_metadata=$(package_metadata "$OPENSSL_PACKAGE") || {
        printf 'Error: cannot read OpenSSL package status.\n' >&2
        return 1
    }
    IFS=$'\t' read -r openssl_version _ <<< "$openssl_metadata"
    if [[ "$openssl_version" == "none" ]]; then
        openssl_status="Not installed"
    else
        openssl_source=$(package_metadata "$OPENSSL_PACKAGE" source "$openssl_version") || {
            printf 'Error: cannot determine the OpenSSL package source.\n' >&2
            return 1
        }
        [[ "$openssl_source" != "Ubuntu repository" ]] || openssl_source="Ubuntu Official"
        openssl_status="$openssl_source / $openssl_version"
    fi
    openssl_line="8. Switch OpenSSL source [Now: $openssl_status]"
    (( ${#openssl_line} <= width )) || width=${#openssl_line}
    (( ${#source_title} <= width )) || width=${#source_title}
    printf -v border '%*s' "$((width + 2))" ''
    border="+${border// /-}+"
    printf '%s\n' "$border"
    printf '| %-*s |\n' "$width" 'Kunpeng 950 Ubuntu Server Setup'
    printf '%s\n' "$border"
    printf '| %-*s |\n' "$width" '[ Repositories ]'
    ppa_label="1. Import Kunpeng PPA [$status]"
    printf '| 1. Import Kunpeng PPA [%s%s\033[0m]%*s |\n' \
        "$color" "$status" "$((width - ${#ppa_label}))" ''
    printf '%s\n' "$border"
    printf '| %-*s |\n' "$width" '[ Kernel ]' "$width" "$kernel_line"
    printf '%s\n' "$border"
    printf '| %-*s |\n' \
        "$width" \
        '[ Software - Kunpeng PPA ]' \
        "$width" \
        '3. Install/update QEMU' \
        "$width" \
        '4. Install/update libvirt' \
        "$width" \
        '5. Install/update OpenSSL' \
        "$width" \
        '6. Install/update rasdaemon' \
        "$width" \
        '7. Install/update hikptool'
    printf '%s\n' "$border"
    printf '| %-*s |\n' \
        "$width" \
        "$source_title" \
        "$width" \
        "$openssl_line"
    printf '%s\n' "$border"
    printf '| %-*s |\n' \
        "$width" \
        '[ Help & System Information ]' \
        "$width" \
        '9. Help' \
        "$width" \
        '10. System info' \
        "$width" \
        '0. Exit'
    printf '%s\n' "$border"
}

main() {
    case "$#" in
        0) ;;
        1)
            if [[ "$1" != "--preview" ]]; then
                printf 'Usage: bash kunpeng-setup.sh [--preview]\n' >&2
                return 1
            fi
            PREVIEW_MODE=1
            ;;
        *)
            printf 'Usage: bash kunpeng-setup.sh [--preview]\n' >&2
            return 1
            ;;
    esac
    if [[ ! -r /etc/os-release ]]; then
        printf 'Error: cannot read /etc/os-release.\n' >&2
        return 1
    fi
    source /etc/os-release
    if [[ "${ID:-}" != "ubuntu" ]]; then
        printf 'Error: this script supports Ubuntu only.\n' >&2
        return 1
    fi
    if [[ ! -t 0 || ! -t 1 ]]; then
        printf 'Error: run this menu in an interactive terminal.\n' >&2
        return 1
    fi

    local choice
    while true; do
        show_menu || return 1
        read -r -p "Select an option: " choice || return 0
        case "$choice" in
            1)
                if ! import_ppa; then
                    printf 'Error: PPA import failed; earlier APT changes may remain.\n' >&2
                fi
                ;;
            2)
                if ! kernel_menu; then
                    printf 'Error: kernel replacement did not complete; review the output before rebooting.\n' >&2
                fi
                ;;
            3)
                manage_packages "QEMU" kunpeng "$QEMU_PACKAGE" ||
                    printf 'Error: QEMU installation/update did not complete.\n' >&2
                ;;
            4)
                manage_packages "libvirt" kunpeng "${LIBVIRT_PACKAGES[@]}" ||
                    printf 'Error: libvirt installation/update did not complete.\n' >&2
                ;;
            5)
                manage_packages "OpenSSL" kunpeng "$OPENSSL_PACKAGE" ||
                    printf 'Error: OpenSSL installation/update did not complete.\n' >&2
                ;;
            6)
                manage_packages "rasdaemon" kunpeng "$RASDAEMON_PACKAGE" ||
                    printf 'Error: rasdaemon installation/update did not complete.\n' >&2
                ;;
            7)
                manage_packages "hikptool" kunpeng "$HIKPTOOL_PACKAGE" ||
                    printf 'Error: hikptool installation/update did not complete.\n' >&2
                ;;
            8)
                openssl_menu ||
                    printf 'Error: OpenSSL source switching did not complete.\n' >&2
                ;;
            9) show_help ;;
            10)
                if ! show_info; then
                    printf 'Error: failed to read system information.\n' >&2
                fi
                ;;
            0) return 0 ;;
            *) printf 'Invalid option: select one of the menu numbers.\n' >&2 ;;
        esac
        read -r -p "Press Enter to return to the menu..." choice || return 0
    done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
