#!/bin/bash
set -euo pipefail

# Script: FC Storage Test for OpenShift
# Purpose: Test FC storage connectivity and PVC mounting across all nodes
# v0.2

echo "=================================================================================="
echo "FC Storage Test Script - Simplified"
echo "Cluster: $(oc whoami --show-server 2>/dev/null || echo 'Not logged in')"
echo "User: $(oc whoami 2>/dev/null || echo 'Not logged in')"
echo "Date: $(date)"
echo "=================================================================================="
echo ""

# Check if logged in
if ! oc whoami &> /dev/null; then
    echo "ERROR: Not logged into OpenShift cluster. Please run 'oc login' first."
    exit 1
fi

NAMESPACE="dummysan"
SIZE="1Gi"

# StorageClass selection logic
echo "=== StorageClass Selection ==="
if [[ $# -ge 1 ]]; then
  STORAGECLASS="$1"
  echo "Using specified StorageClass: $STORAGECLASS"
else
  echo "No StorageClass specified, looking for defaults..."

  # Get all default storage classes (returns space-separated list)
  DEFAULT_SCS=$(oc get sc -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}' 2>/dev/null || echo "")

  if [[ -z "$DEFAULT_SCS" ]]; then
    echo ""
    echo "ERROR: No default StorageClass found!"
    echo ""
    echo "Available StorageClasses:"
    oc get sc -o custom-columns='NAME:.metadata.name,DEFAULT:.metadata.annotations.storageclass\.kubernetes\.io/is-default-class,PROVISIONER:.provisioner'
    echo ""
    echo "Please specify a StorageClass:"
    echo "  $0 <storageclass-name>"
    echo ""
    echo "Example:"
    echo "  $0 ocs-storagecluster-ceph-rbd"
    exit 1
  fi

  # Convert to array for easier handling
  IFS=' ' read -ra SC_ARRAY <<< "$DEFAULT_SCS"
  DEFAULT_COUNT=${#SC_ARRAY[@]}

  if [[ $DEFAULT_COUNT -eq 1 ]]; then
    STORAGECLASS="${SC_ARRAY[0]}"
    echo "Found single default StorageClass: $STORAGECLASS"
  else
    echo ""
    echo "Found $DEFAULT_COUNT default StorageClasses:"
    for i in "${!SC_ARRAY[@]}"; do
      echo "  $((i+1)). ${SC_ARRAY[$i]}"
    done
    echo ""

    # Use the first one by default
    STORAGECLASS="${SC_ARRAY[0]}"
    echo "Will use the first one: $STORAGECLASS"
    echo ""
    echo "To use a different one, run:"
    echo "  $0 <storageclass-name>"
    echo ""
    read -p "Continue with '$STORAGECLASS'? (y/N): " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      echo "Aborted by user"
      echo ""
      echo "Available options:"
      for sc in "${SC_ARRAY[@]}"; do
        echo "  $0 $sc"
      done
      exit 1
    fi
  fi
fi

# Validate the selected StorageClass
echo ""
echo "Validating StorageClass: $STORAGECLASS"
if ! oc get sc "$STORAGECLASS" >/dev/null 2>&1; then
  echo "ERROR: StorageClass '$STORAGECLASS' not found!"
  echo ""
  echo "Available StorageClasses:"
  oc get sc
  exit 1
fi

echo "✓ StorageClass validated"
echo ""
echo "StorageClass details:"
oc get sc "$STORAGECLASS" -o wide
echo ""

# Create namespace
echo "=== Namespace Setup ==="
if ! oc get ns $NAMESPACE >/dev/null 2>&1; then
  echo "Creating namespace: $NAMESPACE"
  oc create ns $NAMESPACE
else
  echo "Namespace $NAMESPACE already exists"
fi
echo ""

# Get nodes
echo "=== Node Discovery ==="
nodes=$(oc get nodes -o json | jq -r '.items[] | select(.spec.unschedulable != true) | .metadata.name')

if [[ -z "$nodes" ]]; then
  echo "ERROR: No schedulable nodes found"
  exit 1
fi

node_count=$(echo "$nodes" | wc -w)
echo "Found $node_count schedulable nodes:"
for node in $nodes; do
  echo "  - $node"
done
echo ""

# Arrays for tracking results
declare -a pvc_results
declare -a fc_results
declare -a pod_results

# Phase 1: Create PVCs
echo "=== PHASE 1: Creating PVCs ==="
for node in $nodes; do
  pvc_name="pvc-${node//./-}"

  echo "Creating PVC for node: $node"

  cat <<EOF | oc apply -n $NAMESPACE -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $pvc_name
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: $SIZE
  storageClassName: $STORAGECLASS
EOF

  # Wait for binding
  echo "  Waiting for PVC to bind (60s timeout)..."
  if oc wait pvc/$pvc_name -n $NAMESPACE --for=jsonpath='{.status.phase}'=Bound --timeout=60s 2>/dev/null; then
    pv_name=$(oc get pvc $pvc_name -n $NAMESPACE -o jsonpath='{.spec.volumeName}')
    echo "  ✓ Bound to PV: $pv_name"
    pvc_results+=("$node,$pvc_name,$pv_name,SUCCESS")
  else
    status=$(oc get pvc $pvc_name -n $NAMESPACE -o jsonpath='{.status.phase}' 2>/dev/null || echo "UNKNOWN")
    echo "  ✗ Failed to bind (Status: $status)"
    pvc_results+=("$node,$pvc_name,N/A,FAILED")
  fi
  echo ""
done

# Phase 2: FC Debug
echo "=== PHASE 2: FC Diagnostics ==="
for node in $nodes; do
  echo "Checking FC on node: $node"

  fc_output=$(oc debug node/$node -- chroot /host bash -c '
    echo "=== FC Host Adapters ==="
    if [ -d /sys/class/fc_host ]; then
      for host in /sys/class/fc_host/host*; do
        if [ -d "$host" ]; then
          echo "$(basename $host):"
          [ -f "$host/port_name" ] && echo "  Port Name: $(cat $host/port_name 2>/dev/null)"
          [ -f "$host/port_state" ] && echo "  Port State: $(cat $host/port_state 2>/dev/null)"
          [ -f "$host/speed" ] && echo "  Speed: $(cat $host/speed 2>/dev/null)"
        fi
      for host in /sys/class/fc_host/host*; do echo 1 > /sys/class/fc_host/$(basename $host)/issue_lip ; done
      done
      echo "Total FC hosts: $(ls -d /sys/class/fc_host/host* 2>/dev/null | wc -l)"
    else
      echo "No FC hosts found"
    fi

    echo ""
    echo "=== Multipath Devices ==="
    if command -v multipath >/dev/null 2>&1; then
      multipath -ll | head -20
    else
      echo "Multipath not available"
    fi
  ' 2>&1)

  if [[ $? -eq 0 ]]; then
    echo "$fc_output" | head -30
    fc_results+=("$node,SUCCESS")
    echo "✓ FC check completed"
  else
    echo "✗ FC check failed"
    fc_results+=("$node,FAILED")
  fi
  echo "----------------------------------------"
  echo ""
done

# Phase 3: Test Pods
echo "=== PHASE 3: Testing PVC Mounts ==="
for node in $nodes; do
  pvc_name="pvc-${node//./-}"
  pod_name="pod-${node//./-}"

  # Check PVC status
  if ! oc get pvc $pvc_name -n $NAMESPACE >/dev/null 2>&1; then
    echo "Skipping $node - PVC not found"
    pod_results+=("$node,$pod_name,NO_PVC")
    continue
  fi

  pvc_phase=$(oc get pvc $pvc_name -n $NAMESPACE -o jsonpath='{.status.phase}')
  if [[ "$pvc_phase" != "Bound" ]]; then
    echo "Skipping $node - PVC not bound"
    pod_results+=("$node,$pod_name,PVC_NOT_BOUND")
    continue
  fi

  echo "Creating test pod on node: $node"

  # Delete if exists
  oc delete pod $pod_name -n $NAMESPACE --ignore-not-found=true >/dev/null 2>&1

  # Create test pod
  cat <<EOF | oc apply -n $NAMESPACE -f -
apiVersion: v1
kind: Pod
metadata:
  name: $pod_name
  labels:
    test: fc-storage
spec:
  nodeSelector:
    kubernetes.io/hostname: $node
  containers:
  - name: test
    image: registry.access.redhat.com/ubi8/ubi-minimal:latest
    command: ["/bin/bash", "-c"]
    args:
    - |
      echo "Testing storage mount..."
      df -h /mnt/test
      echo "Write test..."
      date > /mnt/test/test.txt && echo "✓ Write successful" || echo "✗ Write failed"
      ls -la /mnt/test/
      sleep 3600
    volumeMounts:
    - mountPath: /mnt/test
      name: storage
    resources:
      limits:
        memory: "128Mi"
        cpu: "100m"
  volumes:
  - name: storage
    persistentVolumeClaim:
      claimName: $pvc_name
  restartPolicy: Never
EOF

  # Wait for pod
  echo "  Waiting for pod to start (90s timeout)..."
  timeout=90
  elapsed=0

  while [[ $elapsed -lt $timeout ]]; do
    phase=$(oc get pod $pod_name -n $NAMESPACE -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")

    if [[ "$phase" == "Running" ]]; then
      echo "  ✓ Pod running"
      sleep 3
      echo "  Logs:"
      oc logs $pod_name -n $NAMESPACE 2>/dev/null | sed 's/^/    /'
      pod_results+=("$node,$pod_name,SUCCESS")
      break
    elif [[ "$phase" == "Failed" ]] || [[ "$phase" == "Error" ]]; then
      echo "  ✗ Pod failed: $phase"
      pod_results+=("$node,$pod_name,FAILED")
      break
    fi

    sleep 5
    elapsed=$((elapsed + 5))

    if [[ $((elapsed % 15)) -eq 0 ]]; then
      echo "    Still waiting... ($elapsed/$timeout seconds)"
    fi
  done

  if [[ $elapsed -ge $timeout ]]; then
    echo "  ✗ Timeout waiting for pod"
    pod_results+=("$node,$pod_name,TIMEOUT")
  fi

  echo ""
done

# Summary
echo "=================================================================================="
echo "=== SUMMARY ==="
echo "=================================================================================="
echo ""

# Calculate stats
total_nodes=$node_count
successful_pvcs=0
successful_fc=0
successful_pods=0

for result in "${pvc_results[@]}"; do
  [[ "$result" == *"SUCCESS"* ]] && ((successful_pvcs++)) || true
done

for result in "${fc_results[@]}"; do
  [[ "$result" == *"SUCCESS"* ]] && ((successful_fc++)) || true
done

for result in "${pod_results[@]}"; do
  [[ "$result" == *"SUCCESS"* ]] && ((successful_pods++)) || true
done

echo "Test Results:"
echo "-------------"
echo "Total Nodes:        $total_nodes"
echo "PVCs Bound:         $successful_pvcs/$total_nodes"
echo "FC Checks Passed:   $successful_fc/$total_nodes"
echo "Pods Running:       $successful_pods/$total_nodes"
echo ""

# Detailed results
echo "PVC Status:"
for result in "${pvc_results[@]}"; do
  IFS=',' read -r node pvc pv status <<< "$result"
  printf "  %-30s %s\n" "$node:" "$status"
done
echo ""

echo "FC Status:"
for result in "${fc_results[@]}"; do
  IFS=',' read -r node status <<< "$result"
  printf "  %-30s %s\n" "$node:" "$status"
done
echo ""

echo "Pod Status:"
for result in "${pod_results[@]}"; do
  IFS=',' read -r node pod status <<< "$result"
  printf "  %-30s %s\n" "$node:" "$status"
done
echo ""

# Show running pods
echo "Running pods:"
oc get pods -n $NAMESPACE -o wide

# Cleanup
echo ""
echo "=================================================================================="
read -p "Delete test resources? (y/N): " -n 1 -r
echo ""
if [[ $REPLY =~ ^[Yy]$ ]]; then
  echo "Deleting namespace $NAMESPACE..."
  oc delete namespace $NAMESPACE
  echo "Cleanup completed"
else
  echo "Resources kept in namespace: $NAMESPACE"
  echo "To cleanup manually: oc delete namespace $NAMESPACE"
fi

echo ""
echo "Script completed!"
