IMAGE ?= docker-dc-micro-release.dr.corp.adobe.com/staging/awsservicebroker/aws-servicebroker
TAG  ?= latest
BUCKET_NAME ?= my-helm-repo-bucket
BUCKET_PREFIX ?= /charts
TEMPLATE_PREFIX ?= /templates/latest
FUNCTION_PREFIX ?= /functions
LAYER_PREFIX ?= /layers
HELM_URL ?= https://$(BUCKET_NAME).s3.amazonaws.com$(BUCKET_PREFIX)
S3URI ?= $(shell echo $(HELM_URL)/ | sed 's/https:/s3:/' | sed 's/.s3.amazonaws.com//')
ACL ?= private
PROFILE_NAME ?= ""
PROFILE ?= $(shell if [ "${PROFILE_NAME}" != "" ] ; then echo "--profile ${PROFILE_NAME}" ; fi)
VERSION ?= $(shell cat ./version)
TEMPLATES ?= $(shell cd templates ; ls -1 ; cd ..)
FUNCTIONS ?= $(shell cd functions ; ls -1 ; cd ..)
LAYERS ?= $(shell cd layers ; ls -1 ; cd ..)

build: ## Builds the starter pack
	go build -i github.com/adobe-platform/aws-servicebroker/cmd/servicebroker

test: ## Runs the tests
	go test -v $(shell go list ./... | grep -v /vendor/ | grep -v /test/)

functional-test: ## Builds and execs a minikube image for functional testing
	GOOS=linux GOARCH=amd64 CGO_ENABLED=0 \
    go build -o functional-testing/aws-servicebroker --ldflags="-s" github.com/adobe-platform/aws-servicebroker/cmd/servicebroker && \
    cd functional-testing ; \
      docker build -t aws-sb:functest . && \
      docker run --privileged -it --rm aws-sb:functest /start.sh ; \
    cd ../

linux: ## Builds a Linux executable
	GOOS=linux GOARCH=amd64 CGO_ENABLED=0 \
	go build -o servicebroker-linux --ldflags="-s" github.com/adobe-platform/aws-servicebroker/cmd/servicebroker

debug: ## Builds a debuggable executable targeted to the host.
	CGO_ENABLED=0 \
	go build -o servicebroker --ldflags="-s" -gcflags="all=-N -l" github.com/adobe-platform/aws-servicebroker/cmd/servicebroker

cf: ## Builds a PCF tile and bosh release
	GOOS=linux GOARCH=amd64 CGO_ENABLED=0 \
    go build -o packaging/cloudfoundry/resources/cfnsb --ldflags="-s" github.com/adobe-platform/aws-servicebroker/cmd/servicebroker && \
	cd packaging/cloudfoundry/ ; \
	  tile build $(VERSION); \
	cd ../../

image: ## Builds docker image
	docker build . -t $(IMAGE):$(TAG)

push-image: image
	docker push $(IMAGE):$(TAG)

clean: ## Cleans up build artifacts
	rm -f servicebroker
	rm -f servicebroker-linux
	rm -f functional-testing/aws-servicebroker
	rm -rf packaging/cloudfoundry/product
	rm -rf packaging/cloudfoundry/release
	rm -f packaging/helm/index.yaml
	rm -f packaging/helm/aws-servicebroker-*.tgz
	rm -rf release/

helm: ## Creates helm release and repository index file
	cd packaging/helm/ ; \
	helm package aws-servicebroker --version $(VERSION) && \
		helm repo index . --url $(HELM_URL) ; \
	cd ../../

deploy-chart: ## Deploys helm chart and index file to S3 path specified by HELM_URL
	make helm && \
	aws s3 cp packaging/helm/aws-servicebroker-*.tgz $(S3URI) --acl $(ACL) $(PROFILE) && \
	aws s3 cp packaging/helm/index.yaml $(S3URI) --acl $(ACL) $(PROFILE)

release: ## Package and deploy requirements for a release
	make clean && \
	mkdir -p release/$(VERSION) && \
	make build && \
	mv ./servicebroker release/$(VERSION)/aws-servicebroker-$(VERSION)-OSX && \
	make linux && \
	mv ./servicebroker-linux release/$(VERSION)/aws-servicebroker-$(VERSION)-linux && \
	make image && \
	docker push $(IMAGE):$(TAG) && \
	docker tag $(IMAGE):$(TAG) $(IMAGE):$(VERSION) && \
	docker push $(IMAGE):$(VERSION) && \
	make helm && \
	mv ./packaging/helm/aws-servicebroker-$(VERSION).tgz ./release/$(VERSION)/ && \
	make deploy-chart && \
	make cf && \
	mv ./packaging/cloudfoundry/product/aws-service-broker-$(VERSION).pivotal ./release/$(VERSION)/

templates: ## Package and upload templates
	mkdir -p release/$(VERSION)$(TEMPLATE_PREFIX)/ && \
	cd templates && \
	for i in $(TEMPLATES) ; do cp $$i/template.yaml ../release/$(VERSION)$(TEMPLATE_PREFIX)/$$i-main.yaml ; done && \
	cd .. && \
	aws s3 cp --recursive release/$(VERSION)$(TEMPLATE_PREFIX)/ s3://$(BUCKET_NAME)$(TEMPLATE_PREFIX)/ --acl $(ACL) $(PROFILE)

functions: ## Package and upload functions
	mkdir -p release/$(VERSION)$(FUNCTION_PREFIX)/ && \
	cp -a functions functions-staging && \
	cd functions-staging && \
	for i in $(FUNCTIONS) ; do cd $$i ; echo $$(pwd); cat version; if [ -e version ]; then export FUNCTION_VERSION=$$(cat version) ; else unset FUNCTION_VERSION ; fi; pip3 install -r requirements.txt --target . ; zip -r lambda_function * -x .* -x '*bin/*' ; mkdir -p ../../release/$(VERSION)$(FUNCTION_PREFIX)/$$i$$FUNCTION_VERSION ; cp lambda_function.zip ../../release/$(VERSION)$(FUNCTION_PREFIX)/$$i$$FUNCTION_VERSION ; cd .. ; done && \
	cd .. && \
	aws s3 cp --recursive release/$(VERSION)$(FUNCTION_PREFIX)/ s3://$(BUCKET_NAME)$(FUNCTION_PREFIX)/ --acl $(ACL) $(PROFILE) && \
	rm -rf functions-staging && \
	cp -a layers layers-staging && \
	cd layers-staging && \
	for i in $(LAYERS) ; do cd $$i/python ; pip3 install -r requirements.txt --target . ; cd .. ; zip -r lambda_layer * -x .* -x 'python/bin/*' -x python/botocore* ; if [ -e version ]; then export LAYER_VERSION=$$(cat version) ; else unset LAYER_VERSION ; fi; mkdir -p ../../release/$(VERSION)$(LAYER_PREFIX)/$$i$$LAYER_VERSION ; cp lambda_layer.zip ../../release/$(VERSION)$(LAYER_PREFIX)/$$i$$LAYER_VERSION ; cd .. ; done && \
	cd .. && \
	aws s3 cp --recursive release/$(VERSION)$(LAYER_PREFIX)/ s3://$(BUCKET_NAME)$(LAYER_PREFIX)/ --acl $(ACL) $(PROFILE) && \
	rm -rf layers-staging

help: ## Shows the help
	@echo 'Usage: make <OPTIONS> ... <TARGETS>'
	@echo ''
	@echo 'Available targets are:'
	@echo ''
	@grep -E '^[ a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
        awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'
	@echo ''

.PHONY: build test functional-test linux cf image helm deploy-chart release templates clean help functions
