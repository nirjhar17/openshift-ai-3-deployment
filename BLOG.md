# From Container to Production: Deploying LLMs on OpenShift AI 3.0 with Intelligent Load Balancing

*A complete guide to deploying Large Language Models using OpenShift AI 3.0's new disaggregated inference architecture*

---

## Introduction

**Red Hat recently released OpenShift AI 3.0**, introducing a new way to deploy and serve Large Language Models at scale. In earlier versions, deploying a model meant creating an `InferenceService`, exposing it via OpenShift Routes, and handling authentication separately. It worked, but scaling across multiple GPUs required manual load balancing, and securing endpoints needed extra configuration.

OpenShift AI 3.0 changes this with **llm-d** — a disaggregated inference architecture that intelligently distributes requests across multiple GPU pods. Instead of traditional Routes, we now use the **Kubernetes Gateway API** for external access, which provides built-in TLS termination and seamless integration with **Red Hat Connectivity Link** (Kuadrant) for authentication and rate limiting. The new `LLMInferenceService` resource handles everything — it automatically creates an **EPP Scheduler** that routes requests to the best available GPU based on queue length, KV cache utilization, and prefix matching.

In this blog, I'll walk you through deploying an LLM on OpenShift AI 3.0 from scratch — setting up the Gateway for secure HTTPS access, enabling authentication, and handling real-world GPU compatibility issues with Tesla T4. By the end, you'll have a production-ready model endpoint with automatic TLS, intelligent load balancing, and enterprise-grade security.

**What we'll cover:**
- Setting up the required operators
- Configuring Gateway API for external access
- Enabling authentication with Kuadrant
- Handling TLS certificates
- Overcoming GPU compatibility challenges (Tesla T4)

