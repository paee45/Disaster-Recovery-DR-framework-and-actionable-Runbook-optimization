# Local post-restore primary adoption

This stage adopts an already-restored local Moto RDS instance into a separate Terraform state. It does not modify or remove the old primary/replica state owned by `iac/local/mock`, and it does not create a replica. DEV is single-primary; replica normalization is a separate topology change.

Run from the tools runner after parity/hardening and owner review:

```sh
bash iac/local.sh normalization plan \
  -var=restored_db_id=app-pg-local-p202610131437 \
  -var=baseline_file=/workspace/tests/local/.state/baselines/baseline-app-pg-local-20261013T142817Z.json \
  -var=dr_id=DR-20261013-1437-local-S4 \
  -var=restore_time=2026-10-13T14:42:01Z \
  -out=adopt-restored.plan
```

Review the saved plan before applying it. The acceptable plan imports `aws_db_instance.active` without changing or replacing the RDS instance and creates only the generated `tests/local/.state/normalization.env` override. Stop if it proposes any RDS update, replacement, or deletion. Apply only the reviewed saved plan.

After apply, `iac/local/dr.sh` reads the generated override so later local DR runs use the adopted primary. Keep the S4 evidence and old DB fence until reconciliation is signed off. The restored Moto instance and this state are local-only; they do not represent real AWS resources or a production IaC adoption.
