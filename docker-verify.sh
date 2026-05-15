#!/bin/bash

# Docker容器备份校验脚本
# 作者: Docker Backup Tool
# 版本: 1.0
# 描述: 校验备份目录 manifest.json、checksums.sha256 和关键目录结构

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/backup-utils.sh" ]]; then
    source "${SCRIPT_DIR}/backup-utils.sh"
else
    log_info() { echo "[INFO] $1"; }
    log_error() { echo "[ERROR] $1" >&2; }
    log_success() { echo "[SUCCESS] $1"; }
    log_warning() { echo "[WARNING] $1" >&2; }
fi

show_usage() {
    cat << EOF
用法: $0 <备份目录路径>

功能:
    校验备份目录结构、manifest.json 格式和 checksums.sha256 文件完整性。

示例:
    $0 /var/backups/docker/nginx_20260516_120000

EOF
}

calculate_file_sha256() {
    local file="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$file" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$file" | awk '{print $1}'
    else
        log_error "缺少 sha256sum 或 shasum，无法校验文件哈希"
        return 1
    fi
}

verify_json() {
    local file="$1"
    if [[ ! -f "$file" ]]; then
        log_error "缺少文件: $file"
        return 1
    fi

    if command -v jq >/dev/null 2>&1; then
        jq empty "$file" >/dev/null 2>&1
    elif command -v python3 >/dev/null 2>&1; then
        python3 -m json.tool "$file" >/dev/null 2>&1
    elif command -v python >/dev/null 2>&1; then
        python -m json.tool "$file" >/dev/null 2>&1
    else
        log_warning "缺少 jq 或 python，跳过 JSON 格式校验"
        return 0
    fi
}

verify_structure() {
    local backup_dir="$1"
    local failed=0

    if [[ ! -d "$backup_dir" ]]; then
        log_error "备份目录不存在: $backup_dir"
        return 1
    fi

    if [[ ! -d "$backup_dir/config" ]]; then
        log_error "缺少 config 目录"
        failed=1
    fi

    if [[ ! -f "$backup_dir/config/container_inspect.json" ]]; then
        log_error "缺少 config/container_inspect.json"
        failed=1
    fi

    if [[ ! -f "$backup_dir/restore.sh" ]]; then
        log_warning "缺少 restore.sh，仍可尝试使用 docker-restore 恢复"
    fi

    return $failed
}

verify_checksums() {
    local backup_dir="$1"
    local checksum_file="$backup_dir/checksums.sha256"
    local failed=0
    local checked=0

    if [[ ! -f "$checksum_file" ]]; then
        log_error "缺少 checksums.sha256"
        return 1
    fi

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local expected_hash="${line%%  *}"
        local relative_path="${line#*  }"
        local file="$backup_dir/$relative_path"

        if [[ ! -f "$file" ]]; then
            log_error "文件缺失: $relative_path"
            failed=1
            continue
        fi

        local actual_hash
        if ! actual_hash=$(calculate_file_sha256 "$file"); then
            return 1
        fi

        if [[ "$actual_hash" != "$expected_hash" ]]; then
            log_error "哈希不匹配: $relative_path"
            failed=1
        fi
        checked=$((checked + 1))
    done < "$checksum_file"

    log_info "已校验文件数: $checked"
    return $failed
}

main() {
    if [[ $# -eq 1 && ( "$1" == "-h" || "$1" == "--help" ) ]]; then
        show_usage
        exit 0
    fi

    if [[ $# -ne 1 ]]; then
        show_usage
        exit 1
    fi

    local backup_dir="$1"
    local manifest_file="$backup_dir/manifest.json"
    local failed=0

    log_info "开始校验备份: $backup_dir"

    verify_structure "$backup_dir" || failed=1

    if verify_json "$manifest_file"; then
        log_success "manifest.json 格式正确"
    else
        log_error "manifest.json 格式错误"
        failed=1
    fi

    if verify_checksums "$backup_dir"; then
        log_success "文件完整性校验通过"
    else
        log_error "文件完整性校验失败"
        failed=1
    fi

    if [[ $failed -eq 0 ]]; then
        log_success "备份校验通过: $backup_dir"
        exit 0
    else
        log_error "备份校验失败: $backup_dir"
        exit 1
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
