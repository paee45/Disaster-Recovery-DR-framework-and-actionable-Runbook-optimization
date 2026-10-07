terraform {
  backend "s3" {} # bucket/key/region come from iac/tf.sh (state key platform/shared/terrakube-config)
}
