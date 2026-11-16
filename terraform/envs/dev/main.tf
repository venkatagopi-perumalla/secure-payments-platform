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
