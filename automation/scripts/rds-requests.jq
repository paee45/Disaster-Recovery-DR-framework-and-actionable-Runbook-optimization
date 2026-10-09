# rds-requests.jq — ONE place that turns a source instance (describe-db-instances .DBInstances[0], the "baseline")
# into the API requests used by dr-restore.sh: restore (snapshot / PITR), create-like (empty instance, same config),
# harden (modify after restore), and the normalised view used by validate.
# Used by: automation/scripts/dr-restore.sh, tests/local/up.sh (local primary from a fixture), tests (offline checks).
#
# Field coverage (RDS API, postgres):
#   at restore/create : class, port, subnet group, ALL SGs, parameter group, non-default option group, Multi-AZ,
#                       public access, storage type (+IOPS/throughput only where allowed), IAM auth, log exports, CA,
#                       network type, dedicated log volume, backup target, license model,
#                       engine lifecycle support, deletion protection, copy-tags, user tags (never aws:*)
#                       (backup retention + window: create only; the Restore* APIs reject them, harden sets them)
#   only via modify   : backup retention + window after a restore, maintenance window, max storage (snapshot), Enhanced Monitoring (interval + role),
#                       Performance Insights (+KMS key, retention), Database Insights mode, IAM roles (add-role)
#   not settable      : UpgradeRolloutOrder (reported, not compared), StorageEncrypted/KmsKeyId (from the snapshot)

