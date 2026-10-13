#!/usr/bin/env python3
"""Local Prometheus exporter for the GitOps lab; credentials stay in kubeconfig."""

from __future__ import annotations

import json
import os
import re
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent
CONTEXTS_FILE = Path(os.getenv("OBSERVABILITY_CONTEXTS_FILE", ROOT / "contexts.txt"))
POLL_SECONDS = max(15, int(os.getenv("OBSERVABILITY_POLL_SECONDS", "30")))
METRICS: list[str] = []
LAST_POLL = 0.0
LOCK = threading.Lock()
CONTROLLERS = ["source-controller", "kustomize-controller", "helm-controller", "notification-controller"]
KYVERNO_CONTROLLERS = ["kyverno-admission-controller", "kyverno-background-controller", "kyverno-reports-controller"]


def run(args: list[str], timeout: int = 20) -> str | None:
    try:
        result = subprocess.run(args, check=True, capture_output=True, text=True, timeout=timeout)
        return result.stdout
    except (OSError, subprocess.SubprocessError):
        return None


def kubectl(context: str, *args: str, timeout: int = 20) -> str | None:
    return run(["kubectl", "--context", context, *args], timeout)


def json_command(output: str | None) -> dict[str, Any] | None:
    if not output:
        return None
    try:
        value = json.loads(output)
        if isinstance(value, list):
            return {"items": value}
        return value if isinstance(value, dict) else None
    except json.JSONDecodeError:
        return None


def quote(value: Any) -> str:
    return '"' + str(value).replace("\\", "\\\\").replace("\n", "\\n").replace('"', '\\"') + '"'


def metric(name: str, value: float | int, **labels: Any) -> str:
    label_text = ",".join(f"{key}={quote(val)}" for key, val in sorted(labels.items()))
    return f"{name}{{{label_text}}} {value}" if label_text else f"{name} {value}"


def contexts() -> dict[str, str]:
    result: dict[str, str] = {}
    # k3d emits a top-level array; explicit contexts cover non-k3d clusters.
    raw = run(["k3d", "cluster", "list", "-o", "json"])
    try:
        for cluster in json.loads(raw or "[]"):
            name = cluster.get("name")
            if name:
                result[f"k3d-{name}"] = name
    except (json.JSONDecodeError, AttributeError):
        pass
    if CONTEXTS_FILE.exists():
        for line in CONTEXTS_FILE.read_text(encoding="utf-8").splitlines():
            name = line.strip()
            if name and not name.startswith("#"):
                result.setdefault(name, name)
    for name in os.getenv("OBSERVABILITY_CONTEXTS", "").split(","):
        name = name.strip()
        if name:
            result.setdefault(name, name)
    return result


def ready(deployment: dict[str, Any]) -> bool:
    spec = deployment.get("spec", {})
    status = deployment.get("status", {})
    desired = spec.get("replicas", 1)
    return status.get("observedGeneration", 0) >= deployment.get("metadata", {}).get("generation", 0) and status.get("availableReplicas", 0) >= desired


def add_kyverno_metrics(context: str, cluster: str, output: list[str]) -> None:
    services = json_command(kubectl(context, "-n", "kyverno", "get", "services", "-o", "json"))
    if not services:
        return
    seen: set[str] = set()
    for service in services.get("items", []):
        name = service.get("metadata", {}).get("name", "")
        if "metrics" not in name:
            continue
        for port in service.get("spec", {}).get("ports", []):
            number = port.get("port")
            if not number or (number != 8000 and "metrics" not in port.get("name", "")):
                continue
            path = f"/api/v1/namespaces/kyverno/services/http:{name}:{number}/proxy/metrics"
            raw = kubectl(context, "get", "--raw", path)
            if not raw:
                continue
            for line in raw.splitlines():
                if not line or line.startswith("#") or not line.startswith("kyverno_"):
                    continue
                match = re.match(r"^(\w+)(\{[^}]*\})?(\s+.+)$", line)
                if not match:
                    continue
                labels = match.group(2) or "{}"
                if labels == "{}":
                    labels = "{cluster=" + quote(cluster) + "}"
                else:
                    labels = labels[:-1] + ",cluster=" + quote(cluster) + "}"
                rendered = match.group(1) + labels + match.group(3)
                if rendered not in seen:
                    seen.add(rendered)
                    output.append(rendered)


