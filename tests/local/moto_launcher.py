"""Start moto server (RDS/EC2 mock) with one fix so it behaves like real RDS.

Real RDS clears ReadReplicaSourceDBInstanceIdentifier after promote-read-replica; moto 5.x keeps it, which would make
dr-verify.sh wait-promoted (correctly) wait forever. We patch the MOCK, never the scripts under test.
"""
import sys

import moto.rds.models as rds_models
from moto.server import main

_orig_promote = rds_models.RDSBackend.promote_read_replica


def _promote(self, db_kwargs):
    db = _orig_promote(self, db_kwargs)
    source_id = db.source_db_instance_identifier
    db.source_db_instance_identifier = None
    try:
        primary = self.find_db_from_id(source_id) if source_id else None
        if primary is not None and db.db_instance_identifier in getattr(primary, "read_replica_db_instance_identifiers", []):
            primary.read_replica_db_instance_identifiers.remove(db.db_instance_identifier)
    except Exception:  # best effort; the source may be gone
        pass
    return db


rds_models.RDSBackend.promote_read_replica = _promote

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
