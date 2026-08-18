#!/bin/bash
# =============================================================================
# GNOME Extension Install/Uninstall Loop Automation
# Repository: https://github.com/itsnin/g-auto
# Environment:  Ubuntu 24.04 LTS, GNOME 46, X11 (GNOME Boxes VM)
# Tool:         ydotool (kernel-level uinput injection)
# =============================================================================

# -------------------------- CONFIGURATION --------------------------
EXTENSION="spotlight@nin"
LOOPS=10
DELAY_AFTER_INSTALL=2
DELAY_AFTER_UNINSTALL=2
DELAY_AFTER_ENABLE=1
POPUP_WAIT_TIMEOUT=15
KEY_RETRY_INTERVAL=0.5

# Linux key codes (/usr/include/linux/input-event-codes.h)
KEY_ENTER=28
KEY_TAB=15
KEY_SPACE=57
# -------------------------------------------------------------------

echo "=============================================="
echo " GNOME Extension Install/Uninstall Loop"
echo " Extension: $EXTENSION"
echo " Cycles:    $LOOPS"
echo "=============================================="
echo ""

# -------------------------- VERIFY SETUP --------------------------
echo "[1/4] Verifying setup..."

ERRORS=0

# Check gext
if command -v gext &>/dev/null; then
    echo "      [OK] gext: $(command -v gext)"
else
    echo "      [FAIL] gext not found. Install: pipx install gnome-extensions-cli"
    ERRORS=1
fi

# Check ydotool
if command -v ydotool &>/dev/null; then
    echo "      [OK] ydotool: $(command -v ydotool)"
else
    echo "      [FAIL] ydotool not found. Install: sudo apt install ydotool"
    ERRORS=1
fi

# Check ydotoold daemon
YDOTOOLD_PID=$(pgrep ydotoold | head -1)
if [ -n "$YDOTOOLD_PID" ]; then
    echo "      [OK] ydotoold running (PID: $YDOTOOLD_PID)"
else
    echo "      [WARN] ydotoold not running. Starting..."
    ydotoold &
    sleep 1
    YDOTOOLD_PID=$(pgrep ydotoold | head -1)
    if [ -n "$YDOTOOLD_PID" ]; then
        echo "      [OK] ydotoold started (PID: $YDOTOOLD_PID)"
    else
        echo "      [FAIL] Could not start ydotoold"
        ERRORS=1
    fi
fi

# Check /dev/uinput
if [ -e /dev/uinput ]; then
    echo "      [OK] /dev/uinput exists"
else
    echo "      [FAIL] /dev/uinput missing. Run: sudo modprobe uinput"
    ERRORS=1
fi

# Check input group membership
if groups | grep -q "input"; then
    echo "      [OK] User in 'input' group"
else
    echo "      [FAIL] Not in 'input' group. Run: sudo usermod -aG input \$USER"
    echo "             Then log out and back in."
    ERRORS=1
fi

# Check uinput permissions
if [ -r /dev/uinput ] && [ -w /dev/uinput ]; then
    echo "      [OK] /dev/uinput read/write access"
else
    echo "      [WARN] Fixing /dev/uinput permissions..."
    sudo chmod 660 /dev/uinput 2>/dev/null
    sudo chgrp input /dev/uinput 2>/dev/null
fi

echo ""

if [ "$ERRORS" -eq 1 ]; then
    echo "[ERROR] Fix the issues above and re-run."
    exit 1
fi

echo "[2/4] All checks passed!"
echo ""
echo "[3/4] IMPORTANT:"
echo "      - Do NOT move mouse or type while running"
echo "      - VM window MUST have keyboard focus"
echo "      - ydotool injects REAL keyboard events"
echo ""
echo "[4/4] Starting in 3 seconds... (Ctrl+C to abort)"
sleep 3
echo ""

# -------------------------- HELPER FUNCTIONS --------------------------

# Send a single key press and release via ydotool
send_key() {
    local code=$1
    ydotool key "${code}:1" "${code}:0" 2>/dev/null
}

# Send multiple keys in sequence
send_key_sequence() {
    for code in "$@"; do
        ydotool key "${code}:1" "${code}:0" 2>/dev/null
        sleep 0.1
    done
}

