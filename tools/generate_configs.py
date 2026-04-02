#!/usr/bin/env python3
from __future__ import annotations

import csv
import ipaddress
import sys
from collections import defaultdict
from pathlib import Path

import yaml


# 自动识别项目根目录
BASE_DIR = Path(__file__).resolve().parent.parent

CONFIG_DIR = BASE_DIR / "config"
INVENTORY_DIR = BASE_DIR / "inventory"
INSTANCES_DIR = BASE_DIR / "instances"
GENERATED_DIR = BASE_DIR / "generated"

GLOBAL_CONFIG = CONFIG_DIR / "global.yaml"
PROBES_CSV = INVENTORY_DIR / "probes.csv"
TARGETS_CSV = INVENTORY_DIR / "probe_targets.csv"
NETWORKS_CSV = INVENTORY_DIR / "networks.csv"
TEMPLATE_CSV = INVENTORY_DIR / "targets_template.csv"
COMPOSE_YML = GENERATED_DIR / "docker-compose.yml"

VALID_MODULES = {"mtr", "dns", "http", "tcp", "publicip"}
VALID_TARGET_MODULES = {"mtr", "dns", "http", "tcp"}
VALID_NETWORK_MODES = {"macvlan", "host"}


def die(msg: str) -> None:
    print(f"[ERROR] {msg}", file=sys.stderr)
    sys.exit(1)


def warn(msg: str) -> None:
    print(f"[WARN] {msg}")


def info(msg: str) -> None:
    print(f"[INFO] {msg}")


# =========================
# Global config
# =========================
def load_global() -> dict:
    if not GLOBAL_CONFIG.exists():
        die(f"global config not found: {GLOBAL_CONFIG}")

    with GLOBAL_CONFIG.open("r", encoding="utf-8") as f:
        cfg = yaml.safe_load(f) or {}

    try:
        zabbix_server = str(cfg["zabbix"]["server"]).strip()
        zabbix_port = str(cfg["zabbix"]["port"]).strip()
        image_name = str(cfg["docker"]["image"]).strip()
        interval = str(cfg["probe"]["interval"]).strip()
        discovery_interval = str(cfg["probe"]["discovery_interval"]).strip()
    except KeyError as e:
        die(f"missing required key in global.yaml: {e}")

    if not zabbix_server:
        die("zabbix.server is empty in global.yaml")
    if not zabbix_port.isdigit():
        die("zabbix.port must be numeric in global.yaml")
    if not image_name:
        die("docker.image is empty in global.yaml")
    if not interval.isdigit():
        die("probe.interval must be numeric in global.yaml")
    if not discovery_interval.isdigit():
        die("probe.discovery_interval must be numeric in global.yaml")

    return {
        "zabbix_server": zabbix_server,
        "zabbix_port": zabbix_port,
        "image_name": image_name,
        "interval": interval,
        "discovery_interval": discovery_interval,
    }


# =========================
# Networks
# =========================
def read_networks() -> dict[str, dict]:
    if not NETWORKS_CSV.exists():
        die(f"networks csv not found: {NETWORKS_CSV}")

    networks: dict[str, dict] = {}
    seen_subnets: set[ipaddress._BaseNetwork] = set()

    with NETWORKS_CSV.open("r", newline="", encoding="utf-8-sig") as f:
        reader = csv.DictReader(f)
        required = {"network_name", "vlan_id", "parent_if", "subnet", "gateway"}

        if not reader.fieldnames:
            die("networks.csv is empty")

        missing = required - set(reader.fieldnames)
        if missing:
            die(f"networks.csv missing required columns: {', '.join(sorted(missing))}")

        for idx, row in enumerate(reader, start=2):
            network_name = (row.get("network_name") or "").strip()
            vlan_id = (row.get("vlan_id") or "").strip()
            parent_if = (row.get("parent_if") or "").strip()
            subnet_raw = (row.get("subnet") or "").strip()
            gateway_raw = (row.get("gateway") or "").strip()

            if not network_name:
                die(f"networks.csv line {idx}: network_name is empty")
            if not vlan_id:
                die(f"networks.csv line {idx}: vlan_id is empty")
            if not vlan_id.isdigit():
                die(f"networks.csv line {idx}: vlan_id must be numeric")
            if not parent_if:
                die(f"networks.csv line {idx}: parent_if is empty")
            if not subnet_raw:
                die(f"networks.csv line {idx}: subnet is empty")
            if not gateway_raw:
                die(f"networks.csv line {idx}: gateway is empty")

            if network_name in networks:
                die(f"networks.csv line {idx}: duplicate network_name: {network_name}")

            try:
                subnet = ipaddress.ip_network(subnet_raw, strict=True)
            except ValueError as e:
                die(f"networks.csv line {idx}: invalid subnet '{subnet_raw}': {e}")

            try:
                gateway = ipaddress.ip_address(gateway_raw)
            except ValueError as e:
                die(f"networks.csv line {idx}: invalid gateway '{gateway_raw}': {e}")

            if gateway not in subnet:
                die(f"networks.csv line {idx}: gateway {gateway} not in subnet {subnet}")

            if subnet in seen_subnets:
                warn(f"networks.csv line {idx}: duplicate subnet detected: {subnet}")
            seen_subnets.add(subnet)

            networks[network_name] = {
                "network_name": network_name,
                "vlan_id": vlan_id,
                "parent_if": parent_if,
                "subnet": str(subnet),
                "gateway": str(gateway),
            }

    return networks


