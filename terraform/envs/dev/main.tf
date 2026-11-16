locals {
  name = "payments"
}

module "network" {
  source              = "../../modules/network"
  name                = local.name
  region              = var.region
  vpc_cidr            = "10.30.0.0/16"
  azs                 = ["eu-north-1a", "eu-north-1b"]
  public_subnet_cidrs = ["10.30.1.0/24", "10.30.2.0/24"]
  app_subnet_cidrs    = ["10.30.11.0/24", "10.30.12.0/24"]
  data_subnet_cidrs   = ["10.30.21.0/24", "10.30.22.0/24"]
}

module "database" {
  source            = "../../modules/database"
  name              = local.name
  db_name           = "payments"
  subnet_ids        = module.network.data_subnet_ids
  security_group_id = module.network.db_security_group_id
  kms_key_arn       = aws_kms_key.main.arn
}

output "db_secret_arn" {
  value = module.database.master_secret_arn
}
