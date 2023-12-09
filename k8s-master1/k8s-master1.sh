#!/bin/bash

LISTEN_ADDRESS=172.16.0.1
LISTEN_PORT=8080

VM_NAME="$(basename "$(test -L "$0" && readlink "$0" || echo "$0")" | cut -d. -f1)"

if ! grep ${VM_NAME} <<<$(virsh -q list) >/dev/null 2>&1; then
	sudo virt-install \
		--name ${VM_NAME} \
		--virt-type kvm \
		--accelerate \
		--os-variant ubuntu23.04 \
		--vcpus 2 \
		--memory 6144 \
		--serial pty \
		--graphics none \
		--console pty,target_type=virtio \
		--location /var/lib/libvirt/images/ubuntu-23.10-live-server-amd64.iso,kernel=casper/vmlinuz,initrd=casper/initrd \
		--extra-args "console=ttyS0 quiet autoinstall ds=nocloud-net;s=http://${LISTEN_ADDRESS}:${LISTEN_PORT}/${VM_NAME}/" \
		--network network=default,model=virtio,mac=52:54:00:ff:ff:01 \
		--network network=default,model=virtio,mac=52:54:00:ff:fe:01 \
		--disk size=30,pool=k8s \
		--debug
fi