def userTags: [ .[]? | select(.Key | test("^(aws:|dr-restore$|dr-restored-from$)") | not) ];
def nonnull: with_entries(select(.value != null and .value != [] and .value != ""));
# gp3 below 400 GiB (postgres): IOPS 3000 / 125 MiB/s are fixed baseline values and must NOT be sent (API rejects them)
def gp3big: (.StorageType == "gp3" and (.AllocatedStorage // 0) >= 400);
def customOptionGroup: ([.OptionGroupMemberships[]?.OptionGroupName | select(startswith("default:") | not)][0] // null);

# baseline instance → what the new instance MUST look like (overrides + policy floors applied)
def expected($ov; $env; $floor; $maz):
    .DBInstanceClass = ($ov.class // .DBInstanceClass)
  | (if $ov.subnets then .DBSubnetGroup = {DBSubnetGroupName: $ov.subnets} else . end)
  | (if $ov.sgs then .VpcSecurityGroups = ($ov.sgs | map({VpcSecurityGroupId: ., Status: "active"})) else . end)
  | (if $ov.pg then .DBParameterGroups = [{DBParameterGroupName: $ov.pg}] else . end)
  | .DBParameterGroups |= map(.ParameterApplyStatus = "in-sync")
  | .MultiAZ = ((.MultiAZ // false) or $maz)
  | .DeletionProtection = ((.DeletionProtection // false) or ($env != "dev"))
  | .BackupRetentionPeriod = ([.BackupRetentionPeriod // 0, $floor] | max);

# settings shared by restore and create (input: expected instance)
def common_req($tags):
  {
    DBInstanceClass, MultiAZ, DeletionProtection, BackupRetentionPeriod, PreferredBackupWindow,
    AutoMinorVersionUpgrade, CopyTagsToSnapshot, CACertificateIdentifier, NetworkType, StorageType, DedicatedLogVolume,
    BackupTarget, LicenseModel, EngineLifecycleSupport,
    Port: ((.Endpoint.Port // .DbInstancePort) | if . == 0 then null else . end),
    DBSubnetGroupName: .DBSubnetGroup.DBSubnetGroupName,
    VpcSecurityGroupIds: [.VpcSecurityGroups[].VpcSecurityGroupId],
    DBParameterGroupName: .DBParameterGroups[0].DBParameterGroupName,
    OptionGroupName: customOptionGroup,
    PubliclyAccessible: (.PubliclyAccessible // false),
    EnableIAMDatabaseAuthentication: (.IAMDatabaseAuthenticationEnabled // false),
    EnableCloudwatchLogsExports: (.EnabledCloudwatchLogsExports // []),
    Iops: (if (.StorageType // "" | test("^io")) or gp3big then .Iops else null end),
    StorageThroughput: (if gp3big then .StorageThroughput else null end),
    Tags: $tags
  };

# RestoreDBInstanceFromDBSnapshot / RestoreDBInstanceToPointInTime  ($op = identifiers + source + time)
def restore_req($op; $tags): ((common_req($tags) | del(.BackupRetentionPeriod, .PreferredBackupWindow)) + $op) | nonnull;

# CreateDBInstance: an EMPTY instance with the same configuration (test primary for local/dev/uat)
# Password: RDS-managed in Secrets Manager (ManageMasterUserPassword) unless $ov.MasterUserPassword is given.
def create_req($id; $tags; $ov):
  (common_req($tags) + {
     DBInstanceIdentifier: $id, Engine, EngineVersion, MasterUsername, AllocatedStorage, MaxAllocatedStorage,
     PreferredMaintenanceWindow, StorageEncrypted, KmsKeyId: (if .StorageEncrypted then .KmsKeyId else null end),
     MonitoringInterval, MonitoringRoleArn: (if (.MonitoringInterval // 0) > 0 then .MonitoringRoleArn else null end),
     EnablePerformanceInsights: (.PerformanceInsightsEnabled // false),
     PerformanceInsightsKMSKeyId: (if .PerformanceInsightsEnabled then .PerformanceInsightsKMSKeyId else null end),
     PerformanceInsightsRetentionPeriod: (if .PerformanceInsightsEnabled then .PerformanceInsightsRetentionPeriod else null end),
     DatabaseInsightsMode,
     ManageMasterUserPassword: true
   } + $ov
   | if .MasterUserPassword then del(.ManageMasterUserPassword) else . end) | nonnull;

# ModifyDBInstance after a restore: ONLY what differs between expected ($e = input) and the target ($t)
def harden_req($t; $db):
  def same($a; $b): ($a | tojson) == ($b | tojson);
  . as $e
  | {
      DBInstanceClass: $e.DBInstanceClass, MultiAZ: $e.MultiAZ, BackupRetentionPeriod: $e.BackupRetentionPeriod,
      PreferredBackupWindow: $e.PreferredBackupWindow, PreferredMaintenanceWindow: $e.PreferredMaintenanceWindow,
      DeletionProtection: $e.DeletionProtection, CopyTagsToSnapshot: $e.CopyTagsToSnapshot,
      AutoMinorVersionUpgrade: $e.AutoMinorVersionUpgrade, MaxAllocatedStorage: $e.MaxAllocatedStorage,
      CACertificateIdentifier: $e.CACertificateIdentifier, LicenseModel: $e.LicenseModel,
      EngineLifecycleSupport: $e.EngineLifecycleSupport,
      DBParameterGroupName: $e.DBParameterGroups[0].DBParameterGroupName,
      OptionGroupName: ($e | customOptionGroup),
      EnableIAMDatabaseAuthentication: ($e.IAMDatabaseAuthenticationEnabled // false),
      VpcSecurityGroupIds: ([$e.VpcSecurityGroups[].VpcSecurityGroupId] | sort)
    } as $want
  | {
      DBInstanceClass: $t.DBInstanceClass, MultiAZ: $t.MultiAZ, BackupRetentionPeriod: $t.BackupRetentionPeriod,
      PreferredBackupWindow: $t.PreferredBackupWindow, PreferredMaintenanceWindow: $t.PreferredMaintenanceWindow,
      DeletionProtection: $t.DeletionProtection, CopyTagsToSnapshot: $t.CopyTagsToSnapshot,
      AutoMinorVersionUpgrade: $t.AutoMinorVersionUpgrade, MaxAllocatedStorage: $t.MaxAllocatedStorage,
      CACertificateIdentifier: $t.CACertificateIdentifier, LicenseModel: $t.LicenseModel,
      EngineLifecycleSupport: $t.EngineLifecycleSupport,
      DBParameterGroupName: $t.DBParameterGroups[0].DBParameterGroupName,
      OptionGroupName: ($t | customOptionGroup),
      EnableIAMDatabaseAuthentication: ($t.IAMDatabaseAuthenticationEnabled // false),
      VpcSecurityGroupIds: ([$t.VpcSecurityGroups[].VpcSecurityGroupId] | sort)
    } as $have
  | ($want | with_entries(select(.value != null and (same(.value; $have[.key]) | not))))
    # Performance Insights (+ Database Insights mode) and Enhanced Monitoring travel as sets
  + (if same($e.PerformanceInsightsEnabled // false; $t.PerformanceInsightsEnabled // false)
        and same($e.PerformanceInsightsRetentionPeriod; $t.PerformanceInsightsRetentionPeriod)
        and same($e.DatabaseInsightsMode; $t.DatabaseInsightsMode) then {}
     else {EnablePerformanceInsights: ($e.PerformanceInsightsEnabled // false)}
          + (if $e.PerformanceInsightsEnabled then {PerformanceInsightsRetentionPeriod: $e.PerformanceInsightsRetentionPeriod,
               PerformanceInsightsKMSKeyId: $e.PerformanceInsightsKMSKeyId, DatabaseInsightsMode: $e.DatabaseInsightsMode} | nonnull else {} end) end)
  + (if same($e.MonitoringInterval // 0; $t.MonitoringInterval // 0) and same($e.MonitoringRoleArn; $t.MonitoringRoleArn) then {}
     else {MonitoringInterval: ($e.MonitoringInterval // 0)} + (if ($e.MonitoringInterval // 0) > 0 then {MonitoringRoleArn: $e.MonitoringRoleArn} else {} end) end)
  + ((($e.EnabledCloudwatchLogsExports // []) - ($t.EnabledCloudwatchLogsExports // [])) as $on
     | (($t.EnabledCloudwatchLogsExports // []) - ($e.EnabledCloudwatchLogsExports // [])) as $off
     | if ($on + $off) == [] then {} else {CloudwatchLogsExportConfiguration: {EnableLogTypes: $on, DisableLogTypes: $off}} end)
  | if . == {} then . else . + {DBInstanceIdentifier: $db, ApplyImmediately: true} end;

# every attribute, flattened to "path" → value; identity/runtime/not-settable fields removed; lists sorted and joined
def norm:
    del(.DBInstanceIdentifier, .DBInstanceArn, .DbiResourceId, .Endpoint.Address, .Endpoint.HostedZoneId,
        .InstanceCreateTime, .LatestRestorableTime, .DBInstanceStatus, .PendingModifiedValues,
        .ReadReplicaDBInstanceIdentifiers, .ReadReplicaSourceDBInstanceIdentifier, .ReadReplicaDBClusterIdentifiers,
        .AvailabilityZone, .SecondaryAvailabilityZone, .StatusInfos, .CertificateDetails.ValidTill,
        .EnhancedMonitoringResourceArn, .ActivityStreamStatus, .DBInstanceAutomatedBackupsReplications,
        .AutomaticRestartTime, .ResumeFullAutomationModeTime, .MasterUserSecret, .TagList, .DBSecurityGroups,
        .ListenerEndpoint, .IsStorageConfigUpgradeAvailable, .UpgradeRolloutOrder)
  | .VpcSecurityGroups      = ([.VpcSecurityGroups[]? | .VpcSecurityGroupId] | sort | join(","))
  | .DBParameterGroups      = ([.DBParameterGroups[]? | .DBParameterGroupName + ":" + (.ParameterApplyStatus // "?")] | sort | join(","))
  | .OptionGroupMemberships = ([.OptionGroupMemberships[]? | .OptionGroupName] | sort | join(","))
  | .AssociatedRoles        = ([.AssociatedRoles[]? | .RoleArn + ":" + (.FeatureName // "")] | sort | join(","))
  | .DomainMemberships      = ([.DomainMemberships[]? | .Domain] | sort | join(","))
  | .EnabledCloudwatchLogsExports = ((.EnabledCloudwatchLogsExports // []) | sort | join(","))
  | .DBSubnetGroup = ({name: .DBSubnetGroup.DBSubnetGroupName, vpc: .DBSubnetGroup.VpcId,
                       subnets: ([.DBSubnetGroup.Subnets[]?.SubnetIdentifier] | sort | join(","))} | with_entries(select(.value != null and .value != "")))
  | [paths(scalars) as $p | {key: ($p | map(tostring) | join(".")), value: getpath($p)}] | from_entries;
