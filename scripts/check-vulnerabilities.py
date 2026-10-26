"""Block publication when Debian has an available fix for High/Critical OS CVEs."""
import json
import sys


def fixable_debian_findings(report):
    findings = []
    for result in report.get("Results", []):
        if not str(result.get("Type", "")).lower().startswith("debian"):
            continue
        for vulnerability in result.get("Vulnerabilities", []) or []:
            if (
                vulnerability.get("Severity") in {"HIGH", "CRITICAL"}
                and vulnerability.get("FixedVersion")
            ):
                findings.append(vulnerability)
    return findings


if __name__ == "__main__":
    with open(sys.argv[1], encoding="utf-8") as stream:
        report = json.load(stream)
    if report.get("SchemaVersion") != 2 or not report.get("Results"):
        raise SystemExit("Missing or unsupported Trivy vulnerability scan results")
    findings = fixable_debian_findings(report)
    for finding in findings:
        print(
            f"{finding['VulnerabilityID']}: {finding['PkgName']} "
            f"{finding['InstalledVersion']} -> {finding['FixedVersion']}"
        )
    print(f"Fixable Debian High/Critical findings: {len(findings)}")
    raise SystemExit(bool(findings))