def collect_context(context: str, cluster: str, output: list[str]) -> None:
    connected = kubectl(context, "get", "--raw", "/version") is not None
    output.append(metric("lab_cluster_up", int(connected), cluster=cluster, context=context))
    if not connected:
        return

    deployments_data = json_command(kubectl(context, "get", "deployments", "-A", "-o", "json"))
    deployments = deployments_data or {"items": []}
    output.append(metric("lab_cluster_deployments_query_success", int(deployments_data is not None), cluster=cluster))
    cluster_flux = [d for d in deployments["items"] if d.get("metadata", {}).get("namespace") == "flux-system" and d.get("metadata", {}).get("name") in CONTROLLERS]
    flux_present = len(cluster_flux) > 0
    flux_ready = len(cluster_flux) == len(CONTROLLERS) and all(ready(d) for d in cluster_flux)
    output.append(metric("lab_flux_installed", int(flux_present), cluster=cluster))
    output.append(metric("lab_flux_healthy", int(flux_ready), cluster=cluster))
    for deployment in cluster_flux:
        meta = deployment.get("metadata", {})
        images = [c.get("image", "") for c in deployment.get("spec", {}).get("template", {}).get("spec", {}).get("containers", [])]
        output.append(metric("lab_flux_controller_info", 1, cluster=cluster, controller=meta.get("name", "unknown"), image=";".join(images)))

    sources = json_command(kubectl(context, "get", "gitrepositories.source.toolkit.fluxcd.io", "-A", "-o", "json")) or {"items": []}
    source_revisions: dict[tuple[str, str], str] = {}
    for source in sources.get("items", []):
        meta = source.get("metadata", {})
        revision = source.get("status", {}).get("artifact", {}).get("revision", "")
        source_revisions[(meta.get("namespace", "flux-system"), meta.get("name", ""))] = revision
        output.append(metric("lab_flux_source_ready", int(any(c.get("type") == "Ready" and c.get("status") == "True" for c in source.get("status", {}).get("conditions", []))), cluster=cluster, namespace=meta.get("namespace", "flux-system"), source=meta.get("name", "unknown"), revision=revision))

    kustomizations = json_command(kubectl(context, "get", "kustomizations.kustomize.toolkit.fluxcd.io", "-A", "-o", "json")) or {"items": []}
    for ks in kustomizations.get("items", []):
        meta, spec, status = ks.get("metadata", {}), ks.get("spec", {}), ks.get("status", {})
        source_ref = spec.get("sourceRef", {})
        source_name = source_ref.get("name", "")
        source_namespace = source_ref.get("namespace", meta.get("namespace", "flux-system"))
        applied = status.get("lastAppliedRevision", "")
        available = source_revisions.get((source_namespace, source_name), "")
        is_ready = any(c.get("type") == "Ready" and c.get("status") == "True" for c in status.get("conditions", []))
        output.append(metric("lab_flux_kustomization_ready", int(is_ready), cluster=cluster, namespace=meta.get("namespace", "default"), kustomization=meta.get("name", "unknown")))
        output.append(metric("lab_flux_revision_in_sync", int(bool(applied) and applied == available), cluster=cluster, namespace=meta.get("namespace", "default"), kustomization=meta.get("name", "unknown"), applied=applied or "unknown", available=available or "unknown"))

    releases = json_command(kubectl(context, "get", "helmreleases.helm.toolkit.fluxcd.io", "-A", "-o", "json")) or {"items": []}
    for release in releases.get("items", []):
        meta, spec, status = release.get("metadata", {}), release.get("spec", {}), release.get("status", {})
        is_ready = any(c.get("type") == "Ready" and c.get("status") == "True" for c in status.get("conditions", []))
        output.append(metric("lab_flux_helmrelease_ready", int(is_ready), cluster=cluster, namespace=meta.get("namespace", "default"), helmrelease=meta.get("name", "unknown"), chart=spec.get("chart", {}).get("spec", {}).get("chart", "unknown"), version=spec.get("chart", {}).get("spec", {}).get("version", "unknown")))

    helm_data = json_command(run(["helm", "list", "-A", "-o", "json", "--kube-context", context]))
    helm = helm_data or {"items": []}
    output.append(metric("lab_helm_inventory_query_success", int(helm_data is not None), cluster=cluster))
    for release in helm.get("items", []):
        chart_full = release.get("chart", "unknown")
        chart_name, separator, chart_version = chart_full.rpartition("-")
        if not separator:
            chart_name, chart_version = chart_full, "unknown"
        output.append(metric("lab_helm_release_info", 1, cluster=cluster, namespace=release.get("namespace", "default"), release=release.get("name", "unknown"), chart=chart_name, chart_version=chart_version, app_version=release.get("app_version", "unknown"), status=release.get("status", "unknown")))

    kyverno_deployments = [d for d in deployments["items"] if d.get("metadata", {}).get("namespace") == "kyverno" and d.get("metadata", {}).get("name", "").startswith("kyverno-")]
    kyverno_by_name = {d.get("metadata", {}).get("name", ""): d for d in kyverno_deployments}
    crds_data = json_command(kubectl(context, "get", "crds", "-o", "json"))
    crds = crds_data or {"items": []}
    kyverno_crds = [crd for crd in crds.get("items", []) if crd.get("metadata", {}).get("name", "").endswith(".kyverno.io") or crd.get("metadata", {}).get("name", "").endswith(".wgpolicyk8s.io")]
    present = bool(kyverno_deployments or kyverno_crds)
    conclusively_absent = not present and deployments_data is not None and crds_data is not None
    healthy = deployments_data is not None and crds_data is not None and all(name in kyverno_by_name and ready(kyverno_by_name[name]) for name in KYVERNO_CONTROLLERS) and bool(kyverno_crds)
    state = "not_installed" if conclusively_absent else ("installed_healthy" if healthy else "partial_or_unhealthy")
    present = present or not conclusively_absent
    output.append(metric("lab_kyverno_installed", int(present), cluster=cluster))
    output.append(metric("lab_kyverno_healthy", int(healthy), cluster=cluster))
    output.append(metric("lab_kyverno_installation_state", 1, cluster=cluster, state=state))

    if present:
        policy_names: set[tuple[str, str, str]] = set()
        for resource in ["clusterpolicies.kyverno.io", "policies.kyverno.io", "clusterpolicies.policies.kyverno.io", "policies.policies.kyverno.io"]:
            policies = json_command(kubectl(context, "get", resource, "-A", "-o", "json")) or {"items": []}
            for policy in policies.get("items", []):
                meta, spec = policy.get("metadata", {}), policy.get("spec", {})
                policy_names.add((meta.get("namespace", "cluster"), meta.get("name", "unknown"), policy.get("kind", "Policy")))
                actions = set(spec.get("validationActions", []))
                actions.add(spec.get("validationFailureAction", ""))
                actions.update(rule.get("validate", {}).get("failureAction", "") for rule in spec.get("rules", []))
                for action in actions - {""}:
                    output.append(metric("lab_kyverno_policy_info", 1, cluster=cluster, policy=meta.get("name", "unknown"), namespace=meta.get("namespace", "cluster"), action=action))
        output.append(metric("lab_kyverno_policy_count", len(policy_names), cluster=cluster))

        reports_data = json_command(kubectl(context, "get", "policyreports.wgpolicyk8s.io,clusterpolicyreports.wgpolicyk8s.io", "-A", "-o", "json"))
        reports = reports_data or {"items": []}
        output.append(metric("lab_kyverno_policy_reports_query_success", int(reports_data is not None), cluster=cluster))
        counts: dict[tuple[str, str, str], int] = {}
        for report in reports.get("items", []):
            namespace = report.get("metadata", {}).get("namespace", "cluster")
            for result in report.get("results", []):
                if result.get("result") == "fail":
                    key = (result.get("policy", "unknown"), result.get("rule", "unknown"), namespace)
                    counts[key] = counts.get(key, 0) + 1
        for (policy, rule, namespace), count in counts.items():
            output.append(metric("lab_kyverno_policy_report_failures", count, cluster=cluster, policy=policy, rule=rule, namespace=namespace))
        add_kyverno_metrics(context, cluster, output)

    for deployment in deployments.get("items", []):
        meta, spec, status = deployment.get("metadata", {}), deployment.get("spec", {}), deployment.get("status", {})
        output.append(metric("lab_deployment_replicas", status.get("availableReplicas", 0), cluster=cluster, namespace=meta.get("namespace", "default"), deployment=meta.get("name", "unknown"), desired=spec.get("replicas", 1)))

    pods = json_command(kubectl(context, "get", "pods", "-A", "-o", "json")) or {"items": []}
    for pod in pods.get("items", []):
        meta, status = pod.get("metadata", {}), pod.get("status", {})
        restarts = sum(c.get("restartCount", 0) for c in status.get("containerStatuses", []))
        output.append(metric("lab_pod_restarts", restarts, cluster=cluster, namespace=meta.get("namespace", "default"), pod=meta.get("name", "unknown")))
    top_nodes = kubectl(context, "top", "nodes", "--no-headers")
    if top_nodes:
        for line in top_nodes.splitlines():
            fields = line.split()
            if len(fields) >= 5:
                output.append(metric("lab_node_cpu_millicores", parse_cpu(fields[1]), cluster=cluster, node=fields[0]))
                output.append(metric("lab_node_memory_bytes", parse_quantity(fields[3]), cluster=cluster, node=fields[0]))
    top = kubectl(context, "top", "pods", "-A", "--no-headers")
    if top:
        for line in top.splitlines():
            fields = line.split()
            if len(fields) >= 4:
                output.append(metric("lab_pod_cpu_millicores", parse_cpu(fields[2]), cluster=cluster, namespace=fields[0], pod=fields[1]))
                output.append(metric("lab_pod_memory_bytes", parse_quantity(fields[3]), cluster=cluster, namespace=fields[0], pod=fields[1]))


