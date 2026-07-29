#!/bin/bash
echo "=== Systemd Triggered Storage Flush ==="

if command -v kubectl &>/dev/null && kubectl get nodes &>/dev/null; then
    echo "Scaling down MariaDB to flush InnoDB buffers..."
    kubectl scale statefulset mariadb-server -n openstack --replicas=0 2>/dev/null || true

    for i in {1..6}; do
        PODS=$(kubectl get pods -n openstack -l app.kubernetes.io/name=mariadb --no-headers 2>/dev/null | wc -l)
        if [ "$PODS" -eq 0 ]; then
            echo "MariaDB stopped cleanly."
            break
        fi
        sleep 5
    done
fi

mount | grep 'kubelet' | awk '{print $3}' | while read -r mount; do
    umount -f -l "$mount"
done

if [ -b /dev/loop100 ]; then
    echo "Flushing block device buffers..."
    blockdev --flushbufs /dev/loop100 2>/dev/null
fi

losetup -D
