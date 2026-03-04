#!/bin/bash

set -e

# Get next available container ID
DEFAULT_CTID=$(pvesh get /cluster/nextid 2>/dev/null || echo 100)
read -p "Enter container ID [$DEFAULT_CTID]: " CTID_INPUT
CTID="${CTID_INPUT:-$DEFAULT_CTID}"

read -p "Enter container name [k3s-master]: " CTNAME_INPUT
CTNAME="${CTNAME_INPUT:-k3s-master}"

# Get available storage names from host
mapfile -t AVAILABLE_STORAGES < <(pvesm status | awk 'NR>1 {print $1}')
DEFAULT_STORAGE="${AVAILABLE_STORAGES[0]}"

# Validate template storage name
echo "Available storage options: ${AVAILABLE_STORAGES[*]}"
while true; do
  read -p "Enter template storage name [local]: " TEMPLATE_STORAGE_INPUT
  TEMPLATE_STORAGE="${TEMPLATE_STORAGE_INPUT:-local}"
  if [[ " ${AVAILABLE_STORAGES[@]} " =~ " $TEMPLATE_STORAGE " ]]; then
    break
  else
    echo "Invalid storage name. Available options: ${AVAILABLE_STORAGES[*]}"
  fi
done

TEMPLATE="$TEMPLATE_STORAGE:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst"  # Use the latest

# Validate rootfs storage name
echo "Available storage options: ${AVAILABLE_STORAGES[*]}"
while true; do
  read -p "Enter rootfs storage name [$DEFAULT_STORAGE]: " STORAGE_INPUT
  STORAGE="${STORAGE_INPUT:-$DEFAULT_STORAGE}"
  if [[ " ${AVAILABLE_STORAGES[@]} " =~ " $STORAGE " ]]; then
    break
  else
    echo "Invalid storage name. Available options: ${AVAILABLE_STORAGES[*]}"
  fi
done

# Prompt for cores, memory, disk size, IP and GW with defaults
read -p "Enter number of CPU cores [2]: " CORES_INPUT
CORES="${CORES_INPUT:-2}"
read -p "Enter memory size in MB [2048]: " MEMORY_INPUT
MEMORY="${MEMORY_INPUT:-2048}"

# Validate disk size
while true; do
  read -p "Enter disk size in GB [16]: " DISK_SIZE_INPUT
  DISK_SIZE="${DISK_SIZE_INPUT:-16}"
  if [[ "$DISK_SIZE" =~ ^[0-9]+$ ]]; then
    break
  else
    echo "Disk size must be a positive integer (do not include 'G')."
  fi
done

SSH_KEY_PATH="$HOME/.ssh/id_rsa.pub"
read -p "Enter container IP address with CIDR [192.168.0.2/24]: " IP_INPUT
IP="${IP_INPUT:-192.168.0.2/24}"
read -p "Enter gateway IP [192.168.0.1]: " GW_INPUT
GW="${GW_INPUT:-192.168.0.1}"

# Load required kernel modules on the host for K3s
echo "Loading required kernel modules on host..."
modprobe overlay
modprobe br_netfilter
# Persist modules across reboots
echo -e "overlay\nbr_netfilter" > /etc/modules-load.d/k3s.conf

# Create the container
pct create $CTID $TEMPLATE \
  --hostname $CTNAME \
  --cores $CORES \
  --memory $MEMORY \
  --rootfs $STORAGE:${DISK_SIZE} \
  --net0 name=eth0,bridge=vmbr0,ip=$IP,gw=$GW \
  --features nesting=1,keyctl=1,mknod=1 \
  --unprivileged 0 \
  --swap 0 \
  --ssh-public-keys $SSH_KEY_PATH

# Start the container
pct start $CTID

# Apply additional LXC config required for K3s
LXC_CONF="/etc/pve/lxc/${CTID}.conf"
echo "Applying LXC config for K3s compatibility..."
cat >> "$LXC_CONF" <<EOF
lxc.apparmor.profile: unconfined
lxc.cap.drop:
lxc.cgroup2.devices.allow: a
lxc.mount.auto: proc:rw sys:rw cgroup:rw
EOF

# Restart container to apply new config
pct stop $CTID
pct start $CTID

echo "LXC container $CTNAME ($CTID) created and started."

# Wait for container to boot and get network
sleep 10

# Install curl if not present, then install K3s
CONTAINER_IP="${IP%%/*}"  # Strip CIDR suffix

# Create /dev/kmsg if missing (required by kubelet in LXC)
pct exec $CTID -- bash -c "
  if [ ! -e /dev/kmsg ]; then
    mknod /dev/kmsg c 1 11
    chmod 640 /dev/kmsg
  fi
  # Persist across reboots via rc.local
  grep -q 'kmsg' /etc/rc.local 2>/dev/null || \
    echo 'mknod /dev/kmsg c 1 11 2>/dev/null; chmod 640 /dev/kmsg 2>/dev/null' >> /etc/rc.local
  chmod +x /etc/rc.local
"
pct exec $CTID -- bash -c "apt-get update && apt-get install -y curl && \
  curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC='server \
  --bind-address=0.0.0.0 \
  --advertise-address=$CONTAINER_IP \
  --tls-san=$CONTAINER_IP \
  --node-ip=$CONTAINER_IP' sh -"

echo "K3s has been installed in container $CTNAME ($CTID)."

# Wait for K3s to be ready
echo "Waiting for K3s to be ready on port 6443..."
K3S_TIMEOUT=300
K3S_ELAPSED=0
while ! pct exec $CTID -- bash -c "ss -tlnp | grep -q ':6443'" 2>/dev/null; do
  if [[ $K3S_ELAPSED -ge $K3S_TIMEOUT ]]; then
    echo "ERROR: K3s did not become ready within ${K3S_TIMEOUT}s. Check logs with: pct exec $CTID -- journalctl -u k3s"
    exit 1
  fi
  echo "  K3s not ready yet, retrying in 5s... (${K3S_ELAPSED}s/${K3S_TIMEOUT}s)"
  sleep 5
  K3S_ELAPSED=$((K3S_ELAPSED + 5))
done
echo "K3s is ready."

# Extract kubeconfig and replace the server address with the container IP
KUBECONFIG_PATH="$HOME/.kube/$CTNAME.yaml"
mkdir -p "$HOME/.kube"
pct exec $CTID -- cat /etc/rancher/k3s/k3s.yaml | \
  sed -e "s/127.0.0.1/$CONTAINER_IP/g" -e "s/0\.0\.0\.0/$CONTAINER_IP/g" > "$KUBECONFIG_PATH"
chmod 600 "$KUBECONFIG_PATH"

echo ""
echo "Kubeconfig saved to: $KUBECONFIG_PATH"
echo "To use kubectl with this cluster, run:"
echo "  export KUBECONFIG=$KUBECONFIG_PATH"
echo "  kubectl get nodes"