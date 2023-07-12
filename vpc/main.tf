terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 4.67"
    }
  }

  required_version = ">= 1.2.0"
}

provider "aws" {
  region = var.region
}

# create the VPC
resource "aws_vpc" "tfc-web-test-vpc" {
  cidr_block           = var.vpcCIDRblock
  instance_tenancy     = var.instanceTenancy
  enable_dns_support   = var.dnsSupport
  enable_dns_hostnames = var.dnsHostNames

  tags = {
    Name = "TFC test web VPC"
  }
} # end resource


resource "aws_subnet" "public_subnets" {
  count             = length(var.public_subnet_cidrs)
  vpc_id            = aws_vpc.tfc-web-test-vpc.id
  cidr_block        = element(var.public_subnet_cidrs, count.index)
  availability_zone = element(var.azs, count.index)

  tags = {
    Name = "Public Subnet ${count.index + 1}"
  }
}

resource "aws_subnet" "private_subnets" {
  count             = length(var.private_subnet_cidrs)
  vpc_id            = aws_vpc.tfc-web-test-vpc.id
  cidr_block        = element(var.private_subnet_cidrs, count.index)
  availability_zone = element(var.azs, count.index)

  tags = {
    Name = "Private Subnet ${count.index + 1}"
  }
}

# internet gateway
resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.tfc-web-test-vpc.id

  tags = {
    Name = "Project VPC IG"
  }
}

# Second route table
resource "aws_route_table" "second_rt" {
  vpc_id = aws_vpc.tfc-web-test-vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gw.id
  }

  tags = {
    Name = "2nd Route Table"
  }
}

# Associating Public Subnets to the Second Route Table
resource "aws_route_table_association" "public_subnet_asso" {
  count          = length(var.public_subnet_cidrs)
  subnet_id      = element(aws_subnet.public_subnets[*].id, count.index)
  route_table_id = aws_route_table.second_rt.id
}

# create Security Group
resource "aws_security_group" "bastion-sg" {
  name        = var.securityGroupName
  description = var.securityGroupName
  vpc_id      = aws_vpc.tfc-web-test-vpc.id

  // To Allow SSH Transport
  ingress {
    from_port   = 22
    protocol    = "tcp"
    to_port     = 22
    cidr_blocks = ["0.0.0.0/0"]
  }

  // To Allow Port 80 Transport
  ingress {
    from_port   = 80
    protocol    = "tcp"
    to_port     = 80
    cidr_blocks = ["0.0.0.0/0"]
  }

    // To Allow Port 443 Transport
  ingress {
    from_port   = 443
    protocol    = "tcp"
    to_port     = 443
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

}

# instance EC2
resource "aws_instance" "php-my-admin" {
  ami           = var.ami
  instance_type = var.itype
  count         = length(var.public_subnet_cidrs)
  # un 1 EC2 par AZ (ici 3 EC2)
  #subnet_id                   = element(aws_subnet.public_subnets[*].id, count.index)
  # 1 unique EC2 dans un seul Subnet et une seule AZ
  subnet_id                   = aws_subnet.public_subnets[count.index].id
  associate_public_ip_address = var.publicip
  key_name                    = var.keyname
  user_data                   = file("install.sh")

  provisioner "file" {
    source      = "config.inc.php"
    destination = "/home/ec2-user/config.inc.php"

    connection {
      type        = "ssh"
      user        = "ec2-user"
      private_key = file("~/Documents/AWS/ec2-slo-key.pem")
      host        = self.public_dns
    }
  }


  vpc_security_group_ids = [
    aws_security_group.bastion-sg.id, aws_security_group.ec2_rds_sg.id
  ]
  root_block_device {
    delete_on_termination = true
    #iops                  = 150
    volume_size = 50
    volume_type = "gp2"
  }
  tags = {
    Name        = "PhpMyAdmin${count.index + 1}"
    Environment = "TEST"
    OS          = "aws-linux"
    Managed     = "PROJECT"
  }

  depends_on = [aws_security_group.bastion-sg]
}

output "ec2instance_public_ip" {
  value = { for k, v in aws_instance.php-my-admin : k => v.public_ip }
}

#create a security group for RDS Database Instance
resource "aws_security_group" "ec2_rds_sg" {
  name   = "ec2_rds_sg"
  vpc_id = aws_vpc.tfc-web-test-vpc.id

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

#create a security group for RDS Database Instance
resource "aws_security_group" "rds_ec2_sg" {
  name   = "rds_ec2_sg"
  vpc_id = aws_vpc.tfc-web-test-vpc.id

  ingress {
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}


resource "aws_db_subnet_group" "db_private_subnets_group" {
  name = "db_private_subnets_group"
  subnet_ids = [aws_subnet.private_subnets[0].id, aws_subnet.private_subnets[1].id, aws_subnet.private_subnets[2].id]

  tags = {
    Name = "My DB private subnets group"
  }
}

#create a RDS Database Instance
resource "aws_db_instance" "myinstance" {
  engine                 = "mysql"
  identifier             = "myrdsinstance"
  allocated_storage      = 20
  engine_version         = "5.7"
  instance_class         = "db.t3.micro"
  username               = "myrdsuser"
  password               = "#ZbECuSB9u^!Ykb%s6pu"
  parameter_group_name   = "default.mysql5.7"
  vpc_security_group_ids = ["${aws_security_group.rds_ec2_sg.id}"]
  skip_final_snapshot    = true
  publicly_accessible    = true
  db_subnet_group_name   = aws_db_subnet_group.db_private_subnets_group.name
}