# =========================
# Probes
# =========================
def read_probes(networks: dict[str, dict]) -> list[dict]:
    if not PROBES_CSV.exists():
        die(f"probes csv not found: {PROBES_CSV}")

    probes: list[dict] = []
    names: set[str] = set()
    zbx_hosts: set[str] = set()
    probe_ips: set[str] = set()

    with PROBES_CSV.open("r", newline="", encoding="utf-8-sig") as f:
        reader = csv.DictReader(f)

        required = {
            "name",
            "zbx_host",
            "checks",
            "public_ip_url",
            "network_mode",
            "network_name",
            "ip",
            "dns_servers",
        }

        if not reader.fieldnames:
            die("probes.csv is empty")

        missing = required - set(reader.fieldnames)
        if missing:
            die(f"probes.csv missing required columns: {', '.join(sorted(missing))}")

        for idx, row in enumerate(reader, start=2):
            name = (row.get("name") or "").strip()
            zbx_host = (row.get("zbx_host") or "").strip()
            checks = (row.get("checks") or "").strip()
            public_ip_url = (row.get("public_ip_url") or "").strip()
            network_mode = (row.get("network_mode") or "").strip().lower()
            network_name = (row.get("network_name") or "").strip()
            ip_raw = (row.get("ip") or "").strip()
            dns_servers_raw = (row.get("dns_servers") or "").strip()

            if not name:
                die(f"probes.csv line {idx}: name is empty")
            if not zbx_host:
                die(f"probes.csv line {idx}: zbx_host is empty")
            if not checks:
                die(f"probes.csv line {idx}: checks is empty")
            if not public_ip_url:
                die(f"probes.csv line {idx}: public_ip_url is empty")
            if not network_mode:
                die(f"probes.csv line {idx}: network_mode is empty")
            if network_mode not in VALID_NETWORK_MODES:
                die(
                    f"probes.csv line {idx}: invalid network_mode '{network_mode}', "
                    f"must be one of: {', '.join(sorted(VALID_NETWORK_MODES))}"
                )
            if not dns_servers_raw:
                die(f"probes.csv line {idx}: dns_servers is empty")

            if name in names:
                die(f"probes.csv line {idx}: duplicate probe name: {name}")
            if zbx_host in zbx_hosts:
                die(f"probes.csv line {idx}: duplicate zbx_host: {zbx_host}")

            check_list = checks.split()
            unknown = [c for c in check_list if c not in VALID_MODULES]
            if unknown:
                die(f"probes.csv line {idx}: unknown checks: {', '.join(unknown)}")

            dns_servers = [x.strip() for x in dns_servers_raw.split(",") if x.strip()]
            if not dns_servers:
                die(f"probes.csv line {idx}: dns_servers has no valid entries")

            for dns_ip in dns_servers:
                try:
                    ipaddress.ip_address(dns_ip)
                except ValueError as e:
                    die(f"probes.csv line {idx}: invalid dns server '{dns_ip}': {e}")

            if network_mode == "macvlan":
                if not network_name:
                    die(f"probes.csv line {idx}: network_name is required for macvlan mode")
                if network_name not in networks:
                    die(f"probes.csv line {idx}: unknown network_name: {network_name}")
                if not ip_raw:
                    die(f"probes.csv line {idx}: ip is required for macvlan mode")

                try:
                    ip_obj = ipaddress.ip_address(ip_raw)
                except ValueError as e:
                    die(f"probes.csv line {idx}: invalid ip '{ip_raw}': {e}")

                subnet_obj = ipaddress.ip_network(networks[network_name]["subnet"], strict=True)
                gateway_obj = ipaddress.ip_address(networks[network_name]["gateway"])

                if ip_obj not in subnet_obj:
                    die(
                        f"probes.csv line {idx}: ip {ip_obj} not in subnet {subnet_obj} "
                        f"for network {network_name}"
                    )

                if ip_obj == gateway_obj:
                    die(
                        f"probes.csv line {idx}: ip {ip_obj} conflicts with gateway "
                        f"for network {network_name}"
                    )

                if ip_raw in probe_ips:
                    die(f"probes.csv line {idx}: duplicate probe ip: {ip_raw}")
                probe_ips.add(ip_raw)

            else:  # host mode
                if network_name:
                    warn(f"probes.csv line {idx}: network_name is ignored in host mode")
                if ip_raw:
                    warn(f"probes.csv line {idx}: ip is ignored in host mode")

                network_name = ""
                ip_raw = ""

            probes.append(
                {
                    "name": name,
                    "zbx_host": zbx_host,
                    "checks": checks,
                    "check_list": check_list,
                    "public_ip_url": public_ip_url,
                    "network_mode": network_mode,
                    "network_name": network_name,
                    "ip": ip_raw,
                    "dns_servers": dns_servers,
                }
            )

            names.add(name)
            zbx_hosts.add(zbx_host)

    return probes


