# shellcheck shell=bash
# Python tool configurations
# This file configures environment variables for Python package managers and tools

# Poetry: Create virtual environments in project directory (.venv) instead of central cache
export POETRY_VIRTUALENVS_IN_PROJECT=true

# Keep project trees clean: never write __pycache__ bytecode beside source
export PYTHONDONTWRITEBYTECODE=1

# Keep project trees clean: suppress pytest's .pytest_cache directory
# Trade-off: also disables the cache-backed reruns (--lf / --ff / --nf)
export PYTEST_ADDOPTS="-p no:cacheprovider"
