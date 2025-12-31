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

# Default settings that users can override
cat > /etc/skel/.config/Code/User/settings.json << 'EOF'
{
    "terminal.integrated.defaultProfile.linux": "bash",
    "podman.dockerPath": "podman",
    "dev.containers.dockerPath": "podman",
    "remote.containers.dockerPath": "podman"
}
EOF

# Enable podman socket for all users by default
systemctl --global enable podman.socket

# Create docker compatibility symlink
ln -sf /usr/bin/podman /usr/local/bin/docker

#### Security Hardening

# Ensure SELinux is enforcing
sed -i 's/^SELINUX=.*/SELINUX=enforcing/' /etc/selinux/config

# Install security scanning tools
dnf5 install -y openscap-scanner scap-security-guide

# Enable and configure firewall
dnf5 install -y firewalld
systemctl enable firewalld

# Clean up package cache to reduce image size and attack surface
dnf5 clean all
rm -rf /var/cache/dnf5/*

# Use a COPR Example:
#
# dnf5 -y copr enable ublue-os/staging
# dnf5 -y install package
# Disable COPRs so they don't end up enabled on the final image:
# dnf5 -y copr disable ublue-os/staging

#### Example for enabling a System Unit File

systemctl enable podman.socket
