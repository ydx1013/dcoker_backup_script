#!/bin/bash

# Docker容器备份工具 - AI友好统一CLI入口
# 作者: Docker Backup Tool
# 版本: 1.0
# 描述: 为 OpenCLI 和 AI Agent 提供稳定、非交互式的命令封装

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

DEFAULT_BACKUP_DIR="/tmp/docker-backups"

show_usage() {
    cat << EOF
用法: $0 <命令> [选项]

命令:
    backup              备份容器，参数透传给 docker-backup.sh
    restore             恢复容器，参数透传给 docker-restore.sh
    dry-run             恢复预检，不执行恢复操作
    verify              校验备份完整性
    cleanup             清理旧备份
    list-backups        列出可恢复备份
    status              检查 Docker 和工具状态
    serve               启动 HTTP 下载服务
    stop-server         停止 HTTP 下载服务
    download-restore    下载并恢复备份
    opencli-register    注册到 OpenCLI

AI调用示例:
    $0 status
    $0 list-backups --json
    $0 backup -a --exclude-images
    $0 verify /tmp/docker-backups/nginx_20260516_120000
    $0 dry-run /tmp/docker-backups/nginx_20260516_120000
    $0 restore --no-start /tmp/docker-backups/nginx_20260516_120000
    $0 cleanup -f 30
    $0 opencli-register

说明:
    破坏性操作保持原脚本安全语义：覆盖恢复需要 --force，清理跳过确认需要 -f。
    list-backups 和 status 支持 --json，便于 AI 解析。

EOF
}

json_escape() {
    local value="$1"
    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import json,sys; print(json.dumps(sys.argv[1], ensure_ascii=False))' "$value"
    elif command -v python >/dev/null 2>&1; then
        python -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$value"
    else
        printf '"%s"' "${value//\"/\\\"}"
    fi
}

ensure_script() {
    local script="$1"
    if [[ ! -x "${SCRIPT_DIR}/${script}" ]]; then
        log_error "缺少可执行脚本: ${SCRIPT_DIR}/${script}"
        exit 1
    fi
}

run_backup() {
    ensure_script "docker-backup.sh"
    exec "${SCRIPT_DIR}/docker-backup.sh" "$@"
}

run_restore() {
    ensure_script "docker-restore.sh"
    exec "${SCRIPT_DIR}/docker-restore.sh" "$@"
}

run_dry_run() {
    ensure_script "docker-restore.sh"
    exec "${SCRIPT_DIR}/docker-restore.sh" --dry-run "$@"
}

run_verify() {
    ensure_script "docker-verify.sh"
    exec "${SCRIPT_DIR}/docker-verify.sh" "$@"
}

run_cleanup() {
    ensure_script "docker-cleanup.sh"
    exec "${SCRIPT_DIR}/docker-cleanup.sh" "$@"
}

run_serve() {
    ensure_script "install.sh"
    exec "${SCRIPT_DIR}/install.sh" --start-http "$@"
}

run_stop_server() {
    ensure_script "install.sh"
    exec "${SCRIPT_DIR}/install.sh" --stop-http "$@"
}

run_download_restore() {
    ensure_script "install.sh"
    exec "${SCRIPT_DIR}/install.sh" --download-restore "$@"
}

list_backups() {
    local backup_dir="$DEFAULT_BACKUP_DIR"
    local json=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json)
                json=true
                shift
                ;;
            -d|--directory)
                backup_dir="$2"
                shift 2
                ;;
            -h|--help)
                cat << EOF
用法: $0 list-backups [选项]

选项:
    -d, --directory DIR     指定备份目录 (默认: ${DEFAULT_BACKUP_DIR})
    --json                  输出 JSON 格式

