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
# Ensure /usr/local/bin exists (remove if it's a file, create if directory)
if [ -f /usr/local/bin ]; then
    rm -f /usr/local/bin
fi
mkdir -p /usr/local/bin
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

#### Development Tools (Host-level only)

# Kubernetes tools (need host access)
dnf5 install -y kubernetes-client helm

# Container tools for development
dnf5 install -y distrobox buildah skopeo

# Essential CLI tools
dnf5 install -y git git-lfs direnv fzf ripgrep fd-find jq

# Install k9s (Kubernetes TUI)
K9S_VERSION="v0.32.7"
mkdir -p /tmp/k9s
curl -sL "https://github.com/derailed/k9s/releases/download/${K9S_VERSION}/k9s_Linux_amd64.tar.gz" | tar xz -C /tmp/k9s
mv /tmp/k9s/k9s /usr/local/bin/k9s
chmod +x /usr/local/bin/k9s
rm -rf /tmp/k9s

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
