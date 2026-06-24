# Test Makefile - Testing operations

# Load shared configuration
include ../Makefile.defs

.PHONY: help prepare validate test clean

.DEFAULT_GOAL := help

help: ## Show this help message
	@printf '%b\n' ''
	@printf '%b\n' 'Test Targets:'
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  $(BLUE)%-20s$(NC) %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@printf '%b\n' ''

# ============================================================================
# Tool Management
# ============================================================================

check-tools: ## Check if required tools are installed
	@printf '%b\n' "$(BLUE)Checking required tools...$(NC)"
	@command -v helm >/dev/null 2>&1 || { echo "$(RED)Error: helm not installed$(NC)"; exit 1; }
	@command -v kubectl >/dev/null 2>&1 || { echo "$(RED)Error: kubectl not installed$(NC)"; exit 1; }
	@command -v kind >/dev/null 2>&1 || { echo "$(RED)Error: kind not installed$(NC)"; exit 1; }
	@command -v yq >/dev/null 2>&1 || { echo "$(RED)Error: yq not installed$(NC)"; exit 1; }
	@printf '%b\n' "$(GREEN)✓ All required tools are installed$(NC)"

install-tools: ## Install required tools (Linux/macOS)
	@printf '%b\n' "$(BLUE)Installing required tools...$(NC)"
	@if [ "$$(uname)" = "Darwin" ]; then \
		brew install helm kubectl kind yq; \
	else \
		curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash; \
		KUBECTL_VER="$(KUBECTL_VERSION)"; \
		if [ -z "$$KUBECTL_VER" ]; then \
			KUBECTL_VER=$$(curl -sL https://dl.k8s.io/release/stable.txt); \
			printf '%b\n' "$(YELLOW)KUBECTL_VERSION empty, resolved latest: %s$(NC)" "$$KUBECTL_VER"; \
		fi; \
		curl -LO "https://dl.k8s.io/release/$$KUBECTL_VER/bin/linux/amd64/kubectl" && \
			sudo install kubectl /usr/local/bin/kubectl && rm kubectl; \
		KIND_VER="$(KIND_VERSION)"; \
		if [ -z "$$KIND_VER" ]; then \
			KIND_VER=$$(curl -s https://api.github.com/repos/kubernetes-sigs/kind/releases/latest \
				| grep -oE '"tag_name": *"v[0-9]+\.[0-9]+\.[0-9]+"' \
				| grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+'); \
			printf '%b\n' "$(YELLOW)KIND_VERSION empty, resolved latest: %s$(NC)" "$$KIND_VER"; \
		fi; \
		curl -Lo kind https://kind.sigs.k8s.io/dl/$$KIND_VER/kind-linux-amd64 && \
			chmod +x kind && sudo mv kind /usr/local/bin/kind; \
		sudo wget -qO /usr/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 && \
			sudo chmod +x /usr/bin/yq; \
	fi
	@printf '%b\n' "$(GREEN)✓ Tools installed$(NC)"

# ============================================================================
# Preparation & Validation
# ============================================================================

prepare: ## Prepare Cilium resources
	@printf '%b\n' "$(BLUE)Preparing Cilium resources...$(NC)"
	@cd $(CILIUM_DIR) && chmod +x $(ROOT_DIR)/cilium/tools/prepareCiliumInstalltion.sh && $(ROOT_DIR)/cilium/tools/prepareCiliumInstalltion.sh
	@printf '%b\n' "$(GREEN)✓ Resources prepared$(NC)"

validate: ## Validate values.yaml configuration
	@printf '%b\n' "$(BLUE)Validating configuration...$(NC)"
	@cd $(CILIUM_DIR) && chmod +x $(ROOT_DIR)/cilium/tools/validateCiliumChart.sh && $(ROOT_DIR)/cilium/tools/validateCiliumChart.sh
	@printf '%b\n' "$(GREEN)✓ Configuration validated$(NC)"

test-syntax: ## Test shell scripts syntax
	@printf '%b\n' "$(BLUE)Testing scripts syntax...$(NC)"
	@for script in $(CILIUM_DIR)/*.sh $(CILIUM_DIR)/tools/*.sh $(TEST_DIR)/scripts/*.sh; do \
		[ -f "$$script" ] && { bash -n "$$script" || exit 1; }; \
	done
	@printf '%b\n' "$(GREEN)✓ All scripts valid$(NC)"

# ============================================================================
# Core Functions (Reusable)
# ============================================================================

# Create a cluster with given parameters
define create-cluster
	@printf '%b\n' "$(BLUE)Creating cluster: $(1)...$(NC)"
	@chmod +x $(TEST_DIR)/scripts/create-kind-cluster.sh
	@export K8S_VERSION=$(K8S_VERSION) ; \
	$(TEST_DIR)/scripts/create-kind-cluster.sh $(1) $(2) $(3)
	@printf '%b\n' "$(GREEN)✓ Cluster $(1) created$(NC)"
endef

# Install Cilium on a cluster
define install-cilium
	@printf '%b\n' "$(BLUE)Installing Cilium on $(1)...$(NC)"
	@kubectl config use-context kind-$(1)
	@chmod +x $(TEST_DIR)/scripts/install-cilium.sh
	@$(TEST_DIR)/scripts/install-cilium.sh $(1) $(2) $(3) $(4) $(5)
	@printf '%b\n' "$(GREEN)✓ Cilium installed on $(1)$(NC)"
endef

# Wait for Cilium to be ready
define wait-cilium
	@printf '%b\n' "$(BLUE)Waiting for Cilium on $(1)...$(NC)"
	@kubectl config use-context kind-$(1)
	@kubectl wait --for=condition=ready pod -l k8s-app=cilium -n kube-system --timeout=5m
	@kubectl wait --for=condition=ready pod -l name=cilium-operator -n kube-system --timeout=5m
	@printf '%b\n' "$(GREEN)✓ Cilium ready on $(1)$(NC)"
endef

# Test connectivity on a cluster
define test-connectivity
	@printf '%b\n' "$(BLUE)Testing connectivity on $(1)...$(NC)"
	@kubectl config use-context kind-$(1)
	@cd $(CILIUM_DIR)/binary && tar -xzf cilium-cli-*-linux-amd64.tar.gz 2>/dev/null || true
	@cd $(CILIUM_DIR)/binary && ./cilium status --wait
	@cd $(CILIUM_DIR)/binary && ./cilium connectivity test --test-concurrency=1 --all-flows=false
	@printf '%b\n' "$(GREEN)✓ Connectivity test passed on $(1)$(NC)"
endef

# ============================================================================
# Single Cluster Test
# ============================================================================

test-single: validate check-tools ## Test single cluster: create -> install -> test connectivity
	@printf '%b\n' "$(BLUE)========================================$(NC)"
	@printf '%b\n' "$(BLUE)Starting Single Cluster Test$(NC)"
	@printf '%b\n' "$(BLUE)========================================$(NC)"
	$(call create-cluster,$(SINGLE_CLUSTER_NAME),$(SINGLE_POD_SUBNET),$(SINGLE_SERVICE_SUBNET))
	$(call install-cilium,$(SINGLE_CLUSTER_NAME),$(SINGLE_CLUSTER_ID),$(SINGLE_POD_SUBNET),$(SINGLE_HUBBLE_PORT),$(SINGLE_CLUSTERMESH_PORT))
	$(call wait-cilium,$(SINGLE_CLUSTER_NAME))
	$(call test-connectivity,$(SINGLE_CLUSTER_NAME))
	@printf '%b\n' "$(GREEN)========================================$(NC)"
	@printf '%b\n' "$(GREEN)✓ Single cluster test completed$(NC)"
	@printf '%b\n' "$(GREEN)========================================$(NC)"

# ============================================================================
# Multi-Cluster Test
# ============================================================================

test-multi: validate check-tools ## Test multi-cluster: create 2 clusters -> install -> test connectivity -> test cross-cluster
	@printf '%b\n' "$(BLUE)========================================$(NC)"
	@printf '%b\n' "$(BLUE)Starting Multi-Cluster Test$(NC)"
	@printf '%b\n' "$(BLUE)========================================$(NC)"
	# Create both clusters
	$(call create-cluster,$(CLUSTER1_NAME),$(CLUSTER1_POD_SUBNET),$(CLUSTER1_SERVICE_SUBNET))
	$(call create-cluster,$(CLUSTER2_NAME),$(CLUSTER2_POD_SUBNET),$(CLUSTER2_SERVICE_SUBNET))
	# Install Cilium on both clusters
	$(call install-cilium,$(CLUSTER1_NAME),$(CLUSTER1_ID),$(CLUSTER1_POD_SUBNET),$(CLUSTER1_HUBBLE_PORT),$(CLUSTER1_CLUSTERMESH_PORT))
	$(call install-cilium,$(CLUSTER2_NAME),$(CLUSTER2_ID),$(CLUSTER2_POD_SUBNET),$(CLUSTER2_HUBBLE_PORT),$(CLUSTER2_CLUSTERMESH_PORT))
	# Wait for both clusters
	$(call wait-cilium,$(CLUSTER1_NAME))
	$(call wait-cilium,$(CLUSTER2_NAME))
	# Test connectivity on both clusters
	$(call test-connectivity,$(CLUSTER1_NAME))
	$(call test-connectivity,$(CLUSTER2_NAME))
	@printf '%b\n' "$(GREEN)========================================$(NC)"
	@printf '%b\n' "$(GREEN)✓ Multi-cluster test completed$(NC)"
	@printf '%b\n' "$(GREEN)========================================$(NC)"

# ============================================================================
# Combined Testing
# ============================================================================

test-all: test-syntax validate test-single test-multi ## Run all tests: validate -> single cluster -> multi-cluster
	@printf '%b\n' "$(GREEN)========================================$(NC)"
	@printf '%b\n' "$(GREEN)✓ All tests completed successfully$(NC)"
	@printf '%b\n' "$(GREEN)========================================$(NC)"

# ============================================================================
# Cleanup
# ============================================================================

clean: ## Clean up all clusters
	@printf '%b\n' "$(YELLOW)Cleaning up all clusters...$(NC)"
	@kind delete cluster --name $(SINGLE_CLUSTER_NAME) 2>/dev/null || true
	@kind delete cluster --name $(CLUSTER1_NAME) 2>/dev/null || true
	@kind delete cluster --name $(CLUSTER2_NAME) 2>/dev/null || true
	@printf '%b\n' "$(GREEN)✓ Cleanup completed$(NC)"

# ============================================================================
# Debug & Utilities
# ============================================================================

status: ## Show status of current cluster
	@printf '%b\n' "$(BLUE)Cilium Status:$(NC)"
	@kubectl get pods -n kube-system -l k8s-app=cilium -o wide
	@kubectl get pods -n kube-system -l name=cilium-operator -o wide
	@printf '%b\n' ""
	@printf '%b\n' "$(BLUE)Nodes:$(NC)"
	@kubectl get nodes -o wide

logs: ## Show Cilium logs
	@printf '%b\n' "$(BLUE)Cilium Agent Logs:$(NC)"
	@kubectl logs -n kube-system -l k8s-app=cilium --tail=50 --prefix=true
	@printf '%b\n' ""
	@printf '%b\n' "$(BLUE)Cilium Operator Logs:$(NC)"
	@kubectl logs -n kube-system -l name=cilium-operator --tail=50

debug: status logs ## Show debug information
	@printf '%b\n' "$(BLUE)All Pods (wide):$(NC)"
	@kubectl get po -A -o wide
	@printf '%b\n' ""
	@printf '%b\n' "$(BLUE)Describing non-Running / non-Succeeded pods:$(NC)"
	@kubectl get po -A --no-headers 2>/dev/null \
		| awk '$$3 != "Running" && $$3 != "Succeeded" {print $$1, $$2}' \
		| while read -r ns pod; do \
			printf '%b\n' "$(RED)########## kubectl describe po -n $$ns $$pod ##########$(NC)"; \
			kubectl describe po -n "$$ns" "$$pod" 2>&1 || true; \
			printf '%b\n' ""; \
		done
	@printf '%b\n' "$(BLUE)Kubernetes Events:$(NC)"
	@kubectl get events -A --sort-by='.lastTimestamp' 2>&1 | tail -50
