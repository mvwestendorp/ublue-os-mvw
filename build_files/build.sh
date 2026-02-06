#!/bin/bash

set -ouex pipefail

### Install packages

# Packages can be installed from any enabled yum repo on the image.
# RPMfusion repos are available by default in ublue main images
# List of rpmfusion packages: https://mirrors.rpmfusion.org/

# Basic utilities
dnf5 install -y tmux hunspell-nl pandoc

# Install vscode
rpm --import https://packages.microsoft.com/keys/microsoft.asc
echo -e "[code]\nname=Visual Studio Code\nbaseurl=https://packages.microsoft.com/yumrepos/vscode\nenabled=1\nautorefresh=1\ntype=rpm-md\ngpgcheck=1\ngpgkey=https://packages.microsoft.com/keys/microsoft.asc" | tee /etc/yum.repos.d/vscode.repo
dnf5 install -y code

# Configure VS Code for podman and set default preferences
mkdir -p /etc/skel/.config/Code/User
cp /ctx/vscode-settings.json /etc/skel/.config/Code/User/settings.json

# Enable podman socket for all users by default
systemctl --global enable podman.socket

# Create docker compatibility symlink
# In bootc/ostree images, /usr/local may be a symlink to /var/usrlocal
# Resolve the actual path and ensure bin directory exists
ACTUAL_LOCAL_PATH=$(readlink -f /usr/local 2>/dev/null || echo "/usr/local")
mkdir -p "${ACTUAL_LOCAL_PATH}/bin"
ln -sf /usr/bin/podman "${ACTUAL_LOCAL_PATH}/bin/docker"

#### Security Hardening

# Ensure SELinux is enforcing
sed -i 's/^SELINUX=.*/SELINUX=enforcing/' /etc/selinux/config

# Install security tools (combined for performance)
dnf5 install -y openscap-scanner scap-security-guide audit firewalld

# Enable security services
systemctl enable firewalld auditd

# Remove legacy insecure protocols (if present)
dnf5 remove -y telnet rsh-client 2>/dev/null || true

# Network security hardening via sysctl
cat > /etc/sysctl.d/99-security-hardening.conf <<'EOF'
# Protect against IP spoofing
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Enable SYN cookies for DoS protection
net.ipv4.tcp_syncookies = 1

# Disable source routing
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0

# Disable ICMP redirects
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0

# Ignore ICMP broadcast requests
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
EOF

#### Development Tools

# Install all development tools in a single transaction for performance
dnf5 install -y \
  kubernetes-client helm \
  distrobox buildah skopeo \
  git git-lfs direnv fzf ripgrep fd-find jq \
  gnuradio python3-gnuradio SoapySDR soapy-rtlsdr rtl-sdr sdrpp

#### GNU Radio & SDR Configuration

# Set environment variables for GNU Radio
cat >> /etc/profile.d/gnuradio.sh <<'EOF'
export PYTHONPATH=/usr/lib64/python3/site-packages:$PYTHONPATH
export LD_LIBRARY_PATH=/usr/lib64:$LD_LIBRARY_PATH
EOF

# Create symlinks for SDR applications
ln -sf /usr/bin/gnuradio-companion /usr/local/bin/gnuradio-companion 2>/dev/null || true
ln -sf /usr/bin/sdrpp /usr/local/bin/sdrpp 2>/dev/null || true

# Verify GNU Radio and SDR++ installation
echo "Verifying SDR tools installation..."
python3 -c "import gnuradio; print('GNU Radio version:', gnuradio.__version__)" || echo "WARNING: GNU Radio Python module not found"
which gnuradio-companion || echo "WARNING: gnuradio-companion not found in PATH"
which sdrpp || echo "WARNING: sdrpp not found in PATH"

#### Build k9s from Source

# Build k9s to pick up Go stdlib CVE fixes (see build-k9s.sh)
# Revert to binary download once k9s ships a release built with Go >= 1.25.6
/ctx/build-k9s.sh

#### User Environment Configuration

# Create distrobox assembly config for new users
mkdir -p /etc/skel/.config/distrobox
cp /ctx/distrobox.ini /etc/skel/.config/distrobox/distrobox.ini

#### Storage Configuration

# Configure system to use data-ssd for heavy operations
/ctx/storage-data-ssd.sh

#### Final Cleanup

# Clean up package cache to reduce image size and attack surface
dnf5 clean all
rm -rf /var/cache/dnf5/*
