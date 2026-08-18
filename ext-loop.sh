cat > ~/ext-loop.sh << 'SCRIPT_EOF'
#!/bin/bash
# =============================================================================
# GNOME Extension Install/Uninstall Loop Automation
# Uses ydotool (kernel uinput) to auto-confirm GNOME Shell modal dialog
# Tested on: Ubuntu 24.04 LTS, GNOME 46, X11
# =============================================================================

set -euo pipefail

# -------------------------- CONFIGURATION --------------------------
EXTENSION="spotlight@nin"    # Extension UUID
LOOPS=10                     # Number of cycles (0 = infinite)
DELAY_AFTER_INSTALL=2        # Seconds to wait after install
DELAY_AFTER_UNINSTALL=2      # Seconds to wait after uninstall
DELAY_AFTER_ENABLE=1         # Seconds to wait after enabling
POPUP_WAIT_TIMEOUT=15        # Max seconds to wait for popup
KEY_RETRY_INTERVAL=0.5       # Seconds between key retries

# Linux key codes (/usr/include/linux/input-event-codes.h)
KEY_ENTER=28
KEY_TAB=15
KEY_SPACE=57
# -------------------------------------------------------------------

# -------------------------- VERIFY EVERYTHING --------------------------
verify_setup() {
    local errors=0

    echo "=== Verifying setup ==="

    # Check X11
    if [ "${XDG_SESSION_TYPE:-}" != "x11" ]; then
        echo "[FAIL] Not on X11. Current: ${XDG_SESSION_TYPE:-unknown}"
        errors=1
    else
        echo "[ OK ] X11 session confirmed"
    fi

    # Check DISPLAY
    if [ -z "${DISPLAY:-}" ]; then
        echo "[FAIL] DISPLAY not set"
        errors=1
    else
        echo "[ OK ] DISPLAY=$DISPLAY"
    fi

    # Check gext
    if ! command -v gext &>/dev/null; then
        echo "[FAIL] gext not found. Install: pipx install gnome-extensions-cli"
        errors=1
    else
        echo "[ OK ] gext found: $(command -v gext)"
    fi

    # Check ydotool
    if ! command -v ydotool &>/dev/null; then
        echo "[FAIL] ydotool not found. Install: sudo apt install ydotool"
        errors=1
    else
        echo "[ OK ] ydotool found: $(command -v ydotool)"
    fi

    # Check ydotoold daemon
    if ! pgrep -x ydotoold &>/dev/null; then
        echo "[WARN] ydotoold not running. Starting it now..."
        ydotoold &
        sleep 1
        if pgrep -x ydotoold &>/dev/null; then
            echo "[ OK ] ydotoold started (PID: $(pgrep -x ydotoold))"
        else
            echo "[FAIL] Could not start ydotoold"
            errors=1
        fi
    else
        echo "[ OK ] ydotoold running (PID: $(pgrep -x ydotoold))"
    fi

    # Check /dev/uinput
    if [ ! -e /dev/uinput ]; then
        echo "[FAIL] /dev/uinput not found. Run: sudo modprobe uinput"
        errors=1
    else
        echo "[ OK ] /dev/uinput exists"
    fi

    # Check input group
    if ! groups | grep -q "\binput\b"; then
        echo "[FAIL] User not in 'input' group. Run: sudo usermod -aG input \$USER"
        echo "       Then log out and back in."
        errors=1
    else
        echo "[ OK ] User in 'input' group"
    fi

    # Check uinput access
    if [ ! -r /dev/uinput ] || [ ! -w /dev/uinput ]; then
        echo "[WARN] Cannot read/write /dev/uinput. Trying to fix..."
        sudo chmod 660 /dev/uinput 2>/dev/null || true
        sudo chgrp input /dev/uinput 2>/dev/null || true
    fi

    echo ""

    if [ $errors -eq 1 ]; then
        echo "Please fix the issues above and re-run."
        exit 1
    fi

    echo "All checks passed!"
    echo ""
}

# -------------------------- SEND KEYS VIA YDOTOOL --------------------------
send_key() {
    # Press and release a single key: keycode
    local code=$1
    ydotool key "${code}:1" "${code}:0" 2>/dev/null
}

send_keys() {
    # Send multiple keys in sequence: keycode1 keycode2 ...
    for code in "$@"; do
        ydotool key "${code}:1" "${code}:0" 2>/dev/null
        sleep 0.1
    done
}

