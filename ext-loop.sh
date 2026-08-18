# Check you're in the input group
groups | grep input

# Check /dev/uinput exists and is accessible
ls -la /dev/uinput

# Start the ydotool daemon
ydotoold &

# Quick test: ydotool should be able to send keys
# This will press Enter after 3 seconds - make sure your cursor is in a text field to see it
sleep 3 && ydotool key 28:1 28:0
