#!/bin/zsh

set -euo pipefail

label="com.doubao.murmur.mirror"
script_dir="${0:A:h}"
source_helper="${script_dir}/murmur-mirror"
source_checksum="${script_dir}/murmur-mirror.sha256"
source_plist="${script_dir}/${label}.plist"
install_dir="${HOME}/Library/Application Support/Doubao Murmur"
helper_path="${install_dir}/murmur-mirror"
launch_agents_dir="${HOME}/Library/LaunchAgents"
launch_agent_path="${launch_agents_dir}/${label}.plist"
log_dir="${HOME}/Library/Logs/Doubao Murmur"
uid="$(/usr/bin/id -u)"

finish() {
    local status=$?
    trap - EXIT
    if (( status == 0 )); then
        print "\n安装脚本执行完成。"
    else
        print -u2 "\n安装失败（状态码 ${status}）。上方输出保留了失败位置；旧文件若存在，已在备份目录中保留。"
    fi
    if [[ -t 0 ]]; then
        read -r "?按回车键关闭此窗口..."
    fi
    exit "${status}"
}
trap finish EXIT

print "正在校验安装包..."
[[ -f "${source_helper}" && -f "${source_checksum}" && -f "${source_plist}" ]]
(
    cd "${script_dir}"
    /usr/bin/shasum -a 256 -c "${source_checksum:t}"
)
/usr/bin/codesign --verify --strict "${source_helper}"
/usr/bin/plutil -lint "${source_plist}" >/dev/null

machine_arch="$(/usr/bin/uname -m)"
package_archs="$(/usr/bin/lipo -archs "${source_helper}")"
if [[ " ${package_archs} " != *" ${machine_arch} "* ]]; then
    print -u2 "安装包架构不支持此 Mac：本机=${machine_arch}，安装包=${package_archs}"
    exit 1
fi

print "正在备份既有安装（如有）..."
timestamp="$(/bin/date +%Y%m%d-%H%M%S)"
backup_dir="${install_dir}/backups/${timestamp}"
if [[ -e "${helper_path}" || -e "${launch_agent_path}" ]]; then
    /bin/mkdir -p "${backup_dir}"
    [[ ! -e "${helper_path}" ]] || /bin/cp -p "${helper_path}" "${backup_dir}/murmur-mirror"
    [[ ! -e "${launch_agent_path}" ]] || /bin/cp -p "${launch_agent_path}" "${backup_dir}/${label}.plist"
    print "备份目录：${backup_dir}"
fi

print "正在安装当前用户的 helper 与 LaunchAgent..."
/bin/mkdir -p "${install_dir}" "${launch_agents_dir}" "${log_dir}"
/usr/bin/install -m 0755 "${source_helper}" "${helper_path}"

temporary_plist="$(/usr/bin/mktemp "${launch_agents_dir}/.${label}.XXXXXX")"
/bin/cp "${source_plist}" "${temporary_plist}"
/usr/libexec/PlistBuddy -c "Set :ProgramArguments:0 ${helper_path}" "${temporary_plist}"
/usr/libexec/PlistBuddy -c "Set :StandardOutPath ${log_dir}/murmur-mirror.log" "${temporary_plist}"
/usr/libexec/PlistBuddy -c "Set :StandardErrorPath ${log_dir}/murmur-mirror.error.log" "${temporary_plist}"
/usr/bin/plutil -lint "${temporary_plist}" >/dev/null
/bin/chmod 0644 "${temporary_plist}"
/bin/mv -f "${temporary_plist}" "${launch_agent_path}"

print "正在启动 LaunchAgent..."
/bin/launchctl bootout "gui/${uid}/${label}" >/dev/null 2>&1 || true
/bin/launchctl bootstrap "gui/${uid}" "${launch_agent_path}"
/bin/launchctl kickstart -k "gui/${uid}/${label}"

health=""
for attempt in {1..20}; do
    if health="$(/usr/bin/curl --fail --silent --show-error --max-time 2 http://127.0.0.1:17771/health 2>/dev/null)"; then
        break
    fi
    /bin/sleep 0.25
done

if [[ -z "${health}" ]]; then
    print -u2 "helper 已安装，但健康检查失败。请运行 verify.command 并查看：${log_dir}/murmur-mirror.error.log"
    exit 1
fi

print "健康检查：${health}"
if [[ "${health}" == *'"accessibilityTrusted":true'* ]]; then
    print "辅助功能权限：已授权。"
else
    print "\n下一步必须在这台 Mac mini 上授权辅助功能："
    print "1. 系统设置 → 隐私与安全性 → 辅助功能。"
    print "2. 点“+”，按 Command-Shift-G，粘贴以下路径后添加并启用："
    print "   ${helper_path}"
    print "3. 再运行本包里的 verify.command。"
fi

print "\n安装位置：${helper_path}"
print "LaunchAgent：${launch_agent_path}"
print "日志目录：${log_dir}"
