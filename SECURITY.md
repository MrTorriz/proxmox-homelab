# Security policy

## Scope

This repository holds documentation and sanitized configuration for a private Proxmox host.
Nothing here runs anywhere except the CI linters, and nothing published here reaches the
live system. The thing most likely to need reporting is a **sanitization miss**: a real
hostname, address, identifier, credential or anything else that should not be public.

**Sanitization policy.** RFC1918 addressing (`192.168.1.0/24`, `10.10.10.0/24`) and the network topology are published deliberately — they are unreachable from outside and carry no identity. Hostnames, domains, MAC addresses, disk serials/WWNs, account and device identifiers, e-mail addresses and the ISP's name are replaced or removed.

## Reporting

Report privately through GitHub Security Advisories — **Security → Report a vulnerability**
on this repository. Please do not open a public issue for it. Include the file and line,
what you think leaked, and how you found it. Best-effort reply within 7 days.