# =========================
# Optional target template generation
# =========================
def generate_targets_from_template(probes: list[dict]) -> None:
    if not TEMPLATE_CSV.exists():
        return

    rows: list[dict] = []
    with TEMPLATE_CSV.open("r", newline="", encoding="utf-8-sig") as f:
        reader = csv.DictReader(f)

        required = {"module", "target", "id", "label", "extra"}
        if not reader.fieldnames:
            die("targets_template.csv is empty")

        missing = required - set(reader.fieldnames)
        if missing:
            die(f"targets_template.csv missing required columns: {', '.join(sorted(missing))}")

        template_rows = list(reader)

    for idx, row in enumerate(template_rows, start=2):
        module = (row.get("module") or "").strip().lower()
        target = (row.get("target") or "").strip()
        item_id = (row.get("id") or "").strip()
        label = (row.get("label") or "").strip()
        extra = (row.get("extra") or "").strip()

        if module not in VALID_TARGET_MODULES:
            die(f"targets_template.csv line {idx}: invalid module '{module}'")
        if not target:
            die(f"targets_template.csv line {idx}: target is empty")
        if not item_id:
            die(f"targets_template.csv line {idx}: id is empty")
        if not label:
            die(f"targets_template.csv line {idx}: label is empty")
        if module == "dns" and not extra:
            die(f"targets_template.csv line {idx}: dns row requires extra(domain)")
        if module != "dns" and extra:
            warn(f"targets_template.csv line {idx}: extra is ignored for module '{module}'")

    for probe in probes:
        enabled_modules = set(probe["check_list"])

        for t in template_rows:
            module = (t["module"] or "").strip().lower()

            # 只给启用了该模块的 probe 生成目标
            if module not in enabled_modules:
                continue

            rows.append(
                {
                    "probe_name": probe["name"],
                    "module": module,
                    "target": (t["target"] or "").strip(),
                    "id": (t["id"] or "").strip(),
                    "label": (t["label"] or "").strip(),
                    "extra": (t["extra"] or "").strip(),
                }
            )

    with TARGETS_CSV.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(
            f,
            fieldnames=["probe_name", "module", "target", "id", "label", "extra"],
        )
        writer.writeheader()
        writer.writerows(rows)

    info("auto generated probe_targets.csv from targets_template.csv")


