job "grafana" {
  # Specify the datacenter and region
  datacenters = ["*"]
  region      = "global"
  namespace   = "observability"
  node_pool = "all" # run on all nodes
  
  # Job type - system to run on all nodes
  type = "system"
  
  # Update strategy for system jobs
  update {
    max_parallel      = 1
    min_healthy_time  = "10s"
    healthy_deadline  = "5m"
    auto_revert       = true
    stagger          = "30s"
  }
  
  group "alloy" {
    # Restart policy
    restart {
      attempts = 3
      interval = "5m"
      delay    = "25s"
      mode     = "delay"
    }
    
    # Network configuration
    network {
      port "http" {
        static = 12345
        to     = 12345
      }
      
      port "otlp_grpc" {
        static = 4317
        to     = 4317
      }
      
      port "otlp_http" {
        static = 4318
        to     = 4318
      }
    }
    
    # Optional: Volume for data persistence
    volume "alloy-data" {
      type            = "host"
      source          = "alloy-data"
      read_only       = false
      attachment_mode = "file-system"
      access_mode     = "single-node-single-writer"
    }
    
    task "nomad-targets-generator" { 
      driver = "docker"
      
      config {
        image = "python3:3.11-slim"
        command = "python3"
        args    = ["local/generate-alloy-targets.py"]
      }

      env {
        NOMAD_ADDR    = "unix://${NOMAD_SECRETS_DIR}/api.sock"
        NOMAD_LOG_DIR = "/var/nomad/alloc"
        ALLOY_MODULE_FILE = "/alloc/nomad-targets.alloy"
      }      

      resources {
        cpu    = 100
        memory = 128
      }

      lifecycle {
        hook    = "prestart"
        sidecar = true
      }

      identity {
        env = true
      }

      # Output the generated targets to a file for the Alloy agent to consume
      template {
        destination = "local/generate-alloy-targets.py"
        change_mode = "restart"
        left_delimiter = "[["
        right_delimiter = "]]"
        data        = <<EOH
#!/usr/bin/env python3
"""
Generate Grafana Alloy discovery.file targets from Nomad node allocations.
This script runs within a Nomad allocation and uses the Task API to discover
all allocations on the current node, then generates a module discovery file for
Alloy to scrape allocation logs.
"""

import json
import os
import sys
import time
import signal
from pathlib import Path
from typing import List, Dict, Any
import urllib.request
import http.client
import socket


# Nomad Task API configuration (available within allocations)
NOMAD_ADDR = os.getenv("NOMAD_ADDR", "http://127.0.0.1:4646")
NOMAD_TOKEN = os.getenv("NOMAD_TOKEN", "")

# Nomad log directory on host (default location)
NOMAD_LOG_DIR = os.getenv("NOMAD_LOG_DIR", "/var/nomad/alloc")

# Output file for Alloy module
OUTPUT_FILE = os.getenv("ALLOY_MODULE_FILE", "/alloc/nomad-targets.alloy")

# Refresh interval in seconds
REFRESH_INTERVAL = int(os.getenv("REFRESH_INTERVAL", "60"))

# Continuous refresh mode
CONTINUOUS_MODE = os.getenv("CONTINUOUS_MODE", "true").lower() in ["true", "1", "yes"]

# Global flag for graceful shutdown
running = True


"""
For ease of deployment, this script relies on Python stdlib only (so no requests library).
However, the stdlib http library (urlib3) doesn't support UNIX domain sockets (which Nomad's Task API
is available), which forces us to build our own HTTP requests using over UDS handling. 

"""

class UnixHTTPConnection(http.client.HTTPConnection):
    def __init__(self, *args, **kwargs) -> None:
        self._unix_path: str = kwargs.pop("unix_path")
        super().__init__(*args, **kwargs)

    def connect(self) -> None:
        self.sock = socket.socket(family=socket.AF_UNIX, type=socket.SOCK_STREAM)
        if self.timeout is not socket._GLOBAL_DEFAULT_TIMEOUT:
            self.sock.settimeout(self.timeout)
        self.sock.connect(self._unix_path)
        if self._tunnel_host:
            self._tunnel()

class UnixHTTPHandler(urllib.request.AbstractHTTPHandler):
    def __init__(self, unix_path: str) -> None:
        self._unix_path: str = unix_path
        super().__init__()

    def unix_open(self, request: urllib.request.Request) -> http.client.HTTPResponse:
        return self.do_open(UnixHTTPConnection, request, unix_path=self._unix_path)

    def unix_request(self, request: urllib.request.Request) -> urllib.request.Request:
        return self.do_request_(request)

def signal_handler(signum, frame):
    """Handle shutdown signals gracefully."""
    global running
    print(f"\nReceived signal {signum}, shutting down gracefully...")
    running = False

def make_http_request(url: str) -> Dict[str, Any]:
    """Make an HTTP GET request to the given URL and return the JSON response."""
    try:
        headers = {}
        if NOMAD_TOKEN:
            headers["X-Nomad-Token"] = NOMAD_TOKEN
        if url.startswith("unix://"):
            # Extract the UNIX socket path and the actual URL path
            url_without_scheme = url[7:]  # Remove "unix://"
            unix_socket_path = url_without_scheme.split("/v1/")[0]
            url_path = "/v1/" + url_without_scheme.split("/v1/")[1]
            print (f"unix_socket_path: {unix_socket_path}, url_path: {url_path}, url_path_without_scheme: {url_without_scheme}")
            opener: urllib.request.OpenerDirector = urllib.request.build_opener(
                UnixHTTPHandler(unix_socket_path)
            )
            request = urllib.request.Request(f"unix://localhost{url_path}", headers=headers)
            with opener.open(request, timeout=10.0) as response:
                return(json.loads(response.read().decode()))
        else:
            request = urllib.request.Request(url, headers=headers, method="GET")
            with urllib.request.urlopen(request, timeout=10.0) as response:
                return json.loads(response.read().decode())
    except Exception as e:
        print(f"HTTP request error for {url}: {e}", file=sys.stderr)
        raise


def get_node_id() -> str:
    """Get the current node ID from the Task API."""
    try:
        # Use Task API to get allocation info

        alloc_data = make_http_request( f"{NOMAD_ADDR}/v1/allocation/{os.getenv('NOMAD_ALLOC_ID')}")
        return alloc_data.get("NodeID", "")
    except Exception as e:
        print(f"Error getting node ID: {e}", file=sys.stderr)
        sys.exit(1)


def get_node_allocations(node_id: str) -> List[Dict[str, Any]]:
    """Get all allocations for a specific node."""
    try:
        return make_http_request(f"{NOMAD_ADDR}/v1/node/{node_id}/allocations")
    except Exception as e:
        print(f"Error getting node allocations: {e}", file=sys.stderr)
        return []


def generate_alloy_targets(allocations: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    """Generate Alloy discovery.file targets from Nomad allocations."""
    targets = []

    for alloc in allocations:
        alloc_id = alloc.get("ID", "")
        job_name = alloc.get("JobID", "unknown")
        task_group = alloc.get("TaskGroup", "unknown")
        status = alloc.get("ClientStatus", "unknown")
        namespace = alloc.get("Namespace", "default")

        # Only include running allocations
        if status not in ["running", "pending"]:
            continue

        # Get task names if available
        task_states = alloc.get("TaskStates", {})

        for task_name in task_states.keys():
            # Nomad stores logs in: /opt/nomad/data/alloc/<alloc_id>/alloc/logs/
            stdout_log_path = f"{NOMAD_LOG_DIR}/{alloc_id}/alloc/logs/{task_name}.stdout.0"
            stderr_log_path = f"{NOMAD_LOG_DIR}/{alloc_id}/alloc/logs/{task_name}.stderr.0"

            # Create target for stdout
            targets.append({
                "__path__": stdout_log_path,
                "job": job_name,
                "task_group": task_group,
                "task": task_name,
                "alloc_id": alloc_id,
                "namespace": namespace,
                "stream": "stdout",
                "node_id": alloc.get("NodeID", ""),
            })

            # Create target for stderr
            targets.append({
                "__path__": stderr_log_path,
                "job": job_name,
                "task_group": task_group,
                "task": task_name,
                "alloc_id": alloc_id,
                "namespace": namespace,
                "stream": "stderr",
                "node_id": alloc.get("NodeID", ""),
            })

    return targets


def write_discovery_file(targets: List[Dict[str, Any]]) -> None:
    """Write targets to Alloy module file that exports the targets list."""
    try:
        output_path = Path(OUTPUT_FILE)
        output_path.parent.mkdir(parents=True, exist_ok=True)

        # Generate Alloy module with exported targets
        config_lines = []

        # Add module header comment
        config_lines.append('// Nomad log file targets module')
        config_lines.append('// Generated automatically - do not edit manually')
        config_lines.append('')

        # Declare module - modules must use declare blocks
        config_lines.append('declare "nomad_targets" {')
        config_lines.append('  // Export the list of Nomad allocation log targets')
        config_lines.append('  export "alloc_targets" {')
        config_lines.append('    value = [')

        for target in targets:
            # Format each target as a River map
            labels = []
            for key, value in target.items():
                # Escape quotes and backslashes in values
                escaped_value = str(value).replace('\\', '\\\\').replace('"', '\\"')
                labels.append(f'{key} = "{escaped_value}"')

            labels_str = ', '.join(labels)
            config_lines.append(f'      {{{labels_str}}},')

        config_lines.append('    ]')
        config_lines.append('  }')
        config_lines.append('}')

        # Write to file
        with open(output_path, 'w') as f:
            f.write('\n'.join(config_lines))

        print(f"Generated {len(targets)} targets in {OUTPUT_FILE}")
    except Exception as e:
        print(f"Error writing module file: {e}", file=sys.stderr)
        sys.exit(1)


def main():
    """Main execution function."""
    global running

    # Set up signal handlers for graceful shutdown
    signal.signal(signal.SIGTERM, signal_handler)
    signal.signal(signal.SIGINT, signal_handler)

    print("Starting Nomad to Alloy discovery generator...")
    print(f"Nomad API: {NOMAD_ADDR}")
    print(f"Output module file: {OUTPUT_FILE}")
    print(f"Log directory: {NOMAD_LOG_DIR}")
    print(f"Continuous mode: {CONTINUOUS_MODE}")
    print(f"Refresh interval: {REFRESH_INTERVAL}s")

    # Get current node ID (only once, node doesn't change)
    node_id = get_node_id()
    print(f"Running on node: {node_id}")

    iteration = 0

    while running:
        try:
            iteration += 1
            print(f"\n--- Iteration {iteration} ---")

            # Get all allocations on this node
            allocations = get_node_allocations(node_id)
            print(f"Found {len(allocations)} allocations on node")

            # Generate Alloy targets
            targets = generate_alloy_targets(allocations)

            # Write discovery file
            write_discovery_file(targets)

            print("Discovery file generated successfully!")

            # If not in continuous mode, exit after first run
            if not CONTINUOUS_MODE:
                print("Single run mode - exiting")
                break

            # Sleep for the refresh interval (with periodic checks for shutdown)
            sleep_remaining = REFRESH_INTERVAL
            while sleep_remaining > 0 and running:
                sleep_time = min(5, sleep_remaining)  # Check every 5 seconds
                time.sleep(sleep_time)
                sleep_remaining -= sleep_time

        except KeyboardInterrupt:
            print("\nReceived keyboard interrupt, shutting down...")
            break
        except Exception as e:
            print(f"Error in main loop: {e}", file=sys.stderr)
            if not CONTINUOUS_MODE:
                sys.exit(1)
            # In continuous mode, wait and retry
            print(f"Retrying in {REFRESH_INTERVAL} seconds...")
            time.sleep(REFRESH_INTERVAL)

    print("Discovery generator stopped.")


if __name__ == "__main__":
    main()        
EOH
        }
    }

    task "alloy-agent" {
      # Use Docker driver
      driver = "docker"
      
      # Template for Alloy configuration file
      template {
        destination = "local/config.alloy"
        change_mode = "restart"
        data = <<-EOH
logging {
  level  = "info"
  format = "logfmt"
}

// OTLP gRPC Receiver for OpenTelemetry data
otelcol.receiver.otlp "default" {
  grpc {
    endpoint = "0.0.0.0:4317"
  }
  
  http {
    endpoint = "0.0.0.0:4318"
  }
  
  output {
    metrics = [otelcol.processor.batch.default.input]
    logs    = [otelcol.processor.batch.default.input]
    traces  = [otelcol.processor.batch.default.input]
  }
}

// Batch processor to optimize data sending
otelcol.processor.batch "default" {
  output {
    metrics = [otelcol.exporter.otlphttp.grafana_cloud.input]
    logs    = [otelcol.exporter.otlphttp.grafana_cloud.input]
    traces  = [otelcol.exporter.otlphttp.grafana_cloud.input]
  }
}

// OTLP HTTP Exporter for Grafana Cloud Metrics (Prometheus)
otelcol.exporter.otlphttp "grafana_cloud" {
  client {
    endpoint = "{{ with nomadVar "nomad/jobs/grafana/" }}{{ .otlp_endpoint }}{{ end }}"
    
    auth = otelcol.auth.basic.grafana_cloud.handler
  }
}

// Basic auth for Grafana Cloud
otelcol.auth.basic "grafana_cloud" {
  username = "{{ with nomadVar "nomad/jobs/grafana" }}{{ .traces_instance_id }}{{ end }}"
  password = "{{ with nomadVar "nomad/jobs/grafana" }}{{ .api_key }}{{ end }}"
}


// Scrape metrics from the local Nomad agent
prometheus.scrape "nomad_metrics" {
  targets = [
  // replace with TASK API
    {"__address__" = "{{ env "NOMAD_IP_http" }}:4646"},
  ]
  forward_to = [prometheus.remote_write.grafana_cloud.receiver]
  metrics_path = "/v1/metrics"
  params = {
    format = ["prometheus"],
  }
  scrape_interval = "15s"
}

// Remote write to Grafana Cloud using Nomad Variables for credentials
prometheus.remote_write "grafana_cloud" {
  endpoint {
    url = "{{ with nomadVar "nomad/jobs/grafana/" }}{{ .prometheus_endpoint }}{{ end }}"
    
    basic_auth {
      username = "{{ with nomadVar "nomad/jobs/grafana/" }}{{ .metrics_instance_id }}{{ end }}"
      password = "{{ with nomadVar "nomad/jobs/grafana/" }}{{ .api_key }}{{ end }}"
    }
  }
}

// Get log targets from the generated Nomad module

import.file "nomad" {
  filename = "/alloc/nomad-targets.alloy"
}

// Init the module
nomad.nomad_targets "default" {}

// Log processing example - adjust paths as needed
loki.source.file "nomad_logs" {
  targets    = nomad.nomad_targets.default.alloc_targets
    forward_to = [loki.write.grafana_cloud.receiver]
}

// Remote write logs to Grafana Cloud using Nomad Variables for credentials
loki.write "grafana_cloud" {
  endpoint {
    url = "{{ with nomadVar "nomad/jobs/grafana/" }}{{ .loki_endpoint }}{{ end }}"
    
    basic_auth {
      username = "{{ with nomadVar "nomad/jobs/grafana/" }}{{ .logs_istance_id }}{{ end }}"
      password = "{{ with nomadVar "nomad/jobs/grafana/" }}{{ .api_key }}{{ end }}"
    }
  }
}
EOH
      }
      
      # Docker configuration
      config {
        image = "grafana/alloy:v1.10.0"
        
        # Command arguments
        args = [
          "run",
          "--server.http.listen-addr=0.0.0.0:12345",
          "--storage.path=/var/lib/alloy/data",
          "local/config.alloy"
        ]
        
        # Port mappings
        ports = ["http", "otlp_grpc", "otlp_http"]
   
        
        # Mount host directories for log collection
        mount {
          type     = "bind"
          target   = "/var/log"
          source   = "/var/log"
          readonly = true
        }
        
        # Mount proc filesystem for system metrics
        mount {
          type     = "bind"
          target   = "/host/proc"
          source   = "/proc"
          readonly = true
        }
        
        # Mount sys filesystem for system metrics
        mount {
          type     = "bind"
          target   = "/host/sys"
          source   = "/sys"
          readonly = true
        }
        # Mount Nomad allocation directory to access allocation logs
        mount {
          type     = "bind"
          target   = "/var/nomad/alloc"
          source   = "/var/nomad/alloc"
          readonly = true
        }
      }
      
      # Optional: Volume mount for data persistence
      volume_mount {
        volume      = "alloy-data"
        destination = "/var/lib/alloy/data"
        read_only   = false
      }
      
      # Resource requirements
      resources {
        cpu    = 512    # MHz
        memory = 512    # MB
      }
      
      # Health check using the HTTP endpoint
      service {
        name = "grafana-alloy"
        port = "http"
        provider = "nomad"
        tags = [
          "monitoring",
          "grafana",
          "alloy",
          "metrics",
          "logs"
        ]
        
        check {
          type     = "http"
          path     = "/-/healthy"
          interval = "30s"
          timeout  = "5s"
          
          check_restart {
            limit           = 3
            grace           = "30s"
            ignore_warnings = false
          }
        }
      }
            
      # Kill timeout
      kill_timeout = "30s"
      
      # Kill signal
      kill_signal = "SIGINT"
    }
  }
}
