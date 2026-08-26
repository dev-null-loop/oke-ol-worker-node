packer {
  required_plugins {
    oracle = {
      source  = "github.com/hashicorp/oracle"
      version = ">= 1.1.2"
    }
  }
}

locals {
  prepull_images_effective = compact(concat(var.oke_default_prepull_images, var.additional_prepull_images))
  builder_metadata = var.ssh_public_key_file != "" ? {
    ssh_authorized_keys = trimspace(file(var.ssh_public_key_file))
  } : {}
}

source "oracle-oci" "oke-ol" {
  availability_domain                                 = var.availability_domain
  base_image_ocid                                     = var.base_image_ocid
  compartment_ocid                                    = var.compartment_ocid
  image_name                                          = "ol${var.oracle_linux_major_version}-${formatdate("YYYY.MM.DD", timestamp())}-OKE-${var.k8s_version}-${var.optimization_profile}"
  shape                                               = var.shape
  ssh_username                                        = var.ssh_username
  subnet_ocid                                         = var.subnet_ocid
  ssh_private_key_file                                = var.ssh_private_key_file != "" ? var.ssh_private_key_file : null
  image_launch_mode                                   = var.image_launch_mode
  instance_options_are_legacy_imds_endpoints_disabled = true
  skip_create_image                                   = var.skip_create_image
  metadata                                            = local.builder_metadata

  tags = {
    k8s_version          = var.k8s_version
    base_os              = "ol${var.oracle_linux_major_version}"
    base_image_ocid      = var.base_image_ocid
    optimization_profile = var.optimization_profile
  }

  shape_config {
    ocpus         = var.shape_ocpus
    memory_in_gbs = var.shape_memory_in_gbs
  }
}

build {
  sources = ["source.oracle-oci.oke-ol"]

  provisioner "file" {
    source      = "../scripts/lib"
    destination = "/tmp"
  }

  provisioner "shell" {
    inline = [
      "cloud-init status --wait"
    ]
  }

  provisioner "shell" {
    environment_vars = [
      "EXPECTED_OL_MAJOR_VERSION=${var.oracle_linux_major_version}",
      "PREPULL_IMAGES=${join(",", local.prepull_images_effective)}",
    ]
    script = "../scripts/install-oke-node-packages.sh"
  }
}
