mkfile_path := $(abspath $(lastword $(MAKEFILE_LIST)))
base_dir := $(notdir $(patsubst %/,%,$(dir $(mkfile_path))))
SERVICE ?= $(base_dir)

BUILDENV := CGO_ENABLED=0
BUILDENV += GO111MODULE=on

GIT_HASH := $(CIRCLE_SHA1)
ifeq ($(GIT_HASH),)
	GIT_HASH := $(shell git rev-parse HEAD)
endif

LINKFLAGS :=-s -X main.gitHash=$(GIT_HASH) -extldflags "-static"
TESTFLAGS := -v -cover -timeout 30s

LINT_FLAGS :=--enable golint,unconvert,unparam,gofmt
LINTER_EXE := golangci-lint
LINTER := $(GOPATH)/bin/$(LINTER_EXE)

DOCKER_ID=payments-circle
DOCKER_REGISTRY=registry.uw.systems
DOCKER_REPOSITORY_NAMESPACE=payments
DOCKER_REPOSITORY_IMAGE=$(SERVICE)
DOCKER_REPOSITORY=$(DOCKER_REGISTRY)/$(DOCKER_REPOSITORY_NAMESPACE)/$(DOCKER_REPOSITORY_IMAGE)
DOCKER_IMAGE_TAG=$(GIT_HASH)

K8S_NAMESPACE=KUBERNETES_NAMESPACE
K8S_DEPLOYMENT_NAME=$(SERVICE)
K8S_CONTAINER_NAME=$(SERVICE)
K8S_URL=https://elb.master.k8s.dev.uw.systems/apis/apps/v1/namespaces/$(K8S_NAMESPACE)/deployments/$(K8S_DEPLOYMENT_NAME)
K8S_PAYLOAD={"spec":{"template":{"spec":{"containers":[{"name":"$(K8S_CONTAINER_NAME)","image":"$(DOCKER_REPOSITORY):$(DOCKER_IMAGE_TAG)"}]}}}}

.DEFAULT_GOAL := rebuild


protos:
	echo "compile protocol buffers"


mockgen-install:
	go get github.com/golang/mock/gomock
	go install github.com/golang/mock/mockgen

mockgen:
	echo "generate mock"


.PHONY: install
install:
	go get -v ./...

$(LINTER):
	go get -u github.com/golangci/golangci-lint/cmd/golangci-lint

.PHONY: lint
lint: $(LINTER)
	$(LINTER) run $(LINT_FLAGS)

.PHONY: test
test:
	$(BUILDENV) go test $(TESTFLAGS) ./...

$(SERVICE):
	$(BUILDENV) go build -o $(SERVICE) -a -ldflags '$(LINKFLAGS)' .

.PHONY: build
build: $(SERVICE)

.PHONY: clean
clean:
	@rm -f $(SERVICE)

.PHONY: rebuild
rebuild: clean $(SERVICE)

.PHONY: all
all: install lint test rebuild


docker-image:
		docker build -t $(DOCKER_REPOSITORY):local . \
				--build-arg GITHUB_TOKEN=$(GITHUB_TOKEN) \
				--build-arg SERVICE=$(SERVICE)

docker-auth:
		@echo "Logging in to $(DOCKER_REGISTRY) as $(DOCKER_ID)"
		@docker login -u $(DOCKER_ID) -p $(DOCKER_PASSWORD) $(DOCKER_REGISTRY)

ci-docker-build: docker-auth
		docker build -t $(DOCKER_REPOSITORY):$(DOCKER_IMAGE_TAG) . \
				--build-arg GITHUB_TOKEN=$(GITHUB_TOKEN) \
				--build-arg SERVICE=$(SERVICE)
		docker tag $(DOCKER_REPOSITORY):$(DOCKER_IMAGE_TAG) $(DOCKER_REPOSITORY):latest
		docker push $(DOCKER_REPOSITORY)

ci-kubernetes-push:
	test "$(shell curl -o /dev/null -w '%{http_code}' -s -X PATCH -k -d '$(K8S_PAYLOAD)' -H 'Content-Type: application/strategic-merge-patch+json' -H 'Authorization: Bearer $(K8S_DEV_TOKEN)' '$(K8S_URL)')" -eq "200"
