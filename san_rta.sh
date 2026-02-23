#!/bin/bash

# SPDX-License-Identifier: GPL-3.0-or-later
#
# FC Storage Test for OpenShift - Test FC storage connectivity and PVC mounting across all nodes
# v0.7
#
# Copyright (C) 2025 Linux Elite <info@linuxelite.com.br>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.

set -euo pipefail

# =============================================================================
# Command line options
# =============================================================================
ASSUME_YES=false
SPECIFIC_NODE=""
STORAGECLASS=""

usage() {
    cat <<EOF
Usage: $0 [OPTIONS] [STORAGECLASS]

Options:
  -n, --node <node>     Run only on specific node (skip auto-discovery)
  -y, --assume-yes      Automatic yes to all prompts
  -h, --help            Show this help

Examples:
  $0                                    # Auto-discover nodes and StorageClass
  $0 ocs-storagecluster-ceph-rbd        # Use specific StorageClass
  $0 -y                                 # Auto-confirm all prompts
  $0 -n worker-1 -y                     # Single node, no prompts
  $0 --node worker-1 my-storageclass    # Single node with specific StorageClass
  $0 -n worker-1 -y my-storageclass     # All options combined

EOF
    exit 0
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -n|--node)
            if [[ -z "${2:-}" ]]; then
                echo "ERROR: --node requires a node name"
                exit 1
            fi
            SPECIFIC_NODE="$2"
            shift 2
            ;;
        -y|--assume-yes)
            ASSUME_YES=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        -*)
            echo "ERROR: Unknown option: $1"
            echo ""
            usage
            ;;
        *)
            # Positional argument = StorageClass
            if [[ -z "$STORAGECLASS" ]]; then
                STORAGECLASS="$1"
            else
                echo "ERROR: Unexpected argument: $1"
                echo "StorageClass already set to: $STORAGECLASS"
                exit 1
            fi
            shift
            ;;
    esac
done

# Confirmation helper function - respects ASSUME_YES
confirm() {
    local prompt="$1"
    if [[ "$ASSUME_YES" == true ]]; then
        echo "${prompt}y (auto-confirmed)"
        return 0
    fi
    read -p "$prompt" -n 1 -r
    echo ""
    [[ $REPLY =~ ^[Yy]$ ]]
}

# =============================================================================
# Main script starts here
# =============================================================================

echo "=================================================================================="
echo "FC Storage Test Script v0.6"
echo "Cluster: $(oc whoami --show-server 2>/dev/null || echo 'Not logged in')"
echo "User: $(oc whoami 2>/dev/null || echo 'Not logged in')"
echo "Date: $(date)"
[[ -n "$SPECIFIC_NODE" ]] && echo "Target Node: $SPECIFIC_NODE"
[[ "$ASSUME_YES" == true ]] && echo "Mode: Non-interactive (--assume-yes)"
echo "=================================================================================="
echo ""

# Check if logged in
if ! oc whoami &> /dev/null; then
    echo "ERROR: Not logged into OpenShift cluster. Please run 'oc login' first."
    exit 1
fi

NAMESPACE="dummysan"
SIZE="1Gi"

# =============================================================================
# StorageClass selection logic
# =============================================================================
echo "=== StorageClass Selection ==="
if [[ -n "$STORAGECLASS" ]]; then
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
        if ! confirm "Continue with '$STORAGECLASS'? (y/N): "; then
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

# =============================================================================
# Namespace Setup
# =============================================================================
echo "=== Namespace Setup ==="
if oc get ns $NAMESPACE >/dev/null 2>&1; then
    echo "WARNING: Namespace $NAMESPACE already exists!"
    echo ""
    echo "This might be from a previous test run."
    if confirm "Delete existing namespace and start fresh? (y/N): "; then
        echo "Deleting namespace $NAMESPACE..."
        oc delete namespace $NAMESPACE --wait=true --timeout=60s
        echo "Namespace deleted. Waiting 5 seconds..."
        sleep 5
    else
        echo "Keeping existing namespace. Resources may conflict."
        if ! confirm "Continue anyway? (y/N): "; then
            echo "Aborted by user"
            exit 1
        fi
    fi
fi

if ! oc get ns $NAMESPACE >/dev/null 2>&1; then
    echo "Creating namespace: $NAMESPACE"
    oc create ns $NAMESPACE
    echo "Namespace created"
fi
echo ""

