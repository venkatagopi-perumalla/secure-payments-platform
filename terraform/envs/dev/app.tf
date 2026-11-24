data "aws_ecr_repository" "api" {
  name = "payments-api"
}

resource "random_password" "api_key" {
  length  = 40
  special = false
}

resource "aws_secretsmanager_secret" "api_key" {
  name                    = "payments/api-key"
  kms_key_id              = aws_kms_key.main.arn
  recovery_window_in_days = 0 # lab only, so destroy and recreate work
}

resource "aws_secretsmanager_secret_version" "api_key" {
  secret_id     = aws_secretsmanager_secret.api_key.id
  secret_string = random_password.api_key.result
}

module "service" {
  source                = "../../modules/service"
  name                  = local.name
  region                = var.region
  vpc_id                = module.network.vpc_id
  public_subnet_ids     = module.network.public_subnet_ids
  app_subnet_ids        = module.network.app_subnet_ids
  alb_security_group_id = module.network.alb_security_group_id
  app_security_group_id = module.network.app_security_group_id
  image                 = "${data.aws_ecr_repository.api.repository_url}:${var.image_tag}"
  db_host               = module.database.address
  db_name               = module.database.db_name
  db_secret_arn         = module.database.master_secret_arn
  api_key_secret_arn    = aws_secretsmanager_secret.api_key.arn
  kms_key_arn           = aws_kms_key.main.arn
  certificate_arn       = aws_acm_certificate_validation.api.certificate_arn
}

output "app_url" {
  value = "https://${var.api_domain}"
}