# Auto-confirm the GNOME Shell extension install popup
auto_confirm_popup() {
    local gext_pid=$1
    local elapsed=0
    local confirmed=0

    echo "        [AUTO-CONFIRM] Waiting for dialog..."

    while (( $(echo "$elapsed < $POPUP_WAIT_TIMEOUT" | bc -l) )); do
        # If gext is still running, the dialog is blocking it
        if kill -0 "$gext_pid" 2>/dev/null; then

            # Strategy 1: Enter key activates default (Install) button
            send_key $KEY_ENTER
            sleep 0.5
            if ! kill -0 "$gext_pid" 2>/dev/null; then
                confirmed=1
                echo "        [AUTO-CONFIRM] Success: Enter key"
                break
            fi

            # Strategy 2: Tab moves focus from Cancel -> Install, then Space
            send_key_sequence $KEY_TAB $KEY_SPACE
            sleep 0.5
            if ! kill -0 "$gext_pid" 2>/dev/null; then
                confirmed=1
                echo "        [AUTO-CONFIRM] Success: Tab+Space"
                break
            fi

            # Strategy 3: Tab x2 + Space (defensive fallback)
            send_key_sequence $KEY_TAB $KEY_TAB $KEY_SPACE
            sleep 0.5
            if ! kill -0 "$gext_pid" 2>/dev/null; then
                confirmed=1
                echo "        [AUTO-CONFIRM] Success: Tab+Tab+Space"
                break
            fi

        else
            # gext already exited - dialog was brief or already handled
            break
        fi

        sleep $KEY_RETRY_INTERVAL
        elapsed=$(echo "$elapsed + $KEY_RETRY_INTERVAL" | bc -l)
    done

    if [ $confirmed -eq 0 ] && kill -0 "$gext_pid" 2>/dev/null; then
        echo "        [AUTO-CONFIRM] FAILED after ${elapsed}s"
        return 1
    fi

    return 0
}

# -------------------------- INSTALL PHASE --------------------------
install_extension() {
    echo "    [INSTALL] $EXTENSION"

    # Launch gext in the background
    gext install "$EXTENSION" &
    local gext_pid=$!

    # Auto-confirm the modal dialog
    if ! auto_confirm_popup "$gext_pid"; then
        echo "    [INSTALL] Killing unresponsive gext process..."
        kill "$gext_pid" 2>/dev/null
        return 1
    fi

    # Wait for gext to complete
    if wait "$gext_pid" 2>/dev/null; then
        echo "    [INSTALL] gext completed successfully"
    else
        local rc=$?
        echo "    [INSTALL] gext exit code: $rc"
    fi

    sleep $DELAY_AFTER_INSTALL

    # Enable the extension
    echo "    [ENABLE] $EXTENSION"
    if gext enable "$EXTENSION" 2>/dev/null; then
        echo "    [ENABLE] Success via gext"
    elif gnome-extensions enable "$EXTENSION" 2>/dev/null; then
        echo "    [ENABLE] Success via gnome-extensions"
    else
        echo "    [ENABLE] Could not enable (may need shell restart)"
    fi

    sleep $DELAY_AFTER_ENABLE

    # Verify installation
    echo "    [VERIFY]"
    if gnome-extensions info "$EXTENSION" 2>/dev/null; then
        echo "    [VERIFY] Extension is installed"
    else
        echo "    [VERIFY] WARNING: Extension not detected by GNOME"
    fi
}

# -------------------------- UNINSTALL PHASE --------------------------
uninstall_extension() {
    echo "    [UNINSTALL] $EXTENSION"

    if gext uninstall "$EXTENSION" 2>/dev/null; then
        echo "    [UNINSTALL] Removed via gext"
    else
        echo "    [UNINSTALL] gext had issues, forcing removal..."
        rm -rf "$HOME/.local/share/gnome-shell/extensions/$EXTENSION" 2>/dev/null
    fi

    sleep $DELAY_AFTER_UNINSTALL

    # Verify files are gone
    if [ ! -d "$HOME/.local/share/gnome-shell/extensions/$EXTENSION" ]; then
        echo "    [VERIFY] Files confirmed removed"
    else
        echo "    [VERIFY] WARNING: Extension files still present!"
    fi

    # Verify GNOME no longer sees it
    if ! gnome-extensions info "$EXTENSION" 2>/dev/null | grep -q "UUID:"; then
        echo "    [VERIFY] GNOME confirms extension unregistered"
    else
        echo "    [VERIFY] NOTE: Still registered (may need shell restart)"
    fi
}

# -------------------------- MAIN LOOP --------------------------
for ((cycle=1; cycle<=LOOPS; cycle++)); do
    echo ""
    echo "############################################"
    echo "###  CYCLE $cycle of $LOOPS"
    echo "############################################"
    echo ""

    install_extension
    echo ""
    uninstall_extension

    echo ""
    echo "--------------------------------------------"
    echo "---  Cycle $cycle complete"
    echo "--------------------------------------------"
done

echo ""
echo "=============================================="
echo " SUCCESS: All $LOOPS cycles completed"
echo "=============================================="