# =============================================================================
# Node Discovery
# =============================================================================
echo "=== Node Discovery ==="
if [[ -n "$SPECIFIC_NODE" ]]; then
    echo "Using specified node: $SPECIFIC_NODE"

    # Validate node exists
    if ! oc get node "$SPECIFIC_NODE" >/dev/null 2>&1; then
        echo "ERROR: Node '$SPECIFIC_NODE' not found!"
        echo ""
        echo "Available nodes:"
        oc get nodes -o custom-columns='NAME:.metadata.name,STATUS:.status.conditions[?(@.type=="Ready")].status,SCHEDULABLE:.spec.unschedulable'
        exit 1
    fi

    # Check if schedulable
    unschedulable=$(oc get node "$SPECIFIC_NODE" -o jsonpath='{.spec.unschedulable}' 2>/dev/null || echo "false")
    if [[ "$unschedulable" == "true" ]]; then
        echo "WARNING: Node '$SPECIFIC_NODE' is marked as unschedulable!"
        if ! confirm "Continue anyway? (y/N): "; then
            echo "Aborted by user"
            exit 1
        fi
    fi

    echo "✓ Node validated"
    nodes="$SPECIFIC_NODE"
else
    # Auto-discover all schedulable nodes
    nodes=$(oc get nodes -o json | jq -r '.items[] | select(.spec.unschedulable != true) | .metadata.name')
fi

if [[ -z "$nodes" ]]; then
    echo "ERROR: No schedulable nodes found"
    exit 1
fi

node_count=$(echo "$nodes" | wc -w)
echo "Found $node_count schedulable node(s):"
for node in $nodes; do
    echo "  - $node"
done
echo ""

# Arrays for tracking results
declare -a pvc_results
declare -a fc_results
declare -a pod_results

# =============================================================================
# PHASE 1: Create PVCs
# =============================================================================
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
    if oc wait "pvc/$pvc_name" -n "$NAMESPACE" --for=jsonpath='{.status.phase}'=Bound --timeout=60s 2>/dev/null; then
        pv_name=$(oc get pvc "$pvc_name" -n "$NAMESPACE" -o jsonpath='{.spec.volumeName}')
        echo "  ✓ Bound to PV: $pv_name"
        pvc_results+=("$node,$pvc_name,$pv_name,SUCCESS")
    else
        status=$(oc get pvc "$pvc_name" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "UNKNOWN")
        echo "  ✗ Failed to bind (Status: $status)"
        pvc_results+=("$node,$pvc_name,N/A,FAILED")
    fi
    echo ""
done

