terraform {
  backend "s3" {} # bucket/key/region come from iac/tf.sh (never hard-code the account id here)
}
