"""Start the pinned Moto mock with RDS identity, field round-trip and promotion parity."""
import sys
import uuid
from copy import deepcopy
from types import GeneratorType

import moto
import moto.rds.models as rds_models
from jinja2 import Template
from moto.rds.responses import RDSResponse
from moto.server import main

if moto.__version__ != "5.0.28":
    raise RuntimeError("RDS parity patches require Moto 5.0.28")

_fields = {
    "backup_target": ("BackupTarget", "region"),
    "monitoring_role_arn": ("MonitoringRoleArn", None),
    "monitoring_interval": ("MonitoringInterval", 0),
    "performance_insights_enabled": ("EnablePerformanceInsights", False),
    "performance_insights_kms_key_id": ("PerformanceInsightsKMSKeyId", None),
    "performance_insights_retention_period": ("PerformanceInsightsRetentionPeriod", 7),
    "database_insights_mode": ("DatabaseInsightsMode", "standard"),
    "network_type": ("NetworkType", "IPV4"),
    "engine_lifecycle_support": ("EngineLifecycleSupport", "open-source-rds-extended-support"),
    "ca_certificate_identifier": ("CACertificateIdentifier", None),
}
_orig_db_kwargs = RDSResponse._get_db_kwargs


def _get_db_kwargs(self):
    kwargs = _orig_db_kwargs(self)
    params = self._get_params()
    if params.get("Action") in ("ModifyDBInstance", "CreateDBInstanceReadReplica"):
        for attribute, parameter in (
            ("preferred_backup_window", "PreferredBackupWindow"),
            ("preferred_maintenance_window", "PreferredMaintenanceWindow"),
            ("security_groups", "DBSecurityGroups"),
            ("vpc_security_group_ids", "VpcSecurityGroupIds"),
        ):
            if parameter not in params:
                kwargs[attribute] = None
                if attribute.startswith("preferred_") and params["Action"] == "ModifyDBInstance":
                    database = self.backend.find_db_from_id(params["DBInstanceIdentifier"])
                    kwargs[attribute] = getattr(database, attribute)
    for attribute, (parameter, default) in _fields.items():
        getter = self._get_param
        if isinstance(default, bool):
            getter = self._get_bool_param
        elif isinstance(default, int):
            getter = self._get_int_param
        kwargs[attribute] = getter(parameter)
    return kwargs


RDSResponse._get_db_kwargs = _get_db_kwargs
_orig_instance_init = rds_models.DBInstance.__init__


def _instance_init(self, *args, **kwargs):
    _orig_instance_init(self, *args, **kwargs)
    if not self.option_group_supplied and self.engine == "postgres":
        self.option_group_name = f"default:postgres-{self.engine_version.split('.')[0]}"
    self.dbi_resource_id = f"db-{uuid.uuid4().hex[:26].upper()}"
    for attribute, (_, default) in _fields.items():
        value = kwargs.get(attribute)
        setattr(self, attribute, default if value is None else value)


rds_models.DBInstance.__init__ = _instance_init
_orig_update = rds_models.DBInstance.update


def _update(self, db_kwargs):
    self.enabled_cloudwatch_logs_exports = list(self.enabled_cloudwatch_logs_exports)
    _orig_update(self, db_kwargs)


rds_models.DBInstance.update = _update
_orig_to_xml = rds_models.DBInstance.to_xml
_extra_template = Template(
    """{% for attribute, field in fields.items() %}
    {% set value = database|attr(attribute) %}
    {% set tag = 'PerformanceInsightsEnabled' if attribute == 'performance_insights_enabled' else field[0] %}
    {% if value is not none %}<{{ tag }}>{{ ('true' if value else 'false') if value is boolean else value }}</{{ tag }}>{% endif %}
    {% endfor %}""",
    autoescape=True,
)


def _to_xml(self):
    extra = _extra_template.render(database=self, fields=_fields)
    return _orig_to_xml(self).replace("</DBInstance>", extra + "</DBInstance>")


rds_models.DBInstance.to_xml = _to_xml

_orig_create_replica = rds_models.RDSBackend.create_db_instance_read_replica


def _create_replica(self, db_kwargs):
    replica = _orig_create_replica(self, db_kwargs)
    replica.dbi_resource_id = f"db-{uuid.uuid4().hex[:26].upper()}"
    return replica


rds_models.RDSBackend.create_db_instance_read_replica = _create_replica

def _materialize(value):
    if isinstance(value, (GeneratorType, list)):
        return [_materialize(item) for item in value]
    if isinstance(value, tuple):
        return tuple(_materialize(item) for item in value)
    if isinstance(value, dict):
        return {key: _materialize(item) for key, item in value.items()}
    return value


def _restore_snapshot(self, snapshot_id, overrides):
    name = self.extract_snapshot_name_from_arn(snapshot_id) if snapshot_id.startswith("arn:aws:rds:") else snapshot_id
    snapshot = self.describe_db_snapshots(db_instance_identifier=None, db_snapshot_identifier=name)[0]
    if overrides["db_instance_identifier"] in self.databases:
        raise rds_models.DBInstanceAlreadyExists()
    properties = {
        attribute: deepcopy(_materialize(value))
        for attribute, value in vars(snapshot.database).items()
        if attribute not in ("backend", "db_subnet_group")
    }
    properties["enable_cloudwatch_logs_exports"] = properties.pop("enabled_cloudwatch_logs_exports")
    if not snapshot.database.option_group_supplied:
        properties["option_group_name"] = None
    for attribute, value in overrides.items():
        if value:
            properties[attribute] = value
    return self.create_db_instance(properties)


rds_models.RDSBackend.restore_db_instance_from_db_snapshot = _restore_snapshot

_orig_promote = rds_models.RDSBackend.promote_read_replica


def _promote(self, db_kwargs):
    db = _orig_promote(self, db_kwargs)
    source_id = db.source_db_identifier
    db.source_db_identifier = None
    try:
        primary = self.find_db_from_id(source_id) if source_id else None
        if primary is not None and db.db_instance_identifier in primary.replicas:
            primary.replicas.remove(db.db_instance_identifier)
    except Exception:  # best effort; the source may be gone
        pass
    return db


rds_models.RDSBackend.promote_read_replica = _promote

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
