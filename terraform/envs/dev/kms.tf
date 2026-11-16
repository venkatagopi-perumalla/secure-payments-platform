resource "aws_kms_key" "main" {
  description             = "Encryption key for the payments platform data"
  enable_key_rotation     = true
  deletion_window_in_days = 7
}

resource "aws_kms_alias" "main" {
  name          = "alias/payments-main"
  target_key_id = aws_kms_key.main.key_id
}
