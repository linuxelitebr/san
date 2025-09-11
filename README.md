# Hitachi FC Storage Connectivity Issue

## Overview

This document describes a chronic Fibre Channel (FC) connectivity issue observed in OpenShift/Kubernetes clusters using Hitachi storage arrays. The problem manifests as intermittent loss of storage connectivity requiring manual intervention to restore service.

## Problem Description

Nodes in the cluster periodically lose connectivity to Hitachi storage volumes over Fibre Channel connections. When this occurs, affected nodes cannot access persistent volumes, causing pod failures and service disruptions.

### Symptoms

- Persistent Volume Claims (PVCs) fail to mount on affected nodes
- Running pods experience I/O errors when accessing storage
- New pods remain in `ContainerCreating` state indefinitely
- Multipath shows failed or offline paths to storage
- FC remote ports appear stale or disconnected
- SCSI devices become unresponsive despite appearing present in the system

### Impact

- Application downtime due to storage unavailability
- Pod scheduling failures on affected nodes
- Manual intervention required to restore service
- Potential data corruption if writes are interrupted

## Root Cause

The issue appears to stem from FC port negotiation failures between the Host Bus Adapter (HBA) and the Hitachi storage array. The exact trigger is intermittent but results in:

1. Loss of FC fabric connectivity
2. Stale SCSI device entries
3. Multipath path failures
4. Inability to recover automatically

## Current Workarounds

Operations teams typically resolve this issue through one of two methods:

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

- **Storage Arrays**: Hitachi VSP series
- **Protocols**: Fibre Channel (8Gb/16Gb/32Gb)
- **Operating Systems**: RHEL 8.x/9.x, RHCOS
- **Platforms**: OpenShift 4.x, Kubernetes 1.2x+
- **HBA Vendors**: Emulex (lpfc driver), QLogic (qla2xxx driver)

## Frequency

The issue occurs intermittently with varying frequency:
- Some environments: Daily
- Others: Weekly or monthly
- Triggers appear random with no clear pattern

## Business Impact

- **Service Availability**: Applications experience downtime
- **Operational Overhead**: Requires 24/7 manual intervention
- **SLA Risk**: Potential for extended outages if not promptly addressed

## Permanent Resolution

A permanent fix requires investigation at multiple levels:
- Storage array firmware updates
- HBA driver/firmware updates  
- FC switch configuration review
- Multipath configuration optimization

Until a root cause fix is implemented, operational workarounds are necessary to maintain service availability.

## References

- Red Hat Solution Article: [FC connectivity issues with Hitachi storage]
- Hitachi Technical Bulletin: [FC path stability recommendations]
- HBA Vendor Advisory: [Driver compatibility matrix]

---

*Note: This is a known issue affecting multiple production environments. Contact your storage vendor for the latest recommendations.*