# =========================
# Targets
# =========================
def read_targets(valid_probe_names: set[str]) -> dict[str, list[dict]]:
    if not TARGETS_CSV.exists():
        die(f"probe_targets csv not found: {TARGETS_CSV}")

    grouped: dict[str, list[dict]] = defaultdict(list)

    with TARGETS_CSV.open("r", encoding="utf-8-sig") as f:
        lines = f.read().splitlines()

    if not lines:
        die("probe_targets.csv is empty")

    header = lines[0]
    header_cols = next(csv.reader([header]))
    expected_header = ["probe_name", "module", "target", "id", "label", "extra"]
    if header_cols != expected_header:
        die(
            "probe_targets.csv header must be exactly: "
            "probe_name,module,target,id,label,extra"
        )

    for line_no, raw_line in enumerate(lines[1:], start=2):
        if not raw_line.strip():
            continue
        cols = next(csv.reader([raw_line]))
        if len(cols) != 6:
            die(
                f"probe_targets.csv line {line_no}: expected 6 columns, got {len(cols)}. "
                f"Non-DNS rows must still keep the last empty 'extra' column."
            )

    with TARGETS_CSV.open("r", newline="", encoding="utf-8-sig") as f:
        reader = csv.DictReader(f)
        required = {"probe_name", "module", "target", "id", "label", "extra"}

        if not reader.fieldnames:
            die("probe_targets.csv is empty")

        missing = required - set(reader.fieldnames)
        if missing:
            die(f"probe_targets.csv missing required columns: {', '.join(sorted(missing))}")

        for idx, row in enumerate(reader, start=2):
            probe_name = (row.get("probe_name") or "").strip()
            module = (row.get("module") or "").strip().lower()
            target = (row.get("target") or "").strip()
            item_id = (row.get("id") or "").strip()
            label = (row.get("label") or "").strip()
            extra = (row.get("extra") or "").strip()

            if not probe_name:
                die(f"probe_targets.csv line {idx}: probe_name is empty")
            if probe_name not in valid_probe_names:
                die(f"probe_targets.csv line {idx}: unknown probe_name: {probe_name}")
            if module not in VALID_TARGET_MODULES:
                die(f"probe_targets.csv line {idx}: invalid module: {module}")
            if not target:
                die(f"probe_targets.csv line {idx}: target is empty")
            if not item_id:
                die(f"probe_targets.csv line {idx}: id is empty")
            if not label:
                die(f"probe_targets.csv line {idx}: label is empty")

            if module == "dns" and not extra:
                die(f"probe_targets.csv line {idx}: dns row requires extra(domain)")
            if module != "dns" and extra:
                warn(f"probe_targets.csv line {idx}: extra is ignored for module '{module}'")

            grouped[probe_name].append(
                {
                    "module": module,
                    "target": target,
                    "id": item_id,
                    "label": label,
                    "extra": extra,
                }
            )

    return grouped


def validate_probe_targets(probes: list[dict], grouped_targets: dict[str, list[dict]]) -> None:
    for probe in probes:
        name = probe["name"]
        check_list = set(probe["check_list"])
        targets = grouped_targets.get(name, [])

        module_count: dict[str, int] = defaultdict(int)
        ids: set[str] = set()

        for item in targets:
            module = item["module"]
            item_id = item["id"]

            if item_id in ids:
                die(f"probe {name}: duplicate id detected: {item_id}")
            ids.add(item_id)

            module_count[module] += 1

            if module not in check_list:
                die(
                    f"probe {name}: target module '{module}' exists, "
                    f"but checks does not include it"
                )

        if "mtr" in check_list and module_count["mtr"] == 0:
            warn(f"probe {name}: checks includes mtr but no mtr target configured")
        if "dns" in check_list and module_count["dns"] == 0:
            warn(f"probe {name}: checks includes dns but no dns target configured")
        if "http" in check_list and module_count["http"] == 0:
            warn(f"probe {name}: checks includes http but no http target configured")
        if "tcp" in check_list and module_count["tcp"] == 0:
            warn(f"probe {name}: checks includes tcp but no tcp target configured")


