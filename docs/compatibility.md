# Compatibility notes

The source still contains a small number of legacy identifiers used by existing profiles, imported links, application upgrades, and the privileged helper service. They are protocol/install contracts, not current product branding.

Do not rename or remove those identifiers as part of a visual rebrand. Before changing one, document its consumers, add a migration that handles already-installed clients, and test upgrade and rollback paths on each affected platform. In particular, subscription header names, import URI aliases, helper service names and old log-file names may be used by existing deployments.

Historical attribution and third-party license notices must also be preserved. Product-facing pages, application labels, release metadata and new assets should use UserNet branding.
