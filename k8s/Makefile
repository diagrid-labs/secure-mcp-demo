# secure-mcp k8s install automation.
#
# `make install-ingress`    — install ingress-nginx with the Azure DNS label
# `make install`            — install the secure-mcp chart
# `make agent-tokens`       — cache agent App ID tokens in a Kubernetes Secret
# `make register-appids`    — point Catalyst at each MCP server's path
# `make build-images`       — build the two Docker images
# `make push-images`        — push to $REGISTRY
# `make uninstall`          — helm uninstall

# ── Configurable ───────────────────────────────────────────────────────────
NAMESPACE          ?= secure-mcp
RELEASE            ?= secure-mcp
REGISTRY           ?= tezizzm
IMAGE_TAG          ?= v1
AZURE_REGION       ?= eastus
# One DNS label shared by the whole stack — points at the nginx-ingress
# controller's LoadBalancer. nginx routes by path to the 5 services
# behind it.
INGRESS_DNS_LABEL  ?= securemcp
DIAGRID_PROJECT    ?= secure-mcp-demo
DIAGRID_API_KEY    ?=
CATALYST_HTTP_ENDPOINT ?=
CATALYST_GRPC_ENDPOINT ?=
HELM_FORCE_CONFLICTS ?= false
HELM_TIMEOUT ?= 15m
# Catalyst's project egress IPs. Comma-separated. Applied to the
# nginx-ingress controller Service via `make install-ingress`.
CATALYST_EGRESS_CIDRS ?=

# Optional Docker Hub credentials. When set, `make install` creates a
# `regcred` Secret in $(NAMESPACE) and wires it into all pods (our
# Deployments + the bitnami postgresql/keycloak subcharts). Lifts the
# anonymous pull rate limit (100/6h → 200/6h for free Docker Hub accounts).
DOCKERHUB_USERNAME ?=
DOCKERHUB_PAT      ?=
DOCKERHUB_EMAIL    ?= $(DOCKERHUB_USERNAME)@example.invalid

# Computed
INGRESS_FQDN  := $(INGRESS_DNS_LABEL).$(AZURE_REGION).cloudapp.azure.com
KEYCLOAK_URL  := http://$(INGRESS_FQDN)/keycloak
CHART_DIR     := helm/secure-mcp
REPO_ROOT     := $(shell git rev-parse --show-toplevel)

# Convert CATALYST_EGRESS_CIDRS=a,b,c → "{a,b,c}" for helm --set lists
EGRESS_HELM_LIST := $(if $(CATALYST_EGRESS_CIDRS),{$(CATALYST_EGRESS_CIDRS)},)

# ── Targets ────────────────────────────────────────────────────────────────
.PHONY: help install install-ingress uninstall uninstall-ingress \
        build-images push-images deps lint render agent-tokens register-appids fqdns

help:
	@echo "secure-mcp k8s install"
	@echo ""
	@echo "Variables (override on the command line):"
	@echo "  REGISTRY              = $(REGISTRY)"
	@echo "  IMAGE_TAG             = $(IMAGE_TAG)"
	@echo "  NAMESPACE             = $(NAMESPACE)"
	@echo "  RELEASE               = $(RELEASE)"
	@echo "  AZURE_REGION          = $(AZURE_REGION)"
	@echo "  INGRESS_DNS_LABEL     = $(INGRESS_DNS_LABEL)"
	@echo "  DIAGRID_PROJECT       = $(DIAGRID_PROJECT)"
	@echo "  DIAGRID_API_KEY       = $(if $(DIAGRID_API_KEY),<set>,<unset>)"
	@echo "  CATALYST_HTTP_ENDPOINT = $(CATALYST_HTTP_ENDPOINT)"
	@echo "  CATALYST_GRPC_ENDPOINT = $(CATALYST_GRPC_ENDPOINT)"
	@echo "  HELM_FORCE_CONFLICTS  = $(HELM_FORCE_CONFLICTS)"
	@echo "  HELM_TIMEOUT          = $(HELM_TIMEOUT)"
	@echo "  CATALYST_EGRESS_CIDRS = $(CATALYST_EGRESS_CIDRS)"
	@echo "  DOCKERHUB_USERNAME    = $(DOCKERHUB_USERNAME)"
	@echo "  DOCKERHUB_PAT         = $(if $(DOCKERHUB_PAT),<set>,<unset>)"
	@echo ""
	@echo "Shared FQDN: $(INGRESS_FQDN)"
	@echo ""
	@echo "Targets:"
	@echo "  make install-ingress  install nginx-ingress with Azure LB + DNS label"
	@echo "  make build-images     build mcp-server + ui-backend images"
	@echo "  make push-images      docker push both"
	@echo "  make deps             helm dependency build (resolves bitnami tgzs)"
	@echo "  make lint             helm lint"
	@echo "  make render           helm template (preview without installing)"
	@echo "  make install          helm upgrade --install the secure-mcp chart"
	@echo "  make agent-tokens     cache Catalyst agent tokens in a Secret"
	@echo "  make register-appids  point Catalyst at each MCP server's path"
	@echo "  make fqdns            print the public URLs of every service"
	@echo "  make uninstall        helm uninstall + delete namespace"
	@echo "  make uninstall-ingress  uninstall nginx-ingress"

