---
name: bi-iscsi-restore
version: 1.0
description: >
  BI iSCSI snapshot restore workflow for the VM/iSCSI SVM. Use this runbook to create a
  temporary FlexClone from an existing ONTAP snapshot, locate and map its LUN,
  bring the LUN online/offline, and clean up the restore clone.
---

# BI iSCSI Restore Workflow

## Scope

Placeholders below (`<vm-svm>`, `<bi-source-volume>`, `<igroup>`) are per-site values.
Resolve them from `config.json` or `.github/Netapp Cases/` — both gitignored. Never commit real names here.

This workflow is restricted to:

- SVM: `<vm-svm>`
- BI source volume: `<bi-source-volume>`
- Source volumes whose names contain `proxmox`
- Restore clone names beginning with:

```text
proxmox_restore_agent_PROXMOX_
```

Do not use the workflow against another SVM, an original/base volume, or a clone outside the approved prefix.

## Supported operations

The restore account can:

- List snapshots on the BI source volume.
- Create a read-write FlexClone from an existing snapshot.
- List LUNs and mappings on restore clones.
- Create and delete LUN mappings on restore clones.
- Bring restore LUNs online or offline.
- Delete only restore-clone volumes using the approved prefix.

The account cannot create or delete snapshots.

## 1. Select an existing snapshot

List snapshots on the source volume:

```text
volume snapshot show -vserver <vm-svm> -volume <bi-source-volume>
```

Use an existing snapshot name. Do not create or delete a snapshot as part of this workflow.

## 2. Create the FlexClone

Use a unique clone name that starts with the approved prefix:

```text
volume clone create -vserver <vm-svm> -flexclone proxmox_restore_agent_PROXMOX_<unique-id> -type RW -parent-volume <bi-source-volume> -parent-snapshot <snapshot-name> -junction-active false -vserver-dr-protection unprotected -foreground true
```

`-vserver-dr-protection unprotected` is required when the parent volume is unprotected in the Vserver DR relationship. Without it, ONTAP may reject the clone even when the command syntax and RBAC are correct.

Wait for the job to succeed before continuing.

## 3. Locate the cloned LUN

```text
lun show -vserver <vm-svm> -volume proxmox_restore_agent_PROXMOX_<unique-id>
```

Record the exact LUN path returned by ONTAP. It will be similar to:

```text
/vol/proxmox_restore_agent_PROXMOX_<unique-id>/<lun-name>.lun
```

## 4. Map the cloned LUN

Use the approved target igroup. The existing Proxmox igroup is:

```text
Proxmox
```

Create the mapping using the exact LUN path returned by `lun show`:

```text
lun mapping create -vserver <vm-svm> -path /vol/proxmox_restore_agent_PROXMOX_<unique-id>/<lun-name>.lun -igroup <igroup>
```

Verify the mapping:

```text
lun mapping show -vserver <vm-svm> -path /vol/proxmox_restore_agent_PROXMOX_<unique-id>/<lun-name>.lun -fields vserver,path,igroup,lun-id,protocol
```

The mapping command allocates the LUN ID; do not add `-lun-id` to `lun mapping create` on this ONTAP version. Verify the assigned ID after creation. LUN ID is a mapping identifier inside an igroup, not the unique identity of the LUN.

## 5. Online/offline

Use the exact LUN path:

```text
lun offline -vserver <vm-svm> -path /vol/proxmox_restore_agent_PROXMOX_<unique-id>/<lun-name>.lun
lun online -vserver <vm-svm> -path /vol/proxmox_restore_agent_PROXMOX_<unique-id>/<lun-name>.lun
```

Verify state with:

```text
lun show -vserver <vm-svm> -path /vol/proxmox_restore_agent_PROXMOX_<unique-id>/<lun-name>.lun
```

## 6. Cleanup

Delete the mapping first:

```text
lun mapping delete -vserver <vm-svm> -path /vol/proxmox_restore_agent_PROXMOX_<unique-id>/<lun-name>.lun -igroup <igroup>
```

Then take the clone volume offline and delete it:

```text
volume offline -vserver <vm-svm> -volume proxmox_restore_agent_PROXMOX_<unique-id>
volume delete -vserver <vm-svm> -volume proxmox_restore_agent_PROXMOX_<unique-id>
```

Verify cleanup:

```text
volume show -vserver <vm-svm> -volume proxmox_restore_agent_PROXMOX_<unique-id>
lun mapping show -vserver <vm-svm> -volume proxmox_restore_agent_PROXMOX_<unique-id>
```

Both commands should return no matching entries.

## API limitation

If API access is required, access to the OpenShift project hosting the MCP services is required. The native ONTAP API does not support the same fine-grained restrictions, so the restrictions described above cannot be applied directly through the API.

## Validation note

The following workflow was validated with an administrative ONTAP account on `<vm-svm>`: clone from the current snapshot, locate the cloned LUN, create a mapping to an isolated test igroup, verify LUN ID allocation, execute and verify `lun offline`, execute and verify `lun online`, then remove the mapping, test igroup, and clone.

The validation confirms command syntax and workflow. It does not replace a separate effective-permission test using the `prox-restore` account after its SSH public key is installed.