EOF
                return 0
                ;;
            *)
                log_error "未知选项: $1"
                return 1
                ;;
        esac
    done

    if [[ "$json" == true ]]; then
        printf '{"backup_dir":%s,"backups":[' "$(json_escape "$backup_dir")"
    else
        echo "备份目录: $backup_dir"
    fi

    if [[ ! -d "$backup_dir" ]]; then
        if [[ "$json" == true ]]; then
            printf '],"count":0,"exists":false}\n'
        else
            log_warning "备份目录不存在: $backup_dir"
        fi
        return 0
    fi

    local count=0
    local first=true
    while IFS= read -r -d '' backup; do
        [[ -d "$backup" ]] || continue
        [[ -f "$backup/config/container_inspect.json" ]] || continue

        local name
        local size
        local modified
        name=$(basename "$backup")
        size=$(du -sh "$backup" 2>/dev/null | cut -f1 || echo "unknown")
        modified=$(date -r "$backup" +%Y-%m-%dT%H:%M:%S%z 2>/dev/null || echo "unknown")
        count=$((count + 1))

        if [[ "$json" == true ]]; then
            if [[ "$first" == true ]]; then
                first=false
            else
                printf ','
            fi
            printf '{"name":%s,"path":%s,"size":%s,"modified":%s}' \
                "$(json_escape "$name")" \
                "$(json_escape "$backup")" \
                "$(json_escape "$size")" \
                "$(json_escape "$modified")"
        else
            echo "${count}) ${name}"
            echo "   路径: $backup"
            echo "   大小: $size"
            echo "   修改时间: $modified"
        fi
    done < <(find "$backup_dir" -maxdepth 1 -type d -name "*_*" -print0 2>/dev/null)

    if [[ "$json" == true ]]; then
        printf '],"count":%s,"exists":true}\n' "$count"
    elif [[ $count -eq 0 ]]; then
        log_warning "未找到可恢复备份"
    fi
}

show_status() {
    local json=false
    if [[ ${1:-} == "--json" ]]; then
        json=true
    elif [[ ${1:-} == "-h" || ${1:-} == "--help" ]]; then
        cat << EOF
用法: $0 status [--json]

检查 Docker 服务和备份工具状态。

EOF
        return 0
    elif [[ $# -gt 0 ]]; then
        log_error "未知选项: $1"
        return 1
    fi

    local docker_bin="false"
    local docker_running="false"
    local docker_version="unknown"
    local jq_bin="false"
    local opencli_bin="false"

    command -v docker >/dev/null 2>&1 && docker_bin="true"
    command -v jq >/dev/null 2>&1 && jq_bin="true"
    command -v opencli >/dev/null 2>&1 && opencli_bin="true"

    if [[ "$docker_bin" == true ]] && docker info >/dev/null 2>&1; then
        docker_running="true"
        docker_version=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "unknown")
    fi

    if [[ "$json" == true ]]; then
        printf '{"docker":{"installed":%s,"running":%s,"version":%s},' \
            "$docker_bin" "$docker_running" "$(json_escape "$docker_version")"
        printf '"tools":{"jq":%s,"opencli":%s},' "$jq_bin" "$opencli_bin"
        printf '"paths":{"script_dir":%s,"default_backup_dir":%s}}\n' \
            "$(json_escape "$SCRIPT_DIR")" "$(json_escape "$DEFAULT_BACKUP_DIR")"
        return 0
    fi

    echo "Docker已安装: $docker_bin"
    echo "Docker运行中: $docker_running"
    echo "Docker版本: $docker_version"
    echo "jq可用: $jq_bin"
    echo "OpenCLI可用: $opencli_bin"
    echo "脚本目录: $SCRIPT_DIR"
    echo "默认备份目录: $DEFAULT_BACKUP_DIR"
}

register_opencli() {
    if ! command -v opencli >/dev/null 2>&1; then
        log_error "未找到 opencli 命令，请先安装 OpenCLI"
        return 1
    fi

    opencli register docker-backup-cli \
        --binary docker-backup-cli \
        --desc "Docker backup and restore CLI for AI agents"
}

main() {
    local command="${1:-}"
    if [[ -z "$command" || "$command" == "-h" || "$command" == "--help" ]]; then
        show_usage
        return 0
    fi
    shift

    case "$command" in
        backup)
            run_backup "$@"
            ;;
        restore)
            run_restore "$@"
            ;;
        dry-run)
            run_dry_run "$@"
            ;;
        verify)
            run_verify "$@"
            ;;
        cleanup)
            run_cleanup "$@"
            ;;
        list-backups)
            list_backups "$@"
            ;;
        status)
            show_status "$@"
            ;;
        serve)
            run_serve "$@"
            ;;
        stop-server)
            run_stop_server "$@"
            ;;
        download-restore)
            run_download_restore "$@"
            ;;
        opencli-register)
            register_opencli "$@"
            ;;
        *)
            log_error "未知命令: $command"
            show_usage
            return 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
