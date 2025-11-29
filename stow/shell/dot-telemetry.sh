# Do Not Track / Disable Telemetry for Popular Tools

# .NET CLI
export DOTNET_CLI_TELEMETRY_OPTOUT=1

# AWS SAM CLI
export SAM_CLI_TELEMETRY=0

# Azure SDK
export AZURE_CORE_COLLECT_TELEMETRY=0
export AZURE_TELEMETRY_DISABLED=1

# Claude Code
export DISABLE_TELEMETRY=1
export DISABLE_ERROR_REPORTING=1
export DISABLE_BUG_COMMAND=1

# Cypress
export CYPRESS_RECORD_KEY=""

# DataDog (if using for tracing)
export DD_INSTRUMENTATION_TELEMETRY_ENABLED=0

# Docker
export DOCKER_CLI_TELEMETRY_OPTOUT=1

# Expo / React Native
export EXPO_NO_TELEMETRY=1

# Gatsby
export GATSBY_TELEMETRY_DISABLED=1

# Google Cloud CLI
export CLOUDSDK_CORE_DISABLE_USAGE_REPORTING=1
# Alternative for some situations:
# gcloud config set disable_usage_reporting true

# Homebrew
export HOMEBREW_NO_ANALYTICS=1

# Next.js
export NEXT_TELEMETRY_DISABLED=1

# npm
# Note: npm doesn't have built-in telemetry. The deprecated metrics-registry config has been removed.

# pnpm
export PNPM_TELEMETRY_DISABLED=1

# Sentry
export SENTRY_DSN=""

# Segment
export SEGMENT_DISABLE=1

# Steam (do not auto-upgrade)
export STNOUPGRADE=1

# Terraform
export CHECKPOINT_DISABLE=1
export TF_CLI_CONFIG_FILE=/dev/null

# TypeScript
export TSC_COMPILE_ON_SAVE_DISABLED=1

# Vite
export VITE_DISABLE_TELEMETRY=1

# Volta
export VOLTA_DISABLE_TELEMETRY=1

# Yarn
export YARN_ENABLE_TELEMETRY=0
