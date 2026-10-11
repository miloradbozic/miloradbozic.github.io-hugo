+++
title = "Immutable servers with Packer, Ansible and Terraform"
description = "Bake the image, never patch the server: how we split responsibilities between three tools and what it changed in deploys"
date = "2017-10-15T18:45:00+02:00"
menu = ""
draft = false
featured = false
share = true
comments = true
slug = "immutable-servers-packer-ansible-terraform"
author = "Milorad Bozic"
tags = ["devops", "aws", "terraform", "packer", "ansible", "infrastructure"]

+++

Over the past months I spent a lot of my time on the operations side at work. The main change was
going from servers that we configure in place to servers that we **never change after they start**.
If something needs to change, we build a new image and replace the server.

Here's how the pieces fit, because the hardest part for me was not learning each tool but
understanding where one stops and the next one starts.

## The problem with long-lived servers

When you configure servers in place, even with Ansible, every server slowly becomes unique. One got
a hotfix package by hand during an incident. One was created before a playbook change and has an
older PHP extension. Running the playbook again *usually* fixes it, until the day it fails halfway
on one machine.

The symptom is always the same sentence: "it works on web-2 but not on web-3".

## Three tools, three jobs

**Ansible: what is on a server.** Packages, PHP and its extensions, nginx config, the queue worker
supervisor config, log shipping. Still Ansible roles, but now they run in exactly one place: while
building an image.

**Packer: bake that into an image.** Packer starts a temporary EC2 instance from a base image, runs
our Ansible playbook on it, and saves the result as an AMI.

```json
{
  "builders": [{
    "type": "amazon-ebs",
    "region": "eu-west-1",
    "source_ami_filter": {
      "filters": { "name": "ubuntu/images/*ubuntu-xenial-16.04-amd64-server-*" },
      "owners": ["099720109477"],
      "most_recent": true
    },
    "instance_type": "t2.medium",
    "ssh_username": "ubuntu",
    "ami_name": "app-{{timestamp}}"
  }],
  "provisioners": [{
    "type": "ansible",
    "playbook_file": "ansible/app.yml"
  }]
}
```

The output is an AMI id. That image is the same for every server that will ever run it.

**Terraform: where and how many.** The VPC, security groups, load balancer, and an auto scaling
group that runs instances from a given AMI.

```hcl
resource "aws_launch_configuration" "app" {
  name_prefix     = "app-"
  image_id        = "${var.app_ami}"
  instance_type   = "t2.medium"
  security_groups = ["${aws_security_group.app.id}"]

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "app" {
  name                 = "app-${aws_launch_configuration.app.name}"
  launch_configuration = "${aws_launch_configuration.app.name}"
  min_size             = 2
  max_size             = 6
  min_elb_capacity     = 2
  load_balancers       = ["${aws_elb.app.name}"]
  vpc_zone_identifier  = ["${var.private_subnets}"]

  lifecycle {
    create_before_destroy = true
  }
}
```

The `create_before_destroy` plus naming the ASG after the launch configuration is the trick: a new
AMI means a new launch configuration, which means a new auto scaling group. Terraform creates it,
waits until `min_elb_capacity` instances are healthy behind the load balancer, and only then
destroys the old group. That's a blue/green deploy in about twenty lines.

## What a deploy looks like now

1. CI builds and tests the code.
2. Packer bakes an AMI with that exact code version and config.
3. `terraform apply -var app_ami=ami-...` rolls the auto scaling group.
4. Rollback is step 3 with the previous AMI id.

No `ssh` into production as part of a deploy. Actually no `ssh` into production at all, most days.

## What it costs

- **Slower deploys.** Baking an AMI takes several minutes. For a hotfix that feels long. We
  accepted it; a predictable ten minutes beats an unpredictable "it depends".
- **Nothing on local disk survives.** Instances can disappear any time, so uploaded files go to
  S3, sessions go to Redis, and logs are shipped off the box. This forced a few changes in the app
  that were overdue anyway.
- **Secrets don't go in the image.** The same AMI should work in staging and production. Config
  comes from the environment at boot, not from the bake.
- **Terraform state is precious.** Remote state in S3, never edited by hand, and only one person
  running `apply` at a time. We learned the last one the hard way.

## Why it matters beyond ops

The idea is the same one I keep running into in application code: don't mutate things in place,
replace them with a new version you can describe completely. An AMI id tells you exactly what's on
a server. A server that has been "kept up to date" for a year tells you nothing.
