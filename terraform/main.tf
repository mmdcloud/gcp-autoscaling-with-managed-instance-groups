# VPC
resource "google_compute_network" "nodeapp-vpc" {
  name                    = "nodeapp-vpc"
  auto_create_subnetworks = false
}

# backend subnet
resource "google_compute_subnetwork" "nodeapp-subnet" {
  name          = "nodeapp-subnet"
  ip_cidr_range = "10.0.1.0/24"
  region        = "us-central1"
  network       = google_compute_network.nodeapp-vpc.id
}

# reserved IP address
resource "google_compute_global_address" "nodeapp-staticip" {
  name = "nodeapp-staticip"
}

# forwarding rule
resource "google_compute_global_forwarding_rule" "nodeapp-forwarding-rule" {
  name                  = "nodeapp-forwarding-rule"
  ip_protocol           = "TCP"
  load_balancing_scheme = "EXTERNAL"
  port_range            = "80"
  target                = google_compute_target_http_proxy.nodeapp-target-http-proxy.id
  ip_address            = google_compute_global_address.nodeapp-staticip.id
}

# http proxy
resource "google_compute_target_http_proxy" "nodeapp-target-http-proxy" {
  name    = "nodeapp-target-http-proxy"
  url_map = google_compute_url_map.nodeapp-url-map.id
}

# url map
resource "google_compute_url_map" "nodeapp-url-map" {
  name            = "nodeapp-url-map"
  default_service = google_compute_backend_service.nodeapp-service.id
}

# backend service with custom request and response headers
resource "google_compute_backend_service" "nodeapp-service" {
  name                    = "nodeapp-service"
  protocol                = "HTTP"
  port_name               = "nodeapp-port"
  load_balancing_scheme   = "EXTERNAL"
  timeout_sec             = 10
  enable_cdn              = true
  custom_request_headers  = ["X-Client-Geo-Location: {client_region_subdivision}, {client_city}"]
  custom_response_headers = ["X-Cache-Hit: {cdn_cache_status}"]
  health_checks           = [google_compute_health_check.nodeapp-health-check.id]
  backend {
    group           = google_compute_instance_group_manager.default.instance_group
    balancing_mode  = "UTILIZATION"
    capacity_scaler = 1.0
  }
}

# instance template
resource "google_compute_instance_template" "nodeapp-template" {
  name         = "nodeapp-template"
  machine_type = "e2-small"
  tags         = ["allow-health-check"]

  network_interface {
    network    = google_compute_network.nodeapp-vpc.id
    subnetwork = google_compute_subnetwork.nodeapp-subnet.id
    access_config {
      # add external ip to fetch packages
    }
  }
  disk {
    source_image = "debian-cloud/debian-12"
    auto_delete  = true
    boot         = true
  }

  # install nginx and serve a simple web page
  metadata = {
    startup-script = <<-EOF1
      #! /bin/bash
      set -euo pipefail

      export DEBIAN_FRONTEND=noninteractive
      apt-get update
      apt-get install -y nginx-light jq

      NAME=$(curl -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/hostname")
      IP=$(curl -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/ip")
      METADATA=$(curl -f -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/attributes/?recursive=True" | jq 'del(.["startup-script"])')

      cat <<EOF > /var/www/html/index.html
      <pre>
      Name: $NAME
      IP: $IP
      Metadata: $METADATA
      </pre>
      EOF
    EOF1
  }
  lifecycle {
    create_before_destroy = true
  }
}

# health check
resource "google_compute_health_check" "nodeapp-health-check" {
  name = "nodeapp-health-check"
  http_health_check {
    port_specification = "USE_SERVING_PORT"
  }
}

# MIG
resource "google_compute_instance_group_manager" "default" {
  name = "l7-xlb-mig1"
  zone = "us-central1-c"
  named_port {
    name = "http"
    port = 80
  }
  version {
    instance_template = google_compute_instance_template.nodeapp-template.id
    name              = "primary"
  }
  base_instance_name = "vm"
  target_size        = 2
}

# allow access from health check ranges
resource "google_compute_firewall" "nodeapp-firewall" {
  name          = "nodeapp-firewall"
  direction     = "INGRESS"
  network       = google_compute_network.nodeapp-vpc.id
  source_ranges = ["0.0.0.0/0"]
  allow {
    protocol = "tcp"
    ports    = ["80"]
  }
  target_tags = ["allow-health-check"]
}