fqdns:
	@echo "ui-backend:      http://$(INGRESS_FQDN)/"
	@echo "keycloak:        http://$(INGRESS_FQDN)/keycloak"
	@echo "mcp-db-query:    http://$(INGRESS_FQDN)/mcp/query"
	@echo "mcp-db-write:    http://$(INGRESS_FQDN)/mcp/write"
	@echo "mcp-db-delete:   http://$(INGRESS_FQDN)/mcp/delete"

# Multi-arch via buildx: AKS nodes are linux/amd64, local dev (Apple Silicon)
# is linux/arm64. One manifest covers both; --push goes straight to Docker Hub
# (buildx can't load multi-arch manifests into the local daemon).
#
# BUILDX_BUILDER must point at a `docker-container` driver builder — the
# default `docker` driver only builds for the host architecture. Run
# `docker buildx ls` to see your builders; create one with
# `docker buildx create --name multiarch --driver docker-container`.
PLATFORMS      ?= linux/amd64,linux/arm64
BUILDX_BUILDER ?= multiarch

build-images:
	docker buildx build --builder $(BUILDX_BUILDER) --platform $(PLATFORMS) --push \
	  -f docker/mcp-server.Dockerfile -t $(REGISTRY)/secure-mcp-server:$(IMAGE_TAG) $(REPO_ROOT)
	docker buildx build --builder $(BUILDX_BUILDER) --platform $(PLATFORMS) --push \
	  -f docker/ui-backend.Dockerfile -t $(REGISTRY)/secure-mcp-ui:$(IMAGE_TAG)     $(REPO_ROOT)

# Kept as an alias for backwards compatibility. `build-images` already pushes
# because buildx requires --push for multi-arch.
push-images: ;

deps:
	helm dependency build $(CHART_DIR)
	@# Helm v4 leaves deps as .tgz in charts/, but helm install/template
	@# refuses to use them until they're unpacked. Unpack idempotently.
	@cd $(CHART_DIR)/charts 2>/dev/null && for tgz in *.tgz; do \
	  [ -e "$$tgz" ] || continue; \
	  name=$$(echo "$$tgz" | sed 's/-[0-9].*//'); \
	  [ -d "$$name" ] || tar -xzf "$$tgz"; \
	done; true

lint: deps
	helm lint $(CHART_DIR)

# ── ingress-nginx install ─────────────────────────────────────────────────
# One Azure LB fronting nginx-ingress. The DNS label gives the predictable
# FQDN baked into KC_HOSTNAME_URL + the Catalyst app-endpoint registrations.
# The Catalyst egress allowlist is applied here, on the controller Service —
# one place to keep in sync.
install-ingress:
	helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || true
	helm repo update ingress-nginx
	helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
	  --namespace ingress-nginx --create-namespace \
	  --set 'controller.service.annotations.service\.beta\.kubernetes\.io/azure-dns-label-name=$(INGRESS_DNS_LABEL)' \
	  --set 'controller.service.annotations.service\.beta\.kubernetes\.io/azure-load-balancer-health-probe-request-path=/healthz' \
	  $(if $(EGRESS_HELM_LIST),--set "controller.service.loadBalancerSourceRanges=$(EGRESS_HELM_LIST)",)
	@echo ""
	@echo "Wait ~1-2 min for the Azure LB IP to provision, then verify:"
	@echo "  curl -sI http://$(INGRESS_FQDN)"

