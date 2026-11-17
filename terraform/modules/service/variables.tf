variable "name" {
  type = string
}

variable "region" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "public_subnet_ids" {
  type = list(string)
}

variable "app_subnet_ids" {
  type = list(string)
}

variable "alb_security_group_id" {
  type = string
}

variable "app_security_group_id" {
  type = string
}

variable "image" {
  type        = string
  description = "Full image reference including the tag"
}

variable "db_host" {
  type = string
}

variable "db_name" {
  type = string
}

variable "db_secret_arn" {
  type = string
}

variable "api_key_secret_arn" {
  type = string
}

variable "kms_key_arn" {
  type = string
}

variable "desired_count" {
  type    = number
  default = 2
}
