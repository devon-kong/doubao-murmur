#!/bin/bash
# setup-permissions.sh - Post-install permission setup for Doubao Murmur
# Run on the host after installing. Safe to re-run.

set -e

echo "=== Doubao Murmur Permission Setup ==="
echo ""

# Distro-neutral install hint for the two optional host tools.
install_hint() {
    if command -v pacman &>/dev/null; then
        echo "sudo pacman -S $*"
    elif command -v rpm-ostree &>/dev/null; then
        echo "sudo rpm-ostree install $* (needs a reboot)"
    elif command -v dnf &>/dev/null; then
        echo "sudo dnf install $*"
    elif command -v apt &>/dev/null; then
        echo "sudo apt install $*"
    else
        echo "install: $*"
    fi
}

# 1. input group. Required by the evdev key listener, which is the only
#    global-hotkey backend that works on a Wayland session.
if id -nG | grep -qw input; then
    echo "[1/3] Already in the 'input' group. OK"
else
    echo "[1/3] Adding $USER to the 'input' group..."
    sudo usermod -aG input "$USER"
    echo "  -> Log out and back in for this to take effect."
fi

# 2. ydotool. Only needed for auto-paste on Wayland; X11 uses xdotool.
echo ""
if command -v ydotoold &>/dev/null; then
    echo "[2/3] Enabling ydotoold (auto-paste on Wayland)..."
    sudo systemctl enable --now ydotoold || \
        echo "  -> Could not enable ydotoold; auto-paste may not work."
else
    echo "[2/3] ydotoold not found."
    echo "  -> On Wayland, auto-paste needs it: $(install_hint ydotool)"
    echo "  -> Without it text is still copied to the clipboard; paste with Ctrl+V."
fi

# 3. Host tools used for clipboard and paste.
echo ""
echo "[3/3] Checking host tools..."
for tool in wl-copy xdotool; do
    if command -v "$tool" &>/dev/null; then
        echo "  $tool: found"
    else
        echo "  $tool: missing -> $(install_hint "$tool")"
    fi
done

# 4. Flatpak device access. Bundles after v1.5.0 ship --device=input in the
#    manifest, so this is only needed for older installs.
if flatpak list 2>/dev/null | grep -q com.doubao.Murmur; then
    echo ""
    echo "Granting the Flatpak /dev/input access (no-op on newer bundles)..."
    flatpak override --user --device=input com.doubao.Murmur
    echo "  -> Done."
fi

echo ""
echo "=== Setup complete ==="
if ! id -nG | grep -qw input; then
    echo "IMPORTANT: log out and back in for the 'input' group to take effect."
fi
echo ""
echo "Launch with: flatpak run com.doubao.Murmur"
echo "Or:          cd linux && ./run.sh"