uninstall-ingress:
	-helm uninstall ingress-nginx -n ingress-nginx
	-kubectl delete namespace ingress-nginx

# ── secure-mcp chart install ──────────────────────────────────────────────
# Catalyst data-plane endpoints are looked up inside the install target
# (single diagrid call, jq twice, no make-parse-time double-invocation).

# When DOCKERHUB_USERNAME is set, plumb `regcred` into our chart + the
# bitnami subcharts. Bitnami honors `global.imagePullSecrets[]` at the
# top level (cascades into every chart in the dep tree), not per-subchart.
PULL_SECRET_FLAGS := $(if $(DOCKERHUB_USERNAME), \
  --set imagePullSecrets[0].name=regcred \
  --set global.imagePullSecrets[0]=regcred,)

CATALYST_ENABLED_FLAGS := $(if $(DIAGRID_API_KEY),--set catalyst.enabled=true,)
CATALYST_ENDPOINT_FLAGS := \
  $(if $(CATALYST_HTTP_ENDPOINT),--set catalyst.httpEndpoint=$(CATALYST_HTTP_ENDPOINT),) \
  $(if $(CATALYST_GRPC_ENDPOINT),--set catalyst.grpcEndpoint=$(CATALYST_GRPC_ENDPOINT),)

HELM_COMMON_FLAGS = \
  --set mcpServer.image.repository=$(REGISTRY)/secure-mcp-server \
  --set mcpServer.image.tag=$(IMAGE_TAG) \
  --set ui.image.repository=$(REGISTRY)/secure-mcp-ui \
  --set ui.image.tag=$(IMAGE_TAG) \
  --set catalyst.project=$(DIAGRID_PROJECT) \
  --set ingress.host=$(INGRESS_FQDN) \
  $(PULL_SECRET_FLAGS) \
  $(CATALYST_ENABLED_FLAGS) \
  $(CATALYST_ENDPOINT_FLAGS) \
  --set        'keycloak.extraEnvVars[0].name=KC_HOSTNAME_STRICT' \
  --set-string 'keycloak.extraEnvVars[0].value=false' \
  --set        'keycloak.extraEnvVars[1].name=KC_HOSTNAME_STRICT_HTTPS' \
  --set-string 'keycloak.extraEnvVars[1].value=false' \
  --set        'keycloak.extraEnvVars[2].name=KC_HTTP_RELATIVE_PATH' \
  --set-string 'keycloak.extraEnvVars[2].value=/keycloak/' \
  --set        'keycloak.extraEnvVars[3].name=KEYCLOAK_HOSTNAME' \
  --set-string 'keycloak.extraEnvVars[3].value=$(KEYCLOAK_URL)'

render: deps
	@helm template $(RELEASE) $(CHART_DIR) --namespace $(NAMESPACE) $(HELM_COMMON_FLAGS)

agent-tokens:
	@kubectl create namespace $(NAMESPACE) --dry-run=client -o yaml | kubectl apply -f -
	@if [ -z "$(DIAGRID_API_KEY)" ]; then \
	  echo "WARNING: DIAGRID_API_KEY is not set — skipping catalyst-agent-tokens Secret"; \
	  echo "         UI backend will fall back to diagrid CLI lookup at runtime."; \
	else \
	  echo ">>> Creating/updating Catalyst agent token Secret"; \
	  ANALYST_TOKEN=$$(diagrid appid get analyst-agent --project $(DIAGRID_PROJECT) -o json | jq -r '.status.apiToken // empty') ; \
	  OPS_TOKEN=$$(diagrid appid get ops-agent --project $(DIAGRID_PROJECT) -o json | jq -r '.status.apiToken // empty') ; \
	  ADMIN_TOKEN=$$(diagrid appid get admin-agent --project $(DIAGRID_PROJECT) -o json | jq -r '.status.apiToken // empty') ; \
	  kubectl -n $(NAMESPACE) create secret generic catalyst-agent-tokens \
	    --from-literal=analyst=$$ANALYST_TOKEN \
	    --from-literal=ops=$$OPS_TOKEN \
	    --from-literal=admin=$$ADMIN_TOKEN \
	    --from-literal=present=true \
	    --dry-run=client -o yaml | kubectl apply -f -; \
	fi

