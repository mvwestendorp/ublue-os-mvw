#!/bin/bash

set -ouex pipefail

### Install packages

# Packages can be installed from any enabled yum repo on the image.
# RPMfusion repos are available by default in ublue main images
# List of rpmfusion packages can be found here:
# https://mirrors.rpmfusion.org/mirrorlist?path=free/fedora/updates/39/x86_64/repoview/index.html&protocol=https&redirect=1

# this installs a package from fedora repos
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

# Install security scanning and audit tools
dnf5 install -y openscap-scanner scap-security-guide audit

# Enable and configure firewall
dnf5 install -y firewalld
systemctl enable firewalld

# Enable audit daemon for security logging
systemctl enable auditd

# Remove legacy insecure protocols
dnf5 remove -y telnet rsh-client 2>/dev/null || true

# Kernel hardening - network protections (non-obtrusive)
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

# Clean up package cache to reduce image size and attack surface
dnf5 clean all
rm -rf /var/cache/dnf5/*

#### Development Tools (Host-level only)

# Kubernetes tools (need host access)
dnf5 install -y kubernetes-client helm

# Container tools for development
dnf5 install -y distrobox buildah skopeo

# Essential CLI tools
dnf5 install -y git git-lfs direnv fzf ripgrep fd-find jq

# Install gnu radio
dnf5 install -y gnuradio gnuradio-osmosdr

# Install k9s (Kubernetes TUI) with SHA256 verification
K9S_VERSION="v0.50.18"
K9S_SHA256="0b697ed4aa80997f7de4deeed6f1fba73df191b28bf691b1f28d2f45fa2a9e9b"
mkdir -p /tmp/k9s
curl -sL "https://github.com/derailed/k9s/releases/download/${K9S_VERSION}/k9s_Linux_amd64.tar.gz" -o /tmp/k9s.tar.gz
echo "${K9S_SHA256}  /tmp/k9s.tar.gz" | sha256sum -c - || { echo "ERROR: k9s checksum verification failed"; exit 1; }
tar xzf /tmp/k9s.tar.gz -C /tmp/k9s
/tmp/k9s/k9s version || { echo "ERROR: k9s binary validation failed"; exit 1; }
install -m 0755 /tmp/k9s/k9s /usr/bin/k9s
rm -rf /tmp/k9s /tmp/k9s.tar.gz

# Create distrobox assembly config for new users
mkdir -p /etc/skel/.config/distrobox
cp /ctx/distrobox.ini /etc/skel/.config/distrobox/distrobox.ini

# Use a COPR Example:
#
# dnf5 -y copr enable ublue-os/staging
# dnf5 -y install package
# Disable COPRs so they don't end up enabled on the final image:
# dnf5 -y copr disable ublue-os/staging

#### Example for enabling a System Unit File

systemctl enable podman.socket
