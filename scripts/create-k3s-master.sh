#!/bin/bash
# filepath: /home/ph/Git/hetzner/proxmox/create-k3s-master.sh

set -e

CTID=9001
CTNAME="k3s-master"
TEMPLATE="local:vztmpl/ubuntu-24.04-standard_24.04-1_amd64.tar.zst"  # Use the latest
STORAGE="local-lvm"

# Prompt for cores, memory, disk size, IP and GW with defaults
read -p "Enter number of CPU cores [2]: " CORES_INPUT
CORES="${CORES_INPUT:-2}"
read -p "Enter memory size in MB [2048]: " MEMORY_INPUT
MEMORY="${MEMORY_INPUT:-2048}"
read -p "Enter disk size in GB [16]: " DISK_SIZE_INPUT
DISK_SIZE="${DISK_SIZE_INPUT:-16}G"
SSH_KEY_PATH="$HOME/.ssh/id_rsa.pub"
read -p "Enter container IP address with CIDR [192.168.0.2/24]: " IP_INPUT
IP="${IP_INPUT:-192.168.0.2/24}"
read -p "Enter gateway IP [192.168.0.1]: " GW_INPUT
GW="${GW_INPUT:-192.168.0.1}"

# Create the container
pct create $CTID $TEMPLATE \
  --hostname $CTNAME \
  --cores $CORES \
  --memory $MEMORY \
  --rootfs $STORAGE:$DISK_SIZE \
  --net0 name=eth0,bridge=vmbr0,ip=$IP,gw=$GW \
  --features nesting=1 \
  --unprivileged 1 \
  --ssh-public-keys $SSH_KEY_PATH

# Start the container
pct start $CTID

echo "LXC container $CTNAME ($CTID) created and started."

# Wait for container to boot and get network
sleep 10

# Install curl if not present, then install K3s
pct exec $CTID -- bash -c "apt-get update && apt-get install -y curl && curl -sfL https://get.k3s.io | sh -"

echo "K3s has been installed in container $CTNAME ($CTID)."