install: deps
	@kubectl create namespace $(NAMESPACE) --dry-run=client -o yaml | kubectl apply -f -
	@if [ -n "$(DIAGRID_API_KEY)" ]; then \
	  echo ">>> Creating/updating catalyst-api-key Secret"; \
	  kubectl -n $(NAMESPACE) create secret generic catalyst-api-key \
	    --from-literal=apiKey=$(DIAGRID_API_KEY) \
	    --dry-run=client -o yaml | kubectl apply -f -; \
	fi
	@$(MAKE) -s agent-tokens \
	  NAMESPACE=$(NAMESPACE) \
	  DIAGRID_PROJECT=$(DIAGRID_PROJECT) \
	  DIAGRID_API_KEY="$(DIAGRID_API_KEY)"
	@if [ -n "$(DOCKERHUB_USERNAME)" ] && [ -n "$(DOCKERHUB_PAT)" ]; then \
	  echo ">>> Creating/updating regcred docker-registry Secret"; \
	  kubectl -n $(NAMESPACE) create secret docker-registry regcred \
	    --docker-server=https://index.docker.io/v1/ \
	    --docker-username=$(DOCKERHUB_USERNAME) \
	    --docker-password=$(DOCKERHUB_PAT) \
	    --docker-email=$(DOCKERHUB_EMAIL) \
	    --dry-run=client -o yaml | kubectl apply -f -; \
	elif [ -n "$(DOCKERHUB_USERNAME)" ] && [ -z "$(DOCKERHUB_PAT)" ]; then \
	  echo "WARNING: DOCKERHUB_USERNAME set but DOCKERHUB_PAT missing — skipping regcred Secret"; \
	fi
	@echo ">>> Resolving Catalyst data-plane endpoints from diagrid project get"
	@PROJECT_JSON=$$(diagrid project get $(DIAGRID_PROJECT) -o json 2>/dev/null || true) ; \
	HTTP_EP="$(CATALYST_HTTP_ENDPOINT)" ; \
	GRPC_EP="$(CATALYST_GRPC_ENDPOINT)" ; \
	if [ -z "$$HTTP_EP" ]; then HTTP_EP=$$(echo "$$PROJECT_JSON" | jq -r '.status.endpoints.http.url // empty' 2>/dev/null || true); fi ; \
	if [ -z "$$GRPC_EP" ]; then GRPC_EP=$$(echo "$$PROJECT_JSON" | jq -r '.status.endpoints.grpc.url // empty' 2>/dev/null || true); fi ; \
	if [ -z "$$HTTP_EP" ]; then echo "WARNING: HTTP endpoint not resolved — UI backend will fall back to CLI lookup at runtime"; fi ; \
	helm upgrade --install $(RELEASE) $(CHART_DIR) \
	  --namespace $(NAMESPACE) --create-namespace \
	  --timeout $(HELM_TIMEOUT) \
	  $(if $(filter true,$(HELM_FORCE_CONFLICTS)),--force-conflicts,) \
	  $(HELM_COMMON_FLAGS) \
	  --set catalyst.httpEndpoint=$$HTTP_EP \
	  --set catalyst.grpcEndpoint=$$GRPC_EP
	@echo ""
	@echo "Endpoints (allow ~1-2 min for ingress-nginx to wire up the LB if you just did install-ingress):"
	@$(MAKE) -s fqdns
	@echo ""
	@echo "Then run:  make register-appids"

register-appids:
	@echo ">>> Registering MCP server path-based endpoints with Catalyst"
	@echo "    (verify --app-endpoint against \`diagrid appid update --help\`"
	@echo "     if your CLI version uses a different flag name)"
	diagrid appid update mcp-db-query  --project $(DIAGRID_PROJECT) --app-endpoint http://$(INGRESS_FQDN)/mcp/query
	diagrid appid update mcp-db-write  --project $(DIAGRID_PROJECT) --app-endpoint http://$(INGRESS_FQDN)/mcp/write
	diagrid appid update mcp-db-delete --project $(DIAGRID_PROJECT) --app-endpoint http://$(INGRESS_FQDN)/mcp/delete
	@echo ""
	@echo "Verify Catalyst → app reachability:"
	@echo "  diagrid appid get mcp-db-query --project $(DIAGRID_PROJECT) -o json | jq '.status'"

uninstall:
	-helm uninstall $(RELEASE) -n $(NAMESPACE)
	-kubectl delete namespace $(NAMESPACE)