# =========================
# Build instance files
# =========================
def build_targets_content(target_rows: list[dict], public_ip_url: str) -> str:
    mtr_targets: list[str] = []
    dns_targets: list[str] = []
    http_targets: list[str] = []
    tcp_targets: list[str] = []

    for item in target_rows:
        module = item["module"]
        target = item["target"]
        item_id = item["id"]
        label = item["label"]
        extra = item["extra"]

        if module == "mtr":
            mtr_targets.append(f"{target}|{item_id}|{label}")
        elif module == "dns":
            dns_targets.append(f"{target}|{extra}|{item_id}|{label}")
        elif module == "http":
            http_targets.append(f"{target}|{item_id}|{label}")
        elif module == "tcp":
            tcp_targets.append(f"{target}|{item_id}|{label}")

    lines: list[str] = []

    if mtr_targets:
        lines.append(f'MTR_TARGETS="{",".join(mtr_targets)}"')
        lines.append("")

    if dns_targets:
        lines.append(f'DNS_TARGETS="{",".join(dns_targets)}"')
        lines.append("")

    if http_targets:
        lines.append(f'HTTP_TARGETS="{",".join(http_targets)}"')
        lines.append("")

    if tcp_targets:
        lines.append(f'TCP_TARGETS="{",".join(tcp_targets)}"')
        lines.append("")

    lines.append(f'PUBLIC_IP_URL="{public_ip_url}"')
    lines.append("")

    return "\n".join(lines)


def build_env_content(probe: dict, global_cfg: dict) -> str:
    return (
        f'CHECKS="{probe["checks"]}"\n'
        f'TARGETS_FILE="/config/probe.targets"\n\n'
        f'ZBX_SERVER="{global_cfg["zabbix_server"]}"\n'
        f'ZBX_PORT="{global_cfg["zabbix_port"]}"\n'
        f'ZBX_HOST="{probe["zbx_host"]}"\n\n'
        f'INTERVAL="{global_cfg["interval"]}"\n'
        f'DISCOVERY_INTERVAL="{global_cfg["discovery_interval"]}"\n'
    )


def write_instances(probes: list[dict], grouped_targets: dict[str, list[dict]], global_cfg: dict) -> None:
    INSTANCES_DIR.mkdir(parents=True, exist_ok=True)

    for probe in probes:
        probe_dir = INSTANCES_DIR / probe["name"]
        probe_dir.mkdir(parents=True, exist_ok=True)

        env_file = probe_dir / "probe.env"
        targets_file = probe_dir / "probe.targets"

        env_file.write_text(build_env_content(probe, global_cfg), encoding="utf-8")
        targets_file.write_text(
            build_targets_content(grouped_targets.get(probe["name"], []), probe["public_ip_url"]),
            encoding="utf-8",
        )


# =========================
# Compose
# =========================
def write_compose(probes: list[dict], global_cfg: dict) -> None:
    GENERATED_DIR.mkdir(parents=True, exist_ok=True)

    lines: list[str] = [
        'version: "3.9"',
        "",
        "services:",
    ]

    used_networks: set[str] = set()

    for probe in probes:
        name = probe["name"]
        network_mode = probe["network_mode"]

        lines.extend(
            [
                f"  {name}:",
                f"    image: {global_cfg['image_name']}",
                f"    container_name: {name}",
                "    restart: unless-stopped",
                "    volumes:",
                f"      - {INSTANCES_DIR}/{name}:/config:ro",
            ]
        )

        if network_mode == "host":
            lines.append("    network_mode: host")
        else:
            net = probe["network_name"]
            ip = probe["ip"]
            used_networks.add(net)

            lines.extend(
                [
                    "    networks:",
                    f"      {net}:",
                    f"        ipv4_address: {ip}",
                ]
            )

        if probe["dns_servers"]:
            lines.append("    dns:")
            for dns_ip in probe["dns_servers"]:
                lines.append(f"      - {dns_ip}")

        lines.append("")

    if used_networks:
        lines.append("networks:")
        for net in sorted(used_networks):
            lines.extend(
                [
                    f"  {net}:",
                    "    external: true",
                    "",
                ]
            )

    COMPOSE_YML.write_text("\n".join(lines), encoding="utf-8")


# =========================
# Main
# =========================
def main() -> None:
    global_cfg = load_global()
    networks = read_networks()
    probes = read_probes(networks)

    # 如果有模板文件，就自动生成 probe_targets.csv
    generate_targets_from_template(probes)

    probe_names = {p["name"] for p in probes}
    grouped_targets = read_targets(probe_names)

    validate_probe_targets(probes, grouped_targets)
    write_instances(probes, grouped_targets, global_cfg)
    write_compose(probes, global_cfg)

    info(f"base dir: {BASE_DIR}")
    info(f"generated {len(probes)} probe instance configs")
    info(f"instances dir: {INSTANCES_DIR}")
    info(f"compose file: {COMPOSE_YML}")


if __name__ == "__main__":
    main()
