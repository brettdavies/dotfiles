# shellcheck shell=bash
# dogshell (`dog`, from the `datadog` Python package) sends its requests to
# DATADOG_HOST when no --api_host is given. The org is on the US3 site.
export DATADOG_HOST=https://api.us3.datadoghq.com
