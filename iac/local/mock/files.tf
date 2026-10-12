resource "local_file" "aws_config" {
  filename        = "${local.state_dir}/aws-config"
  file_permission = "0600"
  content         = <<-CFG
    [profile dr-local]
    region = eu-west-1
    output = json
    endpoint_url = http://172.30.0.10:4566
    services = dr-local-services

    [services dr-local-services]
    rds =
      endpoint_url = http://127.0.0.1:5000
    ec2 =
      endpoint_url = http://127.0.0.1:5000

    [profile dr-sso-expired]
    sso_session = drtest
    sso_account_id = 000000000000
    sso_role_name = lab_admin
    region = eu-west-1

    [sso-session drtest]
    sso_start_url = https://drtest.invalid/start
    sso_region = eu-west-1
    sso_registration_scopes = sso:account:access

    [profile dr-decoy]
    region = eu-west-1
    endpoint_url = http://127.0.0.1:5000
  CFG
}

resource "local_sensitive_file" "aws_credentials" {
  filename        = "${local.state_dir}/aws-credentials"
  file_permission = "0600"
  content         = <<-CFG
    [dr-local]
    aws_access_key_id = test
    aws_secret_access_key = test
    [dr-decoy]
    aws_access_key_id = decoy
    aws_secret_access_key = decoy
  CFG
}

resource "local_file" "endpoint_map" {
  filename        = "${local.state_dir}/endpoint-map"
  file_permission = "0644"
  content         = <<-MAP
    # pattern                host           port
    app-pg-local             172.30.0.21    5432
    app-pg-local-replica     172.30.0.22    5432
    app-pg-local-r*          172.30.0.23    5432
    app-pg-local-p*          172.30.0.23    5432
    app-pg-local-drtest-*    172.30.0.23    5432
  MAP
}

resource "local_file" "local_env" {
  filename        = "${local.state_dir}/local.env"
  file_permission = "0600"
  content         = <<-ENV
    export DR_ENV=local
    export AWS_CONFIG_FILE="${local_file.aws_config.filename}" AWS_SHARED_CREDENTIALS_FILE="${local_sensitive_file.aws_credentials.filename}"
    export AWS_PROFILE=dr-local AWS_REGION=eu-west-1 ACCOUNT_ID=000000000000
    export KUBECONFIG=/tmp/dr-local-kubeconfig EKS_CONTEXT=dr-local REQUIRE_CLUSTER_IDENTITY=true
    export PRIMARY_DB=app-pg-local REPLICA_DB=app-pg-local-replica MULTI_AZ=${local.fx.MultiAZ} BACKUP_RETENTION_DAYS=${local.fx.BackupRetentionPeriod}
    export BASELINE_DIR="${local.state_dir}/baselines"
    export DB_NAME=app APP_DB_USER=app_user
    export SECRET_ID=local/app/db SECRET_ID_RO= MASTER_SECRET_ID=local/app/db-master
    export SECRET_MODE="$${SECRET_MODE:-eso}"
    export K8S_NS=app K8S_SECRET=app-db-credentials K8S_HOST_KEY=POSTGRES_DB_HOST
    export DR_SELECTOR='dr.example.com/db-consumer=true'
    export QUARANTINE_SG=${aws_security_group.quarantine.id} DB_SG= DB_SUBNET_GROUP= DB_PARAM_GROUP= DB_INSTANCE_CLASS=
    export EVIDENCE_BUCKET=${aws_s3_bucket.evidence.bucket}
    export RTO_TARGET_MIN=30 RPO_TARGET_S=86400 REPLICA_LAG_MAX_S=300
    export VERIFY_TABLES="public.orders public.payments"
    export DR_ENDPOINT_MAP="${local_file.endpoint_map.filename}" DR_PGSSLMODE=disable RELOADER_GRACE_S=60
  ENV
}