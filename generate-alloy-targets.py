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
