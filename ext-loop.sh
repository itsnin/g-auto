# Load the uinput kernel module
sudo modprobe uinput

# Make it load automatically on boot
echo 'uinput' | sudo tee /etc/modules-load.d/uinput.conf

# Add your user to the 'input' group
sudo usermod -aG input "$USER"

# Create udev rule for permanent access to /dev/uinput
echo 'KERNEL=="uinput", GROUP="input", MODE="0660", OPTIONS+="static_node=uinput"' | sudo tee /etc/udev/rules.d/80-uinput.rules

# Reload udev rules
sudo udevadm control --reload-rules
sudo udevadm trigger
