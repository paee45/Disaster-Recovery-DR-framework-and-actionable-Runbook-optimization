# Everything inside Terrakube as code: one organization, deploy/destroy templates, and one workspace per lab stack.
# Each workspace clones this repo (branch + folder) and runs Terraform with its OWN state in the S3 bucket:
#   s3://<state_bucket>/<project>/<env>/<component>/terraform.tfstate     (same keys as iac/tf.sh)
# so a stack can be run from Terrakube or from the Mac, but never both at once on the same state (S3 lock protects).
# Not here on purpose: platform/terrakube (it runs on the host Terrakube lives on) and platform/state-bucket.

resource "terrakube_organization" "this" {
  name           = var.organization
  description    = "DR lab in the sandbox account"
  execution_mode = "remote"
}

# Terrakube grants rights inside an organization only through a team named like the user's Dex group.
resource "terrakube_team" "admin" {
  organization_id = terrakube_organization.this.id
  name            = var.approver_team
  # Explicit flags: with role = "admin" alone Terrakube 2.33 stores every flag as false and the UI hides runs and templates.
  role              = "custom"
  manage_workspace  = true
  manage_state      = true
  manage_module     = true
  manage_provider   = true
  manage_vcs        = true
  manage_template   = true
  manage_collection = true
  manage_job        = true
  plan_job          = true
  approve_job       = true
}

# Click-to-deploy: plan, wait for approval, apply.
resource "terrakube_organization_template" "deploy" {
  depends_on      = [terrakube_team.admin]
  organization_id = terrakube_organization.this.id
  name            = "deploy"
  description     = "Plan, approve, apply"
  version         = "1.0.0"
  content         = <<-EOT
    flow:
      - type: "terraformPlan"
        name: "Plan"
        step: 100
      - type: "approval"
        name: "Approve the plan"
        step: 150
        team: "${var.approver_team}"
      - type: "terraformApply"
        name: "Apply"
        step: 200
  EOT
}

# Click-to-destroy: plan the destroy, wait for approval, apply it.
resource "terrakube_organization_template" "destroy" {
  depends_on      = [terrakube_team.admin]
  organization_id = terrakube_organization.this.id
  name            = "destroy"
  description     = "Plan destroy, approve, apply"
  version         = "1.0.0"
  content         = <<-EOT
    flow:
      - type: "terraformPlanDestroy"
        name: "Plan destroy"
        step: 100
      - type: "approval"
        name: "Approve the destroy"
        step: 150
        team: "${var.approver_team}"
      - type: "terraformApply"
        name: "Apply destroy"
        step: 200
  EOT
}

locals {
  # Variables every stack of a component declares (an undeclared one would only warn, but keep the logs clean).
  base = { account_id = var.account_id, region = var.region, state_bucket = var.state_bucket }
  base_keys = {
    network = ["account_id", "region"]
    eks     = ["account_id", "region", "state_bucket"]
    addons  = ["account_id", "region", "state_bucket"]
    db      = ["account_id", "region", "state_bucket"]
    app     = ["account_id", "region", "state_bucket"]
  }

  shared = {
    "lab-network" = { env = "shared", component = "network", vars = {} }
    # "Pause" the cluster = run this workspace with node_desired_size = 0 (change the variable, then deploy).
    "lab-eks"    = { env = "shared", component = "eks", vars = { node_desired_size = "1" } }
    "lab-addons" = { env = "shared", component = "addons", vars = {} }
  }
  per_env = {
    for p in setproduct(var.envs, ["db", "app"]) : "lab-${p[0]}-${p[1]}" => {
      env       = p[0]
      component = p[1]
      vars      = merge({ env = p[0] }, p[1] == "db" ? { operator_cidr = var.operator_cidr } : {})
    }
  }
  stacks = merge(local.shared, local.per_env)

  tf_vars = merge([
    for ws, s in local.stacks : {
      for name, value in merge({ for k in local.base_keys[s.component] : k => local.base[k] }, s.vars) :
      "${ws}/${name}" => { ws = ws, key = name, value = value }
    }
  ]...)
}

resource "terrakube_workspace_vcs" "this" {
  for_each = local.stacks

  depends_on         = [terrakube_team.admin]
  organization_id    = terrakube_organization.this.id
  name               = each.key
  description        = "iac/lab/${each.value.component} (${each.value.env})"
  execution_mode     = "remote"
  repository         = var.repository
  branch             = var.branch
  folder             = "/iac/lab/${each.value.component}"
  template_id        = terrakube_organization_template.deploy.id
  iac_type           = "terraform"
  iac_version        = var.terraform_version
  allow_remote_apply = true
}

# Where the workspace keeps its state: the S3 key layout, passed to `terraform init` (the code has backend "s3" {}).
# No AWS credentials are set: the Terrakube instance role (sandbox account only) is used.
resource "terrakube_workspace_variable" "state" {
  for_each = local.stacks

  organization_id = terrakube_organization.this.id
  workspace_id    = terrakube_workspace_vcs.this[each.key].id
  category        = "ENV"
  key             = "TF_CLI_ARGS_init"
  description     = "S3 state location"
  sensitive       = false
  hcl             = false
  value = join(" ", [
    "-backend-config=bucket=${var.state_bucket}",
    "-backend-config=key=lab/${each.value.env}/${each.value.component}/terraform.tfstate",
    "-backend-config=region=${var.region}",
    "-backend-config=encrypt=true",
    "-backend-config=use_lockfile=true",
  ])
}

resource "terrakube_workspace_variable" "tf" {
  for_each = local.tf_vars

  organization_id = terrakube_organization.this.id
  workspace_id    = terrakube_workspace_vcs.this[each.value.ws].id
  category        = "TERRAFORM"
  key             = each.value.key
  description     = "set by iac/platform/terrakube-config"
  sensitive       = false
  hcl             = false
  value           = each.value.value
}

output "workspaces" { value = sort(keys(local.stacks)) }
output "url" { value = "https://terrakube.platform.local" }
