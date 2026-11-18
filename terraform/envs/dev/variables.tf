variable "region" {
  type    = string
  default = "eu-north-1"
}

variable "image_tag" {
  type        = string
  description = "Commit ID of the image to run on first create"
}

variable "alert_email" {
  type        = string
  description = "Email address that receives alarm notifications"
}
