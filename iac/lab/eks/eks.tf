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
    subnet_ids              = aws_subnet.public[*].id
    endpoint_public_access  = true
    endpoint_private_access = true
  }
  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true # the SSO role that runs `terraform apply` becomes cluster admin
  }
  depends_on = [aws_iam_role_policy_attachment.eks_cluster]
}

resource "aws_eks_node_group" "this" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.name}-ng"
  node_role_arn   = aws_iam_role.eks_node.arn
  subnet_ids      = aws_subnet.public[*].id
  instance_types  = [var.node_instance_type]
  ami_type        = "AL2023_x86_64_STANDARD"
  disk_size       = 20
  scaling_config {
    min_size     = 1
    max_size     = 1
    desired_size = 1
  }
  depends_on = [aws_iam_role_policy_attachment.eks_node]
}

# Kubeconfig with ONE context and NO current-context (dr_guard refuses a current-context and other envs' contexts).
resource "local_sensitive_file" "kubeconfig" {
  filename        = pathexpand(var.kubeconfig_path)
  file_permission = "0600"
  content = yamlencode({
    apiVersion  = "v1"
    kind        = "Config"
    clusters    = [{ name = aws_eks_cluster.this.arn, cluster = { server = aws_eks_cluster.this.endpoint, "certificate-authority-data" = aws_eks_cluster.this.certificate_authority[0].data } }]
    users       = [{ name = aws_eks_cluster.this.arn, user = { exec = { apiVersion = "client.authentication.k8s.io/v1beta1", command = "aws", args = concat(var.aws_profile == null ? [] : ["--profile", var.aws_profile], ["--region", var.region, "eks", "get-token", "--cluster-name", aws_eks_cluster.this.name, "--output", "json"]) } } }]
    contexts    = [{ name = var.kube_context, context = { cluster = aws_eks_cluster.this.arn, user = aws_eks_cluster.this.arn } }]
    preferences = {}
  })
}
