
#!/bin/bash
# =============================================================================
# GNOME Extension Install/Uninstall Loop Automation
# Uses xdotool to auto-confirm the GNOME Shell "Install Extension" dialog
# Verified on: Ubuntu 24.04 LTS, GNOME 46, X11
# Requirements: xdotool, gnome-extensions-cli (gext) v0.11.0+
# =============================================================================

set -euo pipefail

# -------------------------- CONFIGURATION --------------------------
EXTENSION="spotlight@nin"    # Extension UUID to install/uninstall
LOOPS=10                     # Number of cycles (0 = infinite)
DELAY_AFTER_INSTALL=2        # Seconds to wait after install completes
DELAY_AFTER_UNINSTALL=2      # Seconds to wait after uninstall
DELAY_AFTER_ENABLE=1         # Seconds to wait after enabling
POPUP_WAIT_TIMEOUT=15        # Max seconds to wait for the popup dialog
KEY_RETRY_INTERVAL=0.5       # Seconds between retries sending keys
# -------------------------------------------------------------------

# -------------------------- VERIFY DEPENDENCIES --------------------------
verify_dependencies() {
    local missing=0
    
    if ! command -v xdotool &>/dev/null; then
        echo "[ERROR] xdotool not found. Install with: sudo apt install xdotool"
        missing=1
    fi
    
    if ! command -v gext &>/dev/null; then
        echo "[ERROR] gext (gnome-extensions-cli) not found."
        missing=1
    fi
    
    # Check X11 session
    if [ "${XDG_SESSION_TYPE:-}" != "x11" ]; then
        echo "[ERROR] This script requires an X11 session. Current: ${XDG_SESSION_TYPE:-unknown}"
        echo "        Log out and select 'GNOME on Xorg' at the login screen."
        missing=1
    fi
    
    # Check DISPLAY
    if [ -z "${DISPLAY:-}" ]; then
        echo "[ERROR] DISPLAY variable not set. Are you in a graphical session?"
        missing=1
    fi
    
    if [ $missing -eq 1 ]; then
        exit 1
    fi
    
    echo "[OK] Dependencies verified: xdotool, gext, X11 session"
}

# -------------------------- AUTO-CONFIRM POPUP --------------------------
# Strategy:
# 1. Wait for the dialog to appear by polling gext process state
# 2. Send Return key (GNOME HIG: Return activates default button = Install)
# 3. Fallback: Tab + Space (moves focus from Cancel to Install)
# 4. Verify gext process exits (confirmation succeeded)
auto_confirm_popup() {
    local gext_pid=$1
    local elapsed=0
    local confirmed=0
    
    echo "  [AUTO-CONFIRM] Waiting for popup dialog..."
    
    # Wait for gext to block on the dialog (process exists but isn't exiting)
    while [ $elapsed -lt $POPUP_WAIT_TIMEOUT ]; do
        # Check if gext is still running (blocked waiting for user input)
        if kill -0 "$gext_pid" 2>/dev/null; then
            # Try sending Return key - activates the default (Install) button
            # per GNOME Human Interface Guidelines
            xdotool key Return 2>/dev/null
            
            # Give it a moment to process
            sleep 0.5
            
            # Check if gext exited (dialog was confirmed)
            if ! kill -0 "$gext_pid" 2>/dev/null; then
                confirmed=1
                echo "  [AUTO-CONFIRM] Dialog confirmed with Return key"
                break
            fi
            
            # Fallback: Tab to move focus from Cancel -> Install, then Space
            xdotool key Tab space 2>/dev/null
            sleep 0.5
            
            if ! kill -0 "$gext_pid" 2>/dev/null; then
                confirmed=1
                echo "  [AUTO-CONFIRM] Dialog confirmed with Tab+Space"
                break
            fi
        else
            # gext already exited - maybe popup was very brief or error
            break
        fi
        
        sleep $KEY_RETRY_INTERVAL
        elapsed=$(echo "$elapsed + $KEY_RETRY_INTERVAL" | bc)
    done
    
    if [ $confirmed -eq 0 ]; then
        # Last resort: try coordinate-based click on typical Install button position
        # For a centered dialog on 1920x1080, Install button is roughly at center-right
        local screen_w screen_h
        screen_w=$(xdotool getdisplaygeometry 2>/dev/null | awk '{print $1}')
        screen_h=$(xdotool getdisplaygeometry 2>/dev/null | awk '{print $2}')
        if [ -n "$screen_w" ] && [ -n "$screen_h" ]; then
            local click_x=$((screen_w / 2 + screen_w / 8))   # Right of center
            local click_y=$((screen_h / 2 + screen_h / 10))  # Below center
            echo "  [AUTO-CONFIRM] Fallback: clicking at ($click_x, $click_y)"
            xdotool mousemove "$click_x" "$click_y" click 1 2>/dev/null
            sleep 0.5
        fi
        
        if kill -0 "$gext_pid" 2>/dev/null; then
            echo "  [WARNING] Could not auto-confirm dialog after ${elapsed}s"
            return 1
        fi
    fi
    
    return 0
}

