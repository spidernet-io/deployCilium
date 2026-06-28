# Main Makefile - Entry point for all operations

include Makefile.defs

.PHONY: help all test clean

.DEFAULT_GOAL := help

help: ## Show this help message
	@printf '%b\n' ''
	@printf '%b\n' '$(BLUE)Cilium Deployment Project$(NC)'
	@printf '%b\n' ''
	@printf '%b\n' 'Usage:'
	@printf '%b\n' '  make <target>'
	@printf '%b\n' ''
	@printf '%b\n' 'Main Targets:'
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  $(BLUE)%-20s$(NC) %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@printf '%b\n' ''
	@printf '%b\n' 'Test Targets (from test/Makefile):'
	@$(MAKE) -C $(TEST_DIR) help | grep -A 100 "Targets:" | tail -n +2

# ============================================================================
# Tool Management
# ============================================================================

check-tools: ## Check if required tools are installed
	@$(MAKE) -C $(TEST_DIR) check-tools

install-tools: ## Install required tools
	@$(MAKE) -C $(TEST_DIR) install-tools

# ============================================================================
# Preparation & Validation
# ============================================================================

prepare: ## Prepare Cilium resources
	@$(MAKE) -C $(TEST_DIR) prepare

validate: ## Validate Cilium configuration
	@$(MAKE) -C $(TEST_DIR) validate

test-syntax: ## Test shell scripts syntax
	@$(MAKE) -C $(TEST_DIR) test-syntax

# ============================================================================
# Testing
# ============================================================================

test-single: ## Run single cluster test
	@$(MAKE) -C $(TEST_DIR) test-single

test-multi: ## Run multi-cluster test
	@$(MAKE) -C $(TEST_DIR) test-multi

test-all: ## Run all tests
	@$(MAKE) -C $(TEST_DIR) test-all

test: test-all ## Alias for test-all

# ============================================================================
# Cluster & Debug Utilities
# ============================================================================

status: ## Show status of current cluster
	@$(MAKE) -C $(TEST_DIR) status

# ============================================================================
# Debug & Cleanup
# ============================================================================

logs: ## Show Cilium logs
	@$(MAKE) -C $(TEST_DIR) logs

debug: ## Show debug information
	@$(MAKE) -C $(TEST_DIR) debug

clean: ## Clean up all clusters
	@$(MAKE) -C $(TEST_DIR) clean

# ============================================================================
# CI/CD Targets
# ============================================================================

ci-validate: check-tools test-syntax validate ## Run validation for CI
	@printf '%b\n' "$(GREEN)✓ CI validation completed$(NC)"
