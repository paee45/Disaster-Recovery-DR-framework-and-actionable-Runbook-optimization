terraform {
  backend "s3" {} # bucket/key/region come from iac/tf.sh; until the bucket exists tf.sh adds a local-backend override
}
