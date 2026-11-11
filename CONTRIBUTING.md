# Contributing

Issues and pull requests are welcome.

- Keep changes small and say which vendor or script they touch.
- `make lint` and `make test` must pass. Tests use no network and no root; add a test for a new behaviour (synthetic disks and the fake release server in `tests/` cover most of it).
- Scripts are bash with `set -euo pipefail`, checked by shellcheck.
- Workflow actions are pinned by full commit SHA with a version comment; Dependabot updates them. Give each job the least permissions it needs.
- A new vendor is an entry in `config/platforms.json` (OEM id, architectures, formats) plus a README row; do not claim a boot works until it was booted on the vendor.
- Do not rebuild a published release; a fix is a new release with a revision suffix.

Report vulnerabilities as described in [SECURITY.md](SECURITY.md), not in public issues.
