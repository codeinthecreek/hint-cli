CLUSTER ?= lab
REGISTRY := registry.example.org

.PHONY: registry net nodes clean

# ---------------- Cluster ----------------

registry: ## start the local registry
	@docker run -d --restart=always \
	  --name registry -p 5000:5000 \
	  registry:2

# create the cluster network
net:
	@net=$$(docker network ls -q -f name=kind); \
	if [ -z "$$net" ]; then \
	  docker network create kind; \
	fi
	-docker network inspect kind --format "$$X"

nodes:
	kubectl --context kind-$(CLUSTER) get nodes -o wide # all of them
	kubectl get pods -A && kubectl get svc -A

%.o: %.c
	cc -c $< -o $@
