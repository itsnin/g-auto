#!/bin/bash
# =============================================================================
# GNOME Extension Install/Uninstall Loop - INFINITE - FIXED
# Fix: Tab+Space first (moves past Cancel to Install), fixed GNOME 46 JS
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
echo " Fix:       Tab+Space first, JS button filter"
echo "=============================================="
echo ""

# -------------------------- VERIFY --------------------------
echo "[VERIFY] Checking tools..."
command -v gext &>/dev/null && echo "  [OK] gext" || { echo "  [FAIL] gext missing"; exit 1; }
command -v xte &>/dev/null && echo "  [OK] xte" || echo "  [WARN] xte missing"
command -v xdotool &>/dev/null && echo "  [OK] xdotool" || echo "  [WARN] xdotool missing"

echo ""
echo "[INFO] VM window MUST have focus. Do NOT touch keyboard/mouse."
echo "       Starting in 3 seconds..."
sleep 3
echo ""

# -------------------------- STRATEGY 1: GNOME SHELL JS (BEST) --------------------------
# Runs JavaScript INSIDE GNOME Shell via D-Bus to click Install button directly
send_enter_gdbus() {
    local result
    result=$(gdbus call --session \
        --dest org.gnome.Shell \
        --object-path /org/gnome/Shell \
        --method org.gnome.Shell.Eval '
            // GNOME 46 ES module compatible
            const Main = globalThis.Main || imports.ui.main;
            let clicked = "no-dialog";
            
            try {
                let group = Main.layoutManager.modalDialogGroup;
                let children = group.get_children();
                
                for (let c of children) {
                    let dialog = c._dialog || c;
                    
                    // Find buttons array
                    let buttons = dialog._buttons || dialog._buttonList || [];
                    
                    for (let btn of buttons) {
                        let label = "";
                        
                        // Try multiple ways to get button label
                        try {
                            if (btn.label) {
                                if (typeof btn.label.get_text === "function") {
                                    label = btn.label.get_text();
                                } else if (btn.label.text) {
                                    label = btn.label.text;
                                }
                            } else if (btn.get_label) {
                                label = btn.get_label();
                            } else if (btn._label) {
                                label = btn._label.text || btn._label.get_text();
                            }
                        } catch(e) {}
                        
                        // DEBUG: log what we find
                        if (label) {
                            clicked = "found-btn:" + label;
                        }
                        
                        // MUST be Install, NOT Cancel
                        if (label === "Install" || label === "_Install" || 
                            (label.includes("nstall") && !label.includes("ancel"))) {
                            if (btn.activate) {
                                btn.activate();
                                return "CLICKED-INSTALL:" + label;
                            } else if (btn.click) {
                                btn.click();
                                return "CLICKED-INSTALL:" + label;
                            }
                        }
                    }
                }
            } catch(e) {
                return "JS-ERROR:" + e.message;
            }
            
            return "RESULT:" + clicked;
        ' 2>/dev/null)
    
    echo "          gdbus result: $result"
    
    # Check if we successfully clicked Install
    echo "$result" | grep -q "CLICKED-INSTALL"
}

# -------------------------- STRATEGY 2: TAB + SPACE (KEYBOARD) --------------------------
# Cancel has initial focus. Tab moves to Install. Space clicks it.
send_tab_space() {
    # Method A: xte
    echo "key Tab" | xte 2>/dev/null
    sleep 0.15
    echo "key space" | xte 2>/dev/null
    
    sleep 0.1
    
    # Method B: xdotool
    xdotool key Tab space 2>/dev/null
}

# -------------------------- STRATEGY 3: RETURN KEY --------------------------
# In case Return activates default button (Install)
send_return() {
    echo "key Return" | xte 2>/dev/null
    xdotool key Return 2>/dev/null
    ydotool key 28:1 28:0 2>/dev/null
}

# -------------------------- MASTER SEND --------------------------
send_keys_to_install() {
    echo "          [1/3] gdbus JS click..."
    if send_enter_gdbus; then
        echo "          >>> SUCCESS via gdbus <<<"
        return 0
    fi
    
    sleep 0.3
    echo "          [2/3] Tab + Space..."
    send_tab_space
    sleep 0.8
    return 0  # Optimistic - check if process exited in caller
}

# -------------------------- AUTO CONFIRM --------------------------
auto_confirm_popup() {
    local gext_pid=$1
    local elapsed=0
    local confirmed=0
    
    echo "        [AUTO-CONFIRM] Waiting for dialog..."
    
    while (( $(echo "$elapsed < $POPUP_WAIT_TIMEOUT" | bc -l) )); do
        if kill -0 "$gext_pid" 2>/dev/null; then
            
            sleep 0.4  # Ensure popup fully rendered and has focus
            
            echo "        [AUTO-CONFIRM] Attempt at ${elapsed}s..."
            send_keys_to_install
            
            # Check if gext exited (dialog was handled)
            sleep 1
            if ! kill -0 "$gext_pid" 2>/dev/null; then
                confirmed=1
                echo "        [AUTO-CONFIRM] Dialog dismissed"
                break
            fi
            
            # Fallback: try Return
            echo "        [AUTO-CONFIRM] Fallback: Return key..."
            send_return
            sleep 0.8
            
            if ! kill -0 "$gext_pid" 2>/dev/null; then
                confirmed=1
                echo "        [AUTO-CONFIRM] Dialog dismissed (Return)"
                break
            fi
            
            # Desperate: Tab x2 + Space
            echo "        [AUTO-CONFIRM] Desperate: Tab x2 + Space..."
            echo "key Tab" | xte 2>/dev/null; sleep 0.1
            echo "key Tab" | xte 2>/dev/null; sleep 0.1
            echo "key space" | xte 2>/dev/null
            sleep 0.8
            
            if ! kill -0 "$gext_pid" 2>/dev/null; then
                confirmed=1
                echo "        [AUTO-CONFIRM] Dialog dismissed (Tabx2)"
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
    local rc=$?
    echo "    [INSTALL] gext exit code: $rc"
    sleep $DELAY_AFTER_INSTALL
    
    echo "    [ENABLE] $EXTENSION"
    gext enable "$EXTENSION" 2>/dev/null || gnome-extensions enable "$EXTENSION" 2>/dev/null
    sleep $DELAY_AFTER_ENABLE
    
    echo "    [VERIFY]"
    if gnome-extensions info "$EXTENSION" 2>/dev/null; then
        echo "    [VERIFY] >>> EXTENSION IS INSTALLED <<<"
    else
        echo "    [VERIFY] >>> WARNING: NOT INSTALLED - clicked Cancel? <<<"
    fi
}

# -------------------------- UNINSTALL --------------------------
uninstall_extension() {
    echo "    [UNINSTALL] $EXTENSION"
    gext uninstall "$EXTENSION" 2>/dev/null
    rm -rf "$HOME/.local/share/gnome-shell/extensions/$EXTENSION" 2>/dev/null
    sleep $DELAY_AFTER_UNINSTALL
    
    if [ ! -d "$HOME/.local/share/gnome-shell/extensions/$EXTENSION" ]; then
        echo "    [VERIFY] Files removed"
    else
        echo "    [VERIFY] WARNING: Files still present!"
    fi
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