# =============================================================================
# PHASE 2: Test Pods (mount PVCs)
# =============================================================================
echo "=== PHASE 2: Testing PVC Mounts ==="
for node in $nodes; do
    pvc_name="pvc-${node//./-}"
    pod_name="pod-${node//./-}"

    # Check PVC status
    if ! oc get pvc "$pvc_name" -n "$NAMESPACE" >/dev/null 2>&1; then
        echo "Skipping $node - PVC not found"
        pod_results+=("$node,$pod_name,NO_PVC")
        continue
    fi

    pvc_phase=$(oc get pvc "$pvc_name" -n "$NAMESPACE" -o jsonpath='{.status.phase}')
    if [[ "$pvc_phase" != "Bound" ]]; then
        echo "Skipping $node - PVC not bound"
        pod_results+=("$node,$pod_name,PVC_NOT_BOUND")
        continue
    fi

    echo "Creating test pod on node: $node"

    # Delete if exists
    oc delete pod "$pod_name" -n "$NAMESPACE" --ignore-not-found=true >/dev/null 2>&1

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
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    fsGroup: 1000
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: test
    image: registry.access.redhat.com/ubi8/ubi-minimal:latest
    securityContext:
      allowPrivilegeEscalation: false
      capabilities:
        drop:
          - ALL
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
        phase=$(oc get pod "$pod_name" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")

        if [[ "$phase" == "Running" ]]; then
            echo "  ✓ Pod running"
            sleep 3
            echo "  Logs:"
            oc logs "$pod_name" -n "$NAMESPACE" 2>/dev/null | sed 's/^/    /'
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

# =============================================================================
# PHASE 3: FC Diagnostics
# =============================================================================
echo "=== PHASE 3: FC Diagnostics ==="

# Helper function to check if pod succeeded on a node
node_pod_succeeded() {
    local check_node="$1"
    for result in "${pod_results[@]}"; do
        IFS=',' read -r result_node _ result_status <<< "$result"
        if [[ "$result_node" == "$check_node" && "$result_status" == "SUCCESS" ]]; then
            return 0
        fi
    done
    return 1
}

for node in $nodes; do
    echo "Checking FC on node: $node"

    # Determine if we should skip LIP rescan
    skip_lip=false
    if node_pod_succeeded "$node"; then
        skip_lip=true
        echo "  → Pod mounted successfully on this node, will skip LIP rescan"
    fi

    # Build the FC check command - conditionally include LIP
    if [[ "$skip_lip" == true ]]; then
        fc_command='
    echo ; echo "=== FC Host Adapters ==="
    if [ -d /sys/class/fc_host ]; then
      for host in /sys/class/fc_host/host*; do
        if [ -d "$host" ]; then
          echo "$(basename $host):"
          [ -f "$host/port_name" ] && echo "  Port Name: $(cat $host/port_name 2>/dev/null)"
          [ -f "$host/port_state" ] && echo "  Port State: $(cat $host/port_state 2>/dev/null)"
          [ -f "$host/speed" ] && echo "  Speed: $(cat $host/speed 2>/dev/null)"
        fi
      done
      echo "Total FC hosts: $(ls -d /sys/class/fc_host/host* 2>/dev/null | wc -l)"
      echo ""
      echo "=== LIP Rescan: SKIPPED (storage working) ==="
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
'
    else
        fc_command='
    echo ; echo "=== FC Host Adapters ==="
    if [ -d /sys/class/fc_host ]; then
      for host in /sys/class/fc_host/host*; do
        if [ -d "$host" ]; then
          echo "$(basename $host):"
          [ -f "$host/port_name" ] && echo "  Port Name: $(cat $host/port_name 2>/dev/null)"
          [ -f "$host/port_state" ] && echo "  Port State: $(cat $host/port_state 2>/dev/null)"
          [ -f "$host/speed" ] && echo "  Speed: $(cat $host/speed 2>/dev/null)"
        fi
      done

      echo "Total FC hosts: $(ls -d /sys/class/fc_host/host* 2>/dev/null | wc -l)"

      echo ""
      echo "=== Executing FC LIP Rescan ==="
      for host in /sys/class/fc_host/host*; do
        if [ -d "$host" ]; then
          echo "  Issuing LIP on $(basename $host)"
          echo 1 > $host/issue_lip 2>/dev/null || true
        fi
        sleep 10
      done
      echo "  LIP rescan completed"

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
'
    fi

    if fc_output=$(oc debug "node/$node" -- chroot /host bash -c "$fc_command" 2>&1); then
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

# =============================================================================
# PHASE 4: Retry Failed Pods
# =============================================================================
echo "=== PHASE 4: Retry Failed Pods ==="

# Identify TIMEOUT pods
timeout_pods=""
for result in "${pod_results[@]}"; do
    if [[ "$result" == *"TIMEOUT"* ]]; then
        IFS=',' read -r node _ _ <<< "$result"
        timeout_pods="$timeout_pods $node"
    fi
done

if [[ -n "${timeout_pods// /}" ]]; then
    echo "Found pods that timed out on nodes:$timeout_pods"
    echo ""

    if confirm "Retry these pods? (y/N): "; then
        # Remove old results for retry nodes
        new_pod_results=()
        for result in "${pod_results[@]}"; do
            if [[ "$result" != *"TIMEOUT"* ]]; then
                new_pod_results+=("$result")
            fi
        done
        pod_results=("${new_pod_results[@]}")

        # Retry each timeout node
        for node in $timeout_pods; do
            pvc_name="pvc-${node//./-}"
            pod_name="pod-${node//./-}"

            echo "Retrying pod on node: $node"

            # Delete existing pod
            oc delete pod "$pod_name" -n "$NAMESPACE" --ignore-not-found=true >/dev/null 2>&1

            # Recreate pod with COMPLETE YAML
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
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: test
    image: registry.access.redhat.com/ubi8/ubi-minimal:latest
    securityContext:
      allowPrivilegeEscalation: false
      capabilities:
        drop:
          - ALL
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

            # Wait with increased timeout (120s)
            echo "  Waiting for pod (120s timeout - extended)..."
            timeout=120
            elapsed=0

            while [[ $elapsed -lt $timeout ]]; do
                phase=$(oc get pod "$pod_name" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")

                if [[ "$phase" == "Running" ]]; then
                    echo "  ✓ Pod running (retry successful)"
                    sleep 3
                    echo "  Logs:"
                    oc logs "$pod_name" -n "$NAMESPACE" 2>/dev/null | sed 's/^/    /'
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
                echo "  ✗ Timeout waiting for pod (retry failed)"
                pod_results+=("$node,$pod_name,TIMEOUT_RETRY")
            fi

            echo ""
        done
    else
        echo "Skipping retry"
    fi
else
    echo "No pods with timeout to retry"
fi
echo ""

# =============================================================================
# Summary
# =============================================================================
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
    IFS=',' read -r node _ _ status <<< "$result"
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
    IFS=',' read -r node _ status <<< "$result"
    printf "  %-30s %s\n" "$node:" "$status"
done
echo ""

# Show running pods
echo "Running pods:"
oc get pods -n $NAMESPACE -o wide

# =============================================================================
# Cleanup
# =============================================================================
echo ""
echo "=================================================================================="
if confirm "Delete test resources? (y/N): "; then
    echo "Deleting namespace $NAMESPACE..."
    oc delete namespace $NAMESPACE
    echo "Cleanup completed"
else
    echo "Resources kept in namespace: $NAMESPACE"
    echo "To cleanup manually: oc delete namespace $NAMESPACE"
fi

echo ""

if [[ $successful_pvcs -lt $total_nodes ]] || [[ $successful_pods -lt $total_nodes ]]; then
    echo "Script completed with failures!"
    exit 1
fi

echo "Script completed!"