def parse_quantity(value: str) -> int:
    match = re.fullmatch(r"([0-9.]+)([a-zA-Z]*)", value)
    if not match:
        return 0
    number, unit = float(match.group(1)), match.group(2)
    if unit == "m":
        return int(number)
    if unit in {"Ki", "Mi", "Gi", "Ti"}:
        return int(number * (1024 ** (1 + ["Ki", "Mi", "Gi", "Ti"].index(unit))))
    if unit == "n":
        return int(number / 1_000_000)
    return int(number)


def parse_cpu(value: str) -> int:
    if value.endswith("m"):
        return int(float(value[:-1]))
    if value.endswith("n"):
        return int(float(value[:-1]) / 1_000_000)
    return int(float(value) * 1000)


def poll() -> None:
    global METRICS, LAST_POLL
    rows = ["# HELP lab_cluster_up Whether the Kubernetes context is reachable.", "# TYPE lab_cluster_up gauge"]
    inventory = contexts()
    for context, name in inventory.items():
        try:
            collect_context(context, name, rows)
        except Exception as exc:  # Keep other clusters visible when one API is unavailable.
            rows.append(metric("lab_cluster_collection_error", 1, cluster=name, reason=type(exc).__name__))
    rows.append(metric("lab_collector_context_count", len(inventory)))
    with LOCK:
        METRICS = rows
        LAST_POLL = time.time()


class Handler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:  # noqa: N802
        if self.path == "/healthz":
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"ok\n")
            return
        if self.path != "/metrics":
            self.send_error(404)
            return
        with LOCK:
            data = "\n".join(METRICS) + "\n"
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
        self.end_headers()
        self.wfile.write(data.encode())

    def log_message(self, fmt: str, *args: Any) -> None:
        return


def main() -> None:
    address = os.getenv("OBSERVABILITY_BIND", "127.0.0.1")
    port = int(os.getenv("OBSERVABILITY_PORT", "9797"))
    server = ThreadingHTTPServer((address, port), Handler)

    def refresh() -> None:
        while True:
            poll()
            time.sleep(POLL_SECONDS)
            poll()

    threading.Thread(target=refresh, daemon=True).start()
    print(f"GitOps lab metrics exporter listening on {address}:{port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
