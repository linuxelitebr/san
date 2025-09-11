# SAN FC Storage Connectivity Issue

## Overview

This document describes a Fibre Channel (FC) connectivity issue observed in OpenShift/Kubernetes clusters using SAN storage arrays.  
The problem occurs **only on nodes that have not yet had any LUN mapped**. Once a LUN has been successfully mapped, no intermittent connectivity losses are observed.

## Problem Description

When a new node in the cluster has no LUNs previously mapped, it may fail to establish initial connectivity with SAN storage volumes over Fibre Channel connections.  
This prevents the node from accessing persistent volumes until manual intervention is performed.

### Symptoms

- Persistent Volume Claims (PVCs) fail to mount on newly added nodes
- New pods scheduled on these nodes remain in `ContainerCreating` state indefinitely
- Multipath shows no active paths until connectivity is established
- FC remote ports appear stale or disconnected
- SCSI devices do not register until a manual rescan or reset is triggered

### Impact

- Applications cannot start on nodes without mapped LUNs
- Pod scheduling failures on affected nodes
- Manual intervention required to initialize storage connectivity

## Root Cause

The issue appears to stem from FC port negotiation failures between the Host Bus Adapter (HBA) and the SAN storage array during the **first LUN mapping event on a node**.  
After a successful mapping, the node maintains stable connectivity with no further issues.

## Current Workarounds

Operations teams can resolve this issue through one of two methods:

### Option 1: HBA Port Reset

Force a Fibre Channel Link Initialization Protocol (LIP) to renegotiate the connection:

```bash
echo 1 > /sys/class/fc_host/host*/issue_lip
echo "- - -" > /sys/class/scsi_host/host*/scan
```

### Option 2: Node Reboot

Complete node restart to fully reinitialize all storage paths:

```bash
systemctl reboot
```

## Affected Components

- **Storage Arrays**: SAN manufactures
- **Protocols**: Fibre Channel (8Gb/16Gb/32Gb)
- **Operating Systems**: RHEL 8.x/9.x, RHCOS
- **Platforms**: OpenShift 4.x, Kubernetes 1.2x+
- **HBA Vendors**: Emulex (lpfc driver), QLogic (qla2xxx driver)

## Permanent Resolution

A permanent fix requires investigation at multiple levels:

- Storage array firmware updates
- HBA driver/firmware updates  
- FC switch configuration review
- Multipath configuration optimization

Until a root cause fix is implemented, operational workarounds are necessary to maintain service availability.

---

*Note: This is a known issue affecting only initial LUN discovery on nodes without previously mapped LUNs. Once the first LUN is successfully mapped, connectivity remains stable with no intermittent losses.*