**GitHub Repository:** All configuration files are available at [github.com/nirjhar17/openshift-ai-3-deployment](https://github.com/nirjhar17/openshift-ai-3-deployment)

---

## Architecture Overview

Before diving into the deployment, let's understand what we're building:

```
                            ┌─────────────────────────────────────┐
                            │         External Traffic            │
                            │   (HTTPS requests from users)       │
                            └──────────────────┬──────────────────┘
                                               │
                                               ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│                    Gateway API (openshift-ai-inference)                       │
│  ┌────────────────────────────────────────────────────────────────────────┐  │
│  │  • Receives external traffic on port 443 (HTTPS)                       │  │
│  │  • TLS termination using OpenShift-managed certificate                 │  │
│  │  • Routes requests to appropriate services                             │  │
│  └────────────────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────────────────┘
                                               │
                                               ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│                    Kuadrant (Red Hat Connectivity Link)                       │
│  ┌────────────────────────────────────────────────────────────────────────┐  │
│  │  • Authorino: Handles authentication (token validation)                │  │
│  │  • Limitador: Handles rate limiting (requests per minute)              │  │
│  │  • AuthPolicy: Defines who can access the model                        │  │
│  └────────────────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────────────────┘
                                               │
                                               ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│                    EPP Scheduler (Endpoint Picker Protocol)                   │
│  ┌────────────────────────────────────────────────────────────────────────┐  │
│  │  • Intelligent request routing across multiple GPU pods                │  │
│  │  • Queue Scorer: Routes to pod with shortest queue                     │  │
│  │  • KV Cache Scorer: Routes based on cache utilization                  │  │
│  │  • Prefix Cache Scorer: Routes similar prompts to same pod             │  │
│  └────────────────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────────────────┘
                                               │
                            ┌──────────────────┴──────────────────┐
                            ▼                                     ▼
                  ┌─────────────────┐                   ┌─────────────────┐
                  │   vLLM Pod 1    │                   │   vLLM Pod 2    │
                  │   (GPU Node)    │                   │   (GPU Node)    │
                  │                 │                   │                 │
                  │  Qwen3-0.6B     │                   │  Qwen3-0.6B     │
                  └─────────────────┘                   └─────────────────┘
```

### What is LLM-D?

Traditional LLM serving runs the entire inference (prefill + decode) on a single GPU. LLM-D allows:

1. **Multiple Replicas**: Run multiple vLLM pods, each with its own GPU
2. **Intelligent Routing**: EPP Scheduler decides which pod handles each request
3. **Better Utilization**: Requests are distributed based on current load and cache state

---

## Prerequisites

### Cluster Requirements

- OpenShift 4.19+ cluster
- GPU nodes with NVIDIA GPUs
- Cluster admin access

### Required Operators

Install these operators from **OperatorHub** in the OpenShift Web Console:

| Operator | Channel | Purpose |
|----------|---------|---------|
| **Red Hat OpenShift AI** | `fast-3.x` | Core AI/ML platform with KServe |
| **NVIDIA GPU Operator** | `v25.10` | GPU device plugin & drivers |
| **Red Hat Connectivity Link** | `stable` | API gateway, auth & rate limiting |

#### Installation Steps (OpenShift Console)

1. Navigate to **Operators → OperatorHub**
2. Search for each operator by name
3. Click **Install** and select the appropriate channel
4. Wait for the operator to show **Succeeded** status

#### Verify Installation

```bash
# Check all operators are installed and ready
oc get csv -A | grep -E "rhods|gpu|rhcl"
```

---

## Step 1: Configure DataScienceCluster

The DataScienceCluster resource configures which OpenShift AI components are enabled.

```yaml
# datasciencecluster.yaml
apiVersion: datasciencecluster.opendatahub.io/v1
kind: DataScienceCluster
metadata:
  name: default-dsc
spec:
  components:
    kserve:
      managementState: Managed
    dashboard:
      managementState: Managed
    llamastackoperator:
      managementState: Managed  # Enables GenAI Playground
```

```bash
oc apply -f datasciencecluster.yaml
```

---

## Step 2: Set Up Gateway API

Gateway API is the modern replacement for Ingress, providing more powerful routing capabilities.

### Create GatewayClass

```yaml
# gateway-class.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: openshift-ai-inference
spec:
  controllerName: openshift.io/gateway-controller/v1
```

### Create Gateway with TLS

```yaml
# gateway.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: openshift-ai-inference
  namespace: openshift-ingress
spec:
  gatewayClassName: openshift-ai-inference
  listeners:
    # HTTP listener (port 80)
    - name: http
      port: 80
      protocol: HTTP
      allowedRoutes:
        namespaces:
          from: All
    
    # HTTPS listener (port 443)
    - name: https
      port: 443
      protocol: HTTPS
      allowedRoutes:
        namespaces:
          from: All
      tls:
        mode: Terminate
        certificateRefs:
          - kind: Secret
            name: default-gateway-tls
```

```bash
oc apply -f gateway-class.yaml
oc apply -f gateway.yaml

# Verify Gateway is programmed
oc get gateway -n openshift-ingress
```

### Understanding TLS Configuration

**The TLS certificate (`default-gateway-tls`)** is automatically created by OpenShift when you create a Gateway. Here's how it works:

1. **OpenShift's Gateway Controller** detects your Gateway resource
2. **It creates a LoadBalancer service** (AWS ELB in our case)
3. **It generates a TLS certificate** and stores it in a Secret called `default-gateway-tls`
4. **The certificate is used** for HTTPS termination at the Gateway

You can verify the certificate exists:
```bash
oc get secret default-gateway-tls -n openshift-ingress
```

---

## Step 3: Enable Kuadrant Authentication

Kuadrant provides authentication and rate limiting for your APIs.

### Create Kuadrant Resource

```yaml
# kuadrant.yaml
apiVersion: kuadrant.io/v1beta1
kind: Kuadrant
metadata:
  name: kuadrant
  namespace: kuadrant-system
spec: {}
```

```bash
oc apply -f kuadrant.yaml

# Verify Kuadrant components are running
oc get pods -n kuadrant-system
```

This creates:
- **Authorino**: Handles authentication (validates tokens)
- **Limitador**: Handles rate limiting

### Enable Authorino TLS (Important!)

For Kuadrant to work properly with the Gateway, Authorino needs a TLS certificate. OpenShift can auto-generate this:

```bash
oc annotate svc authorino-authorino-authorization -n kuadrant-system \
  service.beta.openshift.io/serving-cert-secret-name=authorino-tls
```

This annotation tells OpenShift's service-ca operator to:
1. Generate a TLS certificate for the Authorino service
2. Store it in a Secret called `authorino-tls`
3. The certificate is signed by OpenShift's internal CA

---

## Step 4: Create Hardware Profile

Hardware Profiles define resource allocations for model deployments.

```yaml
# gpu-profile.yaml
apiVersion: infrastructure.opendatahub.io/v1
kind: HardwareProfile
metadata:
  name: gpu-profile
  namespace: redhat-ods-applications
spec:
  identifiers:
    - identifier: cpu
      displayName: CPU
      defaultCount: '1'
      minCount: 1
      maxCount: '8'
      resourceType: CPU
    - identifier: memory
      displayName: Memory
      defaultCount: 12Gi
      minCount: 1Gi
      maxCount: 16Gi
      resourceType: Memory
    - identifier: nvidia.com/gpu
      displayName: GPU
      defaultCount: 1
      minCount: 1
      maxCount: 4
      resourceType: Accelerator
```

```bash
oc apply -f gpu-profile.yaml
```

---

## Step 5: Deploy the LLM with LLM-D

Now for the main event - deploying the model using `LLMInferenceService`.

```yaml
# llminferenceservice.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: my-first-model
---
apiVersion: serving.kserve.io/v1alpha1
kind: LLMInferenceService
metadata:
  name: qwen3-0-6b
  namespace: my-first-model
  annotations:
    opendatahub.io/hardware-profile-name: gpu-profile
    opendatahub.io/hardware-profile-namespace: redhat-ods-applications
    # Set to "false" for anonymous access, remove for token-based auth
    security.opendatahub.io/enable-auth: "false"
spec:
  replicas: 2  # Two vLLM pods for load distribution
  
  model:
    uri: hf://Qwen/Qwen3-0.6B
    name: Qwen/Qwen3-0.6B
  
  # EPP Scheduler configuration
  router:
    scheduler:
      template:
        containers:
          - name: main
            env:
              - name: TOKENIZER_CACHE_DIR
                value: /tmp/tokenizer-cache
              - name: HF_HOME
                value: /tmp/tokenizer-cache
            args:
              - --pool-group
              - inference.networking.x-k8s.io
              - --pool-name
              - '{{ ChildName .ObjectMeta.Name `-inference-pool` }}'
              - --pool-namespace
              - '{{ .ObjectMeta.Namespace }}'
              - --config-text
              - |
                apiVersion: inference.networking.x-k8s.io/v1alpha1
                kind: EndpointPickerConfig
                plugins:
                - type: queue-scorer
                - type: kv-cache-utilization-scorer
                - type: prefix-cache-scorer
                schedulingProfiles:
                - name: default
                  plugins:
                  - pluginRef: queue-scorer
                    weight: 2
                  - pluginRef: kv-cache-utilization-scorer
                    weight: 2
                  - pluginRef: prefix-cache-scorer
                    weight: 3
            volumeMounts:
              - name: tokenizer-cache
                mountPath: /tmp/tokenizer-cache
        volumes:
          - name: tokenizer-cache
            emptyDir: {}
    route: {}
    gateway: {}
  
  # vLLM Pod configuration
  template:
    tolerations:
      - key: "nvidia.com/gpu"
        operator: "Exists"
        effect: "NoSchedule"
    containers:
      - name: main
        image: vllm/vllm-openai:v0.8.4
        env:
          - name: VLLM_USE_V1
            value: "0"
          - name: HF_HOME
            value: "/tmp/hf_home"
          - name: VLLM_ADDITIONAL_ARGS
            value: "--dtype=half --max-model-len=4096 --gpu-memory-utilization=0.85 --enforce-eager"
        resources:
          limits:
            cpu: '2'
            memory: 12Gi
            nvidia.com/gpu: "1"
          requests:
            cpu: '1'
            memory: 8Gi
            nvidia.com/gpu: "1"
```

```bash
oc apply -f llminferenceservice.yaml

# Watch the deployment
oc get pods -n my-first-model -w
```

---

## GPU Compatibility: Tesla T4 Challenges

During our deployment, we encountered several issues specific to Tesla T4 GPUs (compute capability 7.5). Here's what we learned:

### Challenge 1: vLLM V1 Engine Incompatibility

**Error:**
```
RuntimeError: Cannot use FA version 2 is not supported due to FA2 is only supported 
on devices with compute capability >= 8
```

**Cause:** vLLM's V1 engine uses FlashAttention 2, which requires GPU compute capability 8.0+ (A100, H100). Tesla T4 has compute capability 7.5.

**Solution:** Disable V1 engine:
```yaml
env:
  - name: VLLM_USE_V1
    value: "0"
```

### Challenge 2: bfloat16 Not Supported

**Error:**
```
ValueError: Bfloat16 is only supported on GPUs with compute capability of at least 8.0. 
Your Tesla T4 GPU has compute capability 7.5.
```

**Solution:** Use float16 instead:
```yaml
env:
  - name: VLLM_ADDITIONAL_ARGS
    value: "--dtype=half"
```

### Challenge 3: Slow Startup with CUDA Graphs

**Problem:** Model took 5+ minutes to start due to CUDA graph capture.

**Solution:** Disable CUDA graphs for faster startup:
```yaml
env:
  - name: VLLM_ADDITIONAL_ARGS
    value: "--enforce-eager"
```

### Challenge 4: Red Hat vLLM Image Incompatibility

**Problem:** The default Red Hat vLLM image (`registry.redhat.io/rhoai/odh-vllm-cuda-rhel9`) is optimized for newer GPUs and enforces V1 engine.

**Solution:** Use upstream vLLM image:
```yaml
containers:
  - name: main
    image: vllm/vllm-openai:v0.8.4  # Upstream image
```

### Challenge 5: Llama Model Gated Access

**Problem:** When trying to deploy Meta's Llama-3.2-3B-Instruct, we hit:
```
huggingface_hub.errors.GatedRepoError: 401 Client Error. 
Access to model meta-llama/Llama-3.2-3B-Instruct is restricted.
```

**Cause:** Llama models on HuggingFace require accepting a license agreement and providing an access token.

**Solution:** Use a public model like `Qwen/Qwen3-0.6B` or configure HuggingFace authentication.

### Summary: Tesla T4 Configuration

```yaml
containers:
  - name: main
    image: vllm/vllm-openai:v0.8.4  # Use upstream image
    env:
      - name: VLLM_USE_V1
        value: "0"                   # Disable V1 engine
      - name: VLLM_ADDITIONAL_ARGS
        value: "--dtype=half --enforce-eager"  # float16 + no CUDA graphs
```

---

## Step 6: Verify Deployment

### Check LLMInferenceService Status

```bash
oc get llminferenceservice -n my-first-model

# Expected output:
# NAME         READY   URL
# qwen3-0-6b   True    http://...elb.amazonaws.com/my-first-model/qwen3-0-6b
```

### Check Pods

```bash
oc get pods -n my-first-model

# Expected: 2 vLLM pods + 1 scheduler pod
# NAME                                    READY   STATUS    
# qwen3-0-6b-predictor-xxxxx              1/1     Running   
# qwen3-0-6b-predictor-yyyyy              1/1     Running   
# qwen3-0-6b-epp-scheduler-zzzzz          1/1     Running   
```

### Get the Model URL

```bash
oc get llminferenceservice qwen3-0-6b -n my-first-model -o jsonpath='{.status.url}'
```

### Test the Endpoint

```bash
# List models
curl -sk https://<GATEWAY_URL>/my-first-model/qwen3-0-6b/v1/models

# Chat completion
curl -sk https://<GATEWAY_URL>/my-first-model/qwen3-0-6b/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen3-0.6B",
    "messages": [{"role": "user", "content": "What is Kubernetes?"}],
    "max_tokens": 100
  }'
```

---

## Understanding Authentication

### Anonymous Access (Current Setup)

With `security.opendatahub.io/enable-auth: "false"`, anyone can access the model:

```bash
# Works without any token
curl https://<GATEWAY_URL>/my-first-model/qwen3-0-6b/v1/models
```

### Token-Based Access

Remove the `enable-auth` annotation to require Kubernetes tokens:

```yaml
metadata:
  annotations:
    # Remove this line to enable token-based auth
    # security.opendatahub.io/enable-auth: "false"
```

Then users need to provide their OpenShift token:

```bash
# Get your token and make request
curl -H "Authorization: Bearer $(oc whoami -t)" \
  https://<GATEWAY_URL>/my-first-model/qwen3-0-6b/v1/models
```

### How AuthPolicy Works

The ODH Model Controller automatically creates AuthPolicies based on your settings:

**Anonymous mode** (`enable-auth: "false"`):
```yaml
apiVersion: kuadrant.io/v1
kind: AuthPolicy
spec:
  rules:
    authentication:
      public:
        anonymous: {}  # Anyone can access
```

**Token mode** (default):
```yaml
apiVersion: kuadrant.io/v1
kind: AuthPolicy
spec:
  rules:
    authentication:
      kubernetes-user:
        kubernetesTokenReview:
          audiences: [...]  # Validates K8s tokens
    authorization:
      inference-access:
        kubernetesSubjectAccessReview: ...  # Checks RBAC permissions
```

---

## TLS Deep Dive

### The Complete TLS Flow

```
┌─────────────────────────────────────────────────────────────────────┐
│                        TLS Connection Flow                           │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  Client                                                             │
│    │                                                                │
│    │ HTTPS (TLS 1.2/1.3)                                           │
│    │ Certificate: default-gateway-tls                               │
│    ▼                                                                │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │  Gateway (openshift-ai-inference)                            │   │
│  │  - TLS Termination happens here                              │   │
│  │  - Decrypts HTTPS → HTTP                                     │   │
│  └─────────────────────────────────────────────────────────────┘   │
│    │                                                                │
│    │ HTTP (unencrypted, internal cluster network)                  │
│    ▼                                                                │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │  Authorino (authentication check)                            │   │
│  └─────────────────────────────────────────────────────────────┘   │
│    │                                                                │
│    │ HTTP                                                          │
│    ▼                                                                │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │  Model Pod (vLLM)                                            │   │
│  └─────────────────────────────────────────────────────────────┘   │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

### Certificate Sources

| Certificate | Location | Created By | Purpose |
|-------------|----------|------------|---------|
| `default-gateway-tls` | `openshift-ingress` namespace | OpenShift Gateway Controller | HTTPS for external traffic |
| `authorino-tls` | `kuadrant-system` namespace | OpenShift Service CA | Internal TLS for Authorino |

### Checking Certificates

```bash
# Gateway TLS certificate
oc get secret default-gateway-tls -n openshift-ingress

# Authorino TLS certificate
oc get secret authorino-tls -n kuadrant-system

# View certificate details
oc get secret default-gateway-tls -n openshift-ingress -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -text -noout
```

---

## Conclusion

We successfully deployed an LLM on OpenShift AI 3.0 using the new LLM-D architecture. Key takeaways:

1. **LLM-D enables intelligent load balancing** across multiple GPU pods
2. **Gateway API with TLS** provides secure external access
3. **Kuadrant handles authentication** with flexible policies
4. **GPU compatibility matters** - Tesla T4 requires specific vLLM settings
5. **OpenShift automates TLS** certificate management

### What's Next?

In the next blog, we'll explore:
- Rate limiting with `RateLimitPolicy`
- Token-based rate limiting for AI workloads
- Usage tracking and billing with MaaS

---

## Resources

- **GitHub Repository**: [github.com/nirjhar17/openshift-ai-3-deployment](https://github.com/nirjhar17/openshift-ai-3-deployment)
- **OpenShift AI 3.0 Documentation**: [docs.redhat.com](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.0)
- **MaaS Project**: [github.com/opendatahub-io/models-as-a-service](https://github.com/opendatahub-io/models-as-a-service)
- **Kuadrant Documentation**: [kuadrant.io](https://kuadrant.io/)
- **vLLM Documentation**: [docs.vllm.ai](https://docs.vllm.ai/)

---

*Author: Nirjhar Jajodia*  
*Date: December 2025*

