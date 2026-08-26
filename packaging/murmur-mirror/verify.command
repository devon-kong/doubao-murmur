#!/bin/zsh

set -euo pipefail

label="com.doubao.murmur.mirror"
helper_path="${HOME}/Library/Application Support/Doubao Murmur/murmur-mirror"
launch_agent_path="${HOME}/Library/LaunchAgents/${label}.plist"
uid="$(/usr/bin/id -u)"

finish() {
    local status=$?
    trap - EXIT
    if (( status == 0 )); then
        print "\n验证完成。"
    else
        print -u2 "\n验证失败（状态码 ${status}）。请保留上方输出。"
    fi
    if [[ -t 0 ]]; then
        read -r "?按回车键关闭此窗口..."
    fi
    exit "${status}"
}
trap finish EXIT

[[ -x "${helper_path}" ]] || {
    print -u2 "未找到已安装 helper：${helper_path}"
    exit 1
}
[[ -f "${launch_agent_path}" ]] || {
    print -u2 "未找到 LaunchAgent：${launch_agent_path}"
    exit 1
}

print "正在验证签名、架构与 LaunchAgent..."
/usr/bin/codesign --verify --strict "${helper_path}"
print "架构：$(/usr/bin/lipo -archs "${helper_path}")"
/usr/bin/plutil -lint "${launch_agent_path}"
/bin/launchctl print "gui/${uid}/${label}" >/dev/null

health="$(/usr/bin/curl --fail --silent --show-error --max-time 3 http://127.0.0.1:17771/health)"
print "健康检查：${health}"
[[ "${health}" == *'"ok":true'* && "${health}" == *'"protocolVersion":1'* ]] || {
    print -u2 "健康响应不符合 protocolVersion 1。"
    exit 1
}

listen_state="$(/usr/sbin/lsof -nP -a -c murmur-mirror -iTCP:17771 -sTCP:LISTEN 2>/dev/null || true)"
if [[ -n "${listen_state}" ]]; then
    print "监听状态："
    print "${listen_state}"
    [[ "${listen_state}" == *"127.0.0.1:17771"* ]] || {
        print -u2 "未确认 helper 仅监听 127.0.0.1:17771。"
        exit 1
    }
fi

if [[ "${health}" == *'"accessibilityTrusted":true'* ]]; then
    print "辅助功能权限：已授权。"
else
    print -u2 "辅助功能权限：未授权。快速模式还不能投递 Command-V。"
    print -u2 "请到 系统设置 → 隐私与安全性 → 辅助功能 添加并启用："
    print -u2 "${helper_path}"
    exit 2
fi