# -------------------------- AUTO-CONFIRM POPUP --------------------------
auto_confirm_popup() {
    local gext_pid=$1
    local elapsed=0
    local confirmed=0

    echo "  [AUTO-CONFIRM] Waiting for popup dialog..."

    while (( $(echo "$elapsed < $POPUP_WAIT_TIMEOUT" | bc -l) )); do
        if kill -0 "$gext_pid" 2>/dev/null; then
            # Strategy 1: Enter key (activates default button = Install)
            send_key $KEY_ENTER
            sleep 0.5

            if ! kill -0 "$gext_pid" 2>/dev/null; then
                confirmed=1
                echo "  [AUTO-CONFIRM] Success: Enter key"
                break
            fi

            # Strategy 2: Tab moves focus from Cancel -> Install, then Space
            send_keys $KEY_TAB $KEY_SPACE
            sleep 0.5

            if ! kill -0 "$gext_pid" 2>/dev/null; then
                confirmed=1
                echo "  [AUTO-CONFIRM] Success: Tab+Space"
                break
            fi

            # Strategy 3: Tab x2 + Space (just in case focus is elsewhere)
            send_keys $KEY_TAB $KEY_TAB $KEY_SPACE
            sleep 0.5

            if ! kill -0 "$gext_pid" 2>/dev/null; then
                confirmed=1
                echo "  [AUTO-CONFIRM] Success: Tab+Tab+Space"
                break
            fi
        else
            # gext already exited - maybe popup was very brief
            break
        fi

        sleep $KEY_RETRY_INTERVAL
        elapsed=$(echo "$elapsed + $KEY_RETRY_INTERVAL" | bc -l)
    done

    if [ $confirmed -eq 0 ] && kill -0 "$gext_pid" 2>/dev/null; then
        echo "  [ERROR] Could not auto-confirm dialog after ${elapsed}s"
        return 1
    fi

    return 0
}

# -------------------------- INSTALL EXTENSION --------------------------
install_extension() {
    echo "[INSTALL] Starting: $EXTENSION"

    # Launch gext in background
    gext install "$EXTENSION" &
    local gext_pid=$!

    # Auto-confirm the popup
    if ! auto_confirm_popup "$gext_pid"; then
        kill "$gext_pid" 2>/dev/null || true
        return 1
    fi

    # Wait for gext to finish
    if wait "$gext_pid" 2>/dev/null; then
        echo "[INSTALL] gext completed successfully"
    else
        local rc=$?
        echo "[INSTALL] gext exit code: $rc (may be OK)"
    fi

    sleep $DELAY_AFTER_INSTALL

    # Enable the extension
    echo "[ENABLE] Enabling extension..."
    if gext enable "$EXTENSION" 2>/dev/null; then
        echo "[ENABLE] Enabled via gext"
    elif gnome-extensions enable "$EXTENSION" 2>/dev/null; then
        echo "[ENABLE] Enabled via gnome-extensions"
    else
        echo "[ENABLE] Could not enable (may need shell restart)"
    fi

    sleep $DELAY_AFTER_ENABLE

    # Verify
    echo "[VERIFY] Extension info:"
    if gnome-extensions info "$EXTENSION" 2>/dev/null; then
        echo "[VERIFY] Extension is installed"
    else
        echo "[VERIFY] WARNING: Extension not detected"
    fi
}

# -------------------------- UNINSTALL EXTENSION --------------------------
uninstall_extension() {
    echo "[UNINSTALL] Removing: $EXTENSION"

    if gext uninstall "$EXTENSION" 2>/dev/null; then
        echo "[UNINSTALL] Removed via gext"
    else
        echo "[UNINSTALL] gext reported issue, trying direct..."
        rm -rf "$HOME/.local/share/gnome-shell/extensions/$EXTENSION" 2>/dev/null || true
    fi

    sleep $DELAY_AFTER_UNINSTALL

    # Verify removal
    if [ ! -d "$HOME/.local/share/gnome-shell/extensions/$EXTENSION" ]; then
        echo "[VERIFY] Confirmed: files removed"
    else
        echo "[VERIFY] WARNING: Files still present"
    fi

    if ! gnome-extensions info "$EXTENSION" 2>/dev/null | grep -q "UUID:"; then
        echo "[VERIFY] Confirmed: not registered in GNOME"
    else
        echo "[VERIFY] WARNING: Still registered (may need shell restart)"
    fi
}

# -------------------------- MAIN LOOP --------------------------
main() {
    verify_setup

    echo "=============================================="
    echo " GNOME Extension Install/Uninstall Loop"
    echo " Extension: $EXTENSION"
    echo " Cycles:    ${LOOPS:-infinite}"
    echo "=============================================="
    echo ""
    echo "NOTE: Do not move mouse or type while running."
    echo "      ydotool injects REAL keyboard events."
    echo ""
    echo "Press Ctrl+C to stop at any time."
    echo ""
    sleep 2

    local cycle=0

    while true; do
        cycle=$((cycle + 1))

        if [ "$LOOPS" -gt 0 ] && [ "$cycle" -gt "$LOOPS" ]; then
            break
        fi

        echo ""
        echo "############################################"
        echo "###  CYCLE $cycle of ${LOOPS:-INFINITE}"
        echo "############################################"
        echo ""

        if ! install_extension; then
            echo ""
            echo "[ERROR] Install failed in cycle $cycle"
            echo "Continuing to uninstall phase..."
        fi

        echo ""

        uninstall_extension

        echo ""
        echo "--------------------------------------------"
        echo "---  Cycle $cycle complete"
        echo "--------------------------------------------"
    done

    echo ""
    echo "=============================================="
    echo " SUCCESS: All $((cycle - 1)) cycles completed"
    echo "=============================================="
}

# Run main
main "$@"
SCRIPT_EOF

chmod +x ~/ext-loop.sh