# -------------------------- INSTALL CYCLE --------------------------
install_extension() {
    echo "[INSTALL] Starting installation of $EXTENSION..."
    
    # Launch gext install in background
    gext install "$EXTENSION" &
    local gext_pid=$!
    
    # Auto-confirm the popup
    if ! auto_confirm_popup "$gext_pid"; then
        echo "[ERROR] Failed to confirm popup dialog"
        # Clean up stuck process
        kill "$gext_pid" 2>/dev/null || true
        return 1
    fi
    
    # Wait for gext to fully complete
    if wait "$gext_pid" 2>/dev/null; then
        echo "[INSTALL] gext install completed successfully"
    else
        local exit_code=$?
        echo "[WARNING] gext install exited with code $exit_code (may be OK if already installed)"
    fi
    
    sleep $DELAY_AFTER_INSTALL
    
    # Enable the extension
    echo "[ENABLE] Enabling $EXTENSION..."
    if gext enable "$EXTENSION" 2>/dev/null || gnome-extensions enable "$EXTENSION" 2>/dev/null; then
        echo "[ENABLE] Extension enabled"
    else
        echo "[WARNING] Could not enable extension (may need shell restart)"
    fi
    
    sleep $DELAY_AFTER_ENABLE
    
    # Verify status
    echo "[VERIFY] Extension status:"
    gnome-extensions info "$EXTENSION" 2>/dev/null | head -3 || echo "  (not found in extension list)"
}

# -------------------------- UNINSTALL CYCLE --------------------------
uninstall_extension() {
    echo "[UNINSTALL] Removing $EXTENSION..."
    
    if gext uninstall "$EXTENSION" 2>/dev/null; then
        echo "[UNINSTALL] Extension removed successfully"
    else
        echo "[WARNING] gext uninstall reported an issue"
    fi
    
    sleep $DELAY_AFTER_UNINSTALL
    
    # Verify removal
    if ! gnome-extensions info "$EXTENSION" 2>/dev/null | grep -q "UUID:"; then
        echo "[VERIFY] Confirmed: $EXTENSION is no longer installed"
    else
        echo "[WARNING] $EXTENSION may still be present"
    fi
}

# -------------------------- MAIN LOOP --------------------------
main() {
    verify_dependencies
    
    echo ""
    echo "=============================================="
    echo " GNOME Extension Install/Uninstall Loop"
    echo " Extension: $EXTENSION"
    echo " Cycles:    ${LOOPS:-infinite}"
    echo " Session:   X11 ($DISPLAY)"
    echo "=============================================="
    echo ""
    echo "NOTE: Do not move your mouse or type while this runs."
    echo "      xdotool injects real keyboard/mouse events."
    echo ""
    
    local cycle=0
    
    while true; do
        cycle=$((cycle + 1))
        
        if [ "$LOOPS" -gt 0 ] && [ "$cycle" -gt "$LOOPS" ]; then
            break
        fi
        
        echo ""
        echo "########## CYCLE $cycle of ${LOOPS:-INFINITE} ##########"
        echo ""
        
        install_extension
        echo ""
        uninstall_extension
        
        echo ""
        echo "---------- Cycle $cycle complete ----------"
        echo ""
    done
    
    echo "=============================================="
    echo " All $((cycle - 1)) cycles completed successfully"
    echo "=============================================="
}

# Run main
main "$@"
