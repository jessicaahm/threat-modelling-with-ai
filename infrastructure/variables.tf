variable "region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "ap-southeast-1"
}

variable "instance_type" {
  description = "EC2 instance type."
  type        = string
  default     = "t3.micro"
}

variable "name" {
  description = "Name tag for the instance and associated resources."
  type        = string
  default     = "ec2-linux-demo"
}

variable "subnet_id" {
  description = "Optional subnet ID. If empty, a subnet in the default VPC is used."
  type        = string
  default     = ""
}
