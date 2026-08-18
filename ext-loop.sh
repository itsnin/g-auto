#!/bin/bash
# =============================================================================
# GNOME Extension Install/Uninstall Loop - INFINITE
# Multi-tool fallback: gdbus Eval → xte → xdotool → ydotool
# =============================================================================

EXTENSION="spotlight@nin"
DELAY_AFTER_INSTALL=2
DELAY_AFTER_UNINSTALL=2
DELAY_AFTER_ENABLE=1
POPUP_WAIT_TIMEOUT=20
KEY_RETRY_INTERVAL=0.4

echo "=============================================="
echo " GNOME Extension Install/Uninstall Loop"
echo " Extension: $EXTENSION"
echo " Mode:      INFINITE (Ctrl+C to stop)"
echo "=============================================="
echo ""

# -------------------------- VERIFY --------------------------
echo "[VERIFY] Checking tools..."

command -v gext &>/dev/null && echo "  [OK] gext" || { echo "  [FAIL] gext missing"; exit 1; }

# Install xautomation (xte) if missing
if ! command -v xte &>/dev/null; then
    echo "  [INFO] Installing xautomation (xte)..."
    sudo apt install -y xautomation 2>/dev/null
fi
command -v xte &>/dev/null && echo "  [OK] xte" || echo "  [WARN] xte missing"

command -v xdotool &>/dev/null && echo "  [OK] xdotool" || echo "  [WARN] xdotool missing"
command -v ydotool &>/dev/null && echo "  [OK] ydotool" || echo "  [WARN] ydotool missing"

echo ""
echo "[INFO] VM window MUST have focus. Do NOT touch keyboard/mouse."
echo "       Starting in 3 seconds..."
sleep 3
echo ""

# -------------------------- KEY SENDING STRATEGIES --------------------------

# Strategy 1: MOST RELIABLE - Run JS inside GNOME Shell via D-Bus
# This doesn't inject keys - it tells GNOME Shell to click its own button
send_enter_gdbus() {
    gdbus call --session \
        --dest org.gnome.Shell \
        --object-path /org/gnome/Shell \
        --method org.gnome.Shell.Eval '
            const Main = imports.ui.main;
            let group = Main.layoutManager.modalDialogGroup;
            let children = group.get_children();
            for (let c of children) {
                let d = c._dialog || c;
                if (d._buttons) {
                    for (let b of d._buttons) {
                        if (b.label && b.label.get_text && b.label.get_text() === "Install") {
                            b.activate();
                            return "clicked-install";
                        }
                    }
                }
            }
            "no-dialog-found";
        ' 2>/dev/null | grep -q "clicked-install"
}

# Strategy 2: xte from xautomation package (uses XTest)
send_enter_xte() {
    echo "key Return" | xte 2>/dev/null
}

# Strategy 3: xdotool
send_enter_xdotool() {
    xdotool key Return 2>/dev/null
    # Also try: get active window and send to it
    xdotool getactivewindow key Return 2>/dev/null
}

# Strategy 4: ydotool - try with proper root daemon setup
send_enter_ydotool() {
    ydotool key 28:1 28:0 2>/dev/null
    ydotool key 28 2>/dev/null
    ydotool type $'\n' 2>/dev/null
}

# Master send function - tries ALL strategies
send_enter_all() {
    echo "          Trying gdbus Eval..."
    if send_enter_gdbus; then return 0; fi
    
    sleep 0.2
    echo "          Trying xte..."
    send_enter_xte
    
    sleep 0.2
    echo "          Trying xdotool..."
    send_enter_xdotool
    
    sleep 0.2
    echo "          Trying ydotool..."
    send_enter_ydotool
    
    return 1
}

send_tab_space_all() {
    # Tab then Space via multiple tools
    echo "key Tab" | xte 2>/dev/null
    sleep 0.1
    echo "key space" | xte 2>/dev/null
    
    xdotool key Tab space 2>/dev/null
    ydotool key 15:1 15:0 57:1 57:0 2>/dev/null
}

# -------------------------- AUTO CONFIRM --------------------------
auto_confirm_popup() {
    local gext_pid=$1
    local elapsed=0
    local confirmed=0
    
    echo "        [AUTO-CONFIRM] Waiting for dialog..."
    
    while (( $(echo "$elapsed < $POPUP_WAIT_TIMEOUT" | bc -l) )); do
        if kill -0 "$gext_pid" 2>/dev/null; then
            
            sleep 0.3  # Ensure popup has focus
            
            echo "        [AUTO-CONFIRM] Attempt at ${elapsed}s..."
            send_enter_all
            sleep 0.8
            
            if ! kill -0 "$gext_pid" 2>/dev/null; then
                confirmed=1
                echo "        [AUTO-CONFIRM] SUCCESS"
                break
            fi
            
            echo "        [AUTO-CONFIRM] Trying Tab+Space..."
            send_tab_space_all
            sleep 0.8
            
            if ! kill -0 "$gext_pid" 2>/dev/null; then
                confirmed=1
                echo "        [AUTO-CONFIRM] SUCCESS with Tab+Space"
                break
            fi
            
            # Rapid fire
            echo "        [AUTO-CONFIRM] Rapid fire x5..."
            for i in 1 2 3 4 5; do
                echo "key Return" | xte 2>/dev/null
                xdotool key Return 2>/dev/null
                sleep 0.08
            done
            sleep 0.5
            
            if ! kill -0 "$gext_pid" 2>/dev/null; then
                confirmed=1
                echo "        [AUTO-CONFIRM] SUCCESS with rapid fire"
                break
            fi
            
        else
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

# -------------------------- INSTALL --------------------------
install_extension() {
    echo "    [INSTALL] $EXTENSION"
    gext install "$EXTENSION" &
    local gext_pid=$!
    
    if ! auto_confirm_popup "$gext_pid"; then
        kill "$gext_pid" 2>/dev/null
        return 1
    fi
    
    wait "$gext_pid" 2>/dev/null
    echo "    [INSTALL] Done (exit: $?)"
    sleep $DELAY_AFTER_INSTALL
    
    echo "    [ENABLE] $EXTENSION"
    gext enable "$EXTENSION" 2>/dev/null || gnome-extensions enable "$EXTENSION" 2>/dev/null
    sleep $DELAY_AFTER_ENABLE
    
    echo "    [VERIFY]"
    gnome-extensions info "$EXTENSION" 2>/dev/null | head -2 || echo "      Not detected"
}

# -------------------------- UNINSTALL --------------------------
uninstall_extension() {
    echo "    [UNINSTALL] $EXTENSION"
    gext uninstall "$EXTENSION" 2>/dev/null
    rm -rf "$HOME/.local/share/gnome-shell/extensions/$EXTENSION" 2>/dev/null
    sleep $DELAY_AFTER_UNINSTALL
    
    [ ! -d "$HOME/.local/share/gnome-shell/extensions/$EXTENSION" ] && \
        echo "    [VERIFY] Files removed" || echo "    [VERIFY] WARNING: Files present"
}

# -------------------------- INFINITE LOOP --------------------------
cycle=0
while true; do
    cycle=$((cycle + 1))
    echo ""
    echo "############################################"
    echo "###  CYCLE $cycle (INFINITE)"
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
