resource "aws_iam_role" "eks_cluster" {
  name = "${var.name}-eks-cluster"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "eks.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_cluster" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_iam_role" "eks_node" {
  name = "${var.name}-eks-node"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_node" {
  for_each   = toset(["AmazonEKSWorkerNodePolicy", "AmazonEKS_CNI_Policy", "AmazonEC2ContainerRegistryReadOnly"])
  role       = aws_iam_role.eks_node.name
  policy_arn = "arn:aws:iam::aws:policy/${each.value}"
}

resource "aws_eks_cluster" "this" {
  name     = "${var.name}-eks"
  role_arn = aws_iam_role.eks_cluster.arn
  vpc_config {
    subnet_ids              = local.subnet_ids
    endpoint_public_access  = true
    endpoint_private_access = true
  }
  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true # the SSO role that runs `terraform apply` becomes cluster admin
  }
  depends_on = [aws_iam_role_policy_attachment.eks_cluster]
}

# Whoever creates the cluster (the Terrakube instance role from the UI, or the SSO role from the Mac) is its only admin;
# the SSO admin role gets access explicitly so kubectl from the Mac works whichever one ran the apply.
data "aws_iam_roles" "sso_admin" {
  name_regex  = "^AWSReservedSSO_AdministratorAccess_"
  path_prefix = "/aws-reserved/sso.amazonaws.com/"
}

resource "aws_eks_access_entry" "sso_admin" {
  for_each      = toset(data.aws_iam_roles.sso_admin.arns)
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value # the real role ARN, including the SSO path (EKS rejects the stripped form)
}

resource "aws_eks_access_policy_association" "sso_admin" {
  for_each      = aws_eks_access_entry.sso_admin
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value.principal_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  access_scope { type = "cluster" }
}

resource "aws_eks_node_group" "this" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.name}-ng"
  node_role_arn   = aws_iam_role.eks_node.arn
  subnet_ids      = local.subnet_ids
  instance_types  = [var.node_instance_type]
  ami_type        = "AL2023_x86_64_STANDARD"
  disk_size       = 20
  scaling_config {
    min_size     = 0
    max_size     = 1
    desired_size = var.node_desired_size
  }
  depends_on = [aws_iam_role_policy_attachment.eks_node]
}

# One kubeconfig per env, each with ONE context and NO current-context (dr_guard refuses a current-context and other envs' contexts).
resource "local_sensitive_file" "kubeconfig" {
  for_each        = toset(var.envs)
  filename        = pathexpand("${var.kubeconfig_dir}/dr-${each.key}.config")
  file_permission = "0600"
  content = yamlencode({
    apiVersion  = "v1"
    kind        = "Config"
    clusters    = [{ name = aws_eks_cluster.this.arn, cluster = { server = aws_eks_cluster.this.endpoint, "certificate-authority-data" = aws_eks_cluster.this.certificate_authority[0].data } }]
    users       = [{ name = aws_eks_cluster.this.arn, user = { exec = { apiVersion = "client.authentication.k8s.io/v1beta1", command = "aws", args = concat(var.aws_profile == null ? [] : ["--profile", var.aws_profile], ["--region", var.region, "eks", "get-token", "--cluster-name", aws_eks_cluster.this.name, "--output", "json"]) } } }]
    contexts    = [{ name = "dr-${each.key}", context = { cluster = aws_eks_cluster.this.arn, user = aws_eks_cluster.this.arn } }]
    preferences = {}
  })
}
