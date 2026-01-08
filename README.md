# OpenShift AI 3.0 - Model as a Service (MaaS) Deployment Guide

This repository contains the configuration files and instructions to deploy LLM models using **OpenShift AI 3.0** with **LLM-D (Disaggregated Inference)** architecture.

Based on: [Red Hat OpenShift AI 3.0 Showroom](https://rhpds.github.io/redhat-openshift-ai-3-showroom/modules/00-00-intro.html)

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         External Traffic                                 │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                    Gateway API (openshift-ai-inference)                  │
│                    - HTTPS Termination (port 443)                        │
│                    - TLS Certificate: default-gateway-tls                │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                    Kuadrant (Red Hat Connectivity Link)                  │
│                    - AuthPolicy (Token Review / Anonymous)               │
│                    - RateLimitPolicy (Optional)                          │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                         HTTPRoute                                        │
│                    - Routes to InferencePool                             │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                    EPP Scheduler (Endpoint Picker)                       │
│                    - Queue Scorer                                        │
│                    - KV Cache Utilization Scorer                         │
│                    - Prefix Cache Scorer                                 │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                    ┌───────────────┴───────────────┐
                    ▼                               ▼
        ┌───────────────────┐           ┌───────────────────┐
        │   vLLM Pod 1      │           │   vLLM Pod 2      │
        │   (GPU Node 1)    │           │   (GPU Node 2)    │
        └───────────────────┘           └───────────────────┘
```

## Prerequisites

### Required Operators

Install the following operators from OperatorHub before deployment:

| Operator | Version | Namespace | Channel | Purpose |
|----------|---------|-----------|---------|---------|
| **Red Hat OpenShift AI** | 3.0.0 | `redhat-ods-operator` | `fast-3.x` | Core AI/ML platform |
| **NVIDIA GPU Operator** | 25.10.1 | `nvidia-gpu-operator` | `v25.10` | GPU device management |
| **Red Hat Connectivity Link** | 1.2.1 | `kuadrant-system` | `stable` | API gateway & auth (Kuadrant) |
| **Red Hat OpenShift Serverless** | 1.37.0 | `openshift-serverless` | `stable` | KNative for model serving |
| **Red Hat OpenShift Service Mesh** | 3.2.1 | `openshift-operators` | `stable` | Istio-based networking |

### Dependent Components (Auto-installed)

These are automatically installed by Red Hat Connectivity Link:

| Component | Version | Purpose |
|-----------|---------|---------|
| Authorino Operator | 1.2.4 | Authentication & authorization |
| Limitador Operator | 1.2.0 | Rate limiting |
| DNS Operator | 1.2.0 | DNS management |

### Cluster Requirements

- OpenShift 4.19+ cluster
- GPU nodes with NVIDIA GPUs (Tesla T4, A100, H100, etc.)
- Cluster admin access

## Directory Structure

```
openshift-ai-3-deployment/
├── README.md                         # This file (infrastructure deployment)
├── BLOG.md                           # Blog: LLM Deployment with LLM-D
├── BLOG-2-GENAI-PLAYGROUND-MCP.md    # Blog 2: GenAI Playground + MCP
├── ARCHITECTURE.md                   # Detailed architecture documentation
├── 00-prerequisites/
│   ├── operators.yaml                # Operator subscriptions
│   ├── datasciencecluster.yaml       # DataScienceCluster config
│   └── odh-dashboard-config.yaml     # Dashboard features (GenAI Studio)
├── 01-gateway-api/
│   ├── gateway-class.yaml            # GatewayClass definition
│   └── gateway.yaml                  # Gateway with HTTPS listener
├── 02-kuadrant/
│   ├── kuadrant.yaml                 # Kuadrant CR to enable auth
│   └── authorino-tls-annotation.sh   # Script to add TLS to Authorino
├── 03-hardware-profile/
│   └── gpu-profile.yaml              # Hardware profile for GPU resources
├── 04-llm-d-deployment/
│   └── llminferenceservice.yaml      # LLMInferenceService for Qwen model
└── 05-genai-playground/
    ├── README.md                     # GenAI Playground & MCP Setup Guide
    └── llamastackdistribution.yaml   # GenAI Playground configuration
```

## Documentation

| Document | Description |
|----------|-------------|
| [README.md](README.md) | Infrastructure deployment (this file) |
| [05-genai-playground/README.md](05-genai-playground/README.md) | **GenAI Playground & MCP Setup Guide** |
| [BLOG.md](BLOG.md) | Blog: LLM Deployment with LLM-D |
| [BLOG-2-GENAI-PLAYGROUND-MCP.md](BLOG-2-GENAI-PLAYGROUND-MCP.md) | Blog 2: GenAI Playground + MCP |
| [ARCHITECTURE.md](ARCHITECTURE.md) | Detailed architecture documentation |

## Deployment Steps

### Step 0: Install Required Operators

Reference: [Operator Installation](https://rhpds.github.io/redhat-openshift-ai-3-showroom/modules/02-01-deploy-operators.html)

```bash
# Install operators (wait for each to be ready)
oc apply -f 00-prerequisites/operators.yaml

# Verify all operators are installed
oc get csv -A | grep -E "rhods|gpu|rhcl|serverless|servicemesh"
```

Wait until all operators show `Succeeded` phase before proceeding.

### Step 1: Configure DataScienceCluster

Reference: [DataScienceCluster Deployment](https://rhpds.github.io/redhat-openshift-ai-3-showroom/modules/02-02-deploy-dsc.html)

```bash
oc apply -f 00-prerequisites/datasciencecluster.yaml
```

This enables:
- `kserve` - Model serving platform
- `dashboard` - OpenShift AI Dashboard
- `llamastackoperator` - GenAI Playground support

### Step 2: Configure ODH Dashboard

Reference: [ODH Dashboard Config](https://rhpds.github.io/redhat-openshift-ai-3-showroom/modules/03-01-odh-dashboard.html)

```bash
oc apply -f 00-prerequisites/odh-dashboard-config.yaml
```

This enables:
- `genAiStudio: true` - GenAI Playground in dashboard
- `modelAsService: true` - Model-as-a-Service features

### Step 3: Deploy Gateway API

Reference: [Deploying LLM-D](https://rhpds.github.io/redhat-openshift-ai-3-showroom/modules/04-00-deploy-llmd.html)

```bash
oc apply -f 01-gateway-api/gateway-class.yaml
oc apply -f 01-gateway-api/gateway.yaml
```

**Gateway Components:**
- **GatewayClass**: Defines the controller (`openshift.io/gateway-controller/v1`)
- **Gateway**: Creates LoadBalancer service with HTTPS (443) listener

### Step 4: Enable Kuadrant Authentication

```bash
oc apply -f 02-kuadrant/kuadrant.yaml
bash 02-kuadrant/authorino-tls-annotation.sh
```

**Kuadrant Components:**
- **Kuadrant CR**: Activates Authorino (authentication) and Limitador (rate limiting)
- **Authorino**: Handles TokenReview and SubjectAccessReview
- **TLS Annotation**: Required for Authorino service certificate

> **Note**: If the KServe operator does not detect RHCL, reboot the KServe operator pod.

### Step 5: Create Hardware Profile

Reference: [Create Hardware Profile](https://rhpds.github.io/redhat-openshift-ai-3-showroom/modules/03-02-hardware-profile.html)

```bash
oc apply -f 03-hardware-profile/gpu-profile.yaml
```

**Hardware Profile** specifies:
- CPU limits (1-8 cores)
- Memory limits (1Gi-16Gi)
- GPU allocation (nvidia.com/gpu)

### Step 6: Deploy LLM with LLM-D

Reference: [Deploy a Model](https://rhpds.github.io/redhat-openshift-ai-3-showroom/modules/03-03-deploy-model.html)

```bash
oc apply -f 04-llm-d-deployment/llminferenceservice.yaml
```

**LLMInferenceService** creates:
- **InferencePool**: Group of vLLM pods serving the model
- **EPP Scheduler**: Intelligent request routing
- **HTTPRoute**: External access via Gateway
- **AuthPolicy**: Authentication rules

### Step 7: Deploy GenAI Playground (Optional)

Reference: [GenAI Playground Integration](https://rhpds.github.io/redhat-openshift-ai-3-showroom/modules/03-04-genai-playground.html)

```bash
oc apply -f 05-genai-playground/llamastackdistribution.yaml
```

### Step 8: Deploy MCP Servers (Optional)

Reference: [Deploy MCP Servers](https://rhpds.github.io/redhat-openshift-ai-3-showroom/modules/03-05-deploy-mcp.html)

MCP servers can be added via ConfigMap:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: gen-ai-aa-mcp-servers
  namespace: redhat-ods-applications
data:
  GitHub-MCP-Server: |
    {
      "url": "https://api.githubcopilot.com/mcp",
      "description": "GitHub MCP Server"
    }
```

## Accessing the Model

### Get the Model URL

```bash
oc get llminferenceservice -n my-first-model -o jsonpath='{.items[0].status.url}'
```

### Test with curl

```bash
# Anonymous access (if enable-auth: false)
curl -sk https://<GATEWAY_URL>/my-first-model/qwen3-0-6b/v1/models

# Token-based access
TOKEN=$(oc whoami -t)
curl -sk https://<GATEWAY_URL>/my-first-model/qwen3-0-6b/v1/chat/completions \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen3-0.6B",
    "messages": [{"role": "user", "content": "Hello!"}]
  }'
```

## Key Configuration Notes

### For Tesla T4 GPUs

Tesla T4 has compute capability 7.5, which requires:

| Setting | Value | Reason |
|---------|-------|--------|
| `VLLM_USE_V1` | `"0"` | V1 engine requires compute capability 8.0+ |
| `--dtype` | `half` | bfloat16 not supported on T4 |
| `--enforce-eager` | enabled | Faster startup (disables CUDA graph) |

### Authentication Modes

| Annotation | AuthPolicy Type | Access |
|------------|-----------------|--------|
| `enable-auth: "false"` | Anonymous | Anyone can access |
| (not set) | Kubernetes TokenReview | Requires `oc whoami -t` token |

### Scaling

```yaml
spec:
  replicas: 2  # Number of vLLM pods (each needs 1 GPU)
```

## Verification Commands

```bash
# Check operator status
oc get csv -A | grep -E "rhods|gpu|rhcl"

# Check DataScienceCluster
oc get datasciencecluster

# Check Gateway
oc get gateway -n openshift-ingress

# Check Kuadrant
oc get kuadrant -n kuadrant-system

# Check LLMInferenceService
oc get llminferenceservice -n my-first-model

# Check pods
oc get pods -n my-first-model

# Check AuthPolicy
oc get authpolicy -A
```

## Troubleshooting

### TLS Issues

If you encounter TLS/500 errors when authentication is enabled:

1. **Check Authorino TLS annotation**:
   ```bash
   oc get svc authorino-authorino-authorization -n kuadrant-system -o yaml | grep serving-cert
   ```
   
2. **Add TLS annotation if missing**:
   ```bash
   oc annotate svc authorino-authorino-authorization -n kuadrant-system \
     service.beta.openshift.io/serving-cert-secret-name=authorino-tls
   ```

3. **Restart Authorino**:
   ```bash
   oc rollout restart deployment authorino -n kuadrant-system
   ```

### Model Not Starting

1. **Check pod logs**:
   ```bash
   oc logs -n my-first-model -l app=qwen3-0-6b --tail=100
   ```

2. **Common issues on Tesla T4**:
   - `bfloat16 not supported` → Add `--dtype=half`
   - `V1 engine failed` → Set `VLLM_USE_V1=0`
   - `OOMKilled` → Increase memory limit to 12Gi

### Gateway Not Routing

1. **Check HTTPRoute**:
   ```bash
   oc get httproute -n my-first-model -o yaml
   ```

2. **Check Gateway allows all namespaces**:
   ```bash
   oc get gateway openshift-ai-inference -n openshift-ingress -o yaml | grep -A 5 allowedRoutes
   ```

## References

- [OpenShift AI 3.0 Showroom](https://rhpds.github.io/redhat-openshift-ai-3-showroom/modules/00-00-intro.html)
- [OpenShift AI 3.0 Documentation](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.0)
- [MaaS Documentation](https://opendatahub-io.github.io/models-as-a-service/) - Model-as-a-Service Platform
- [MaaS GitHub Repository](https://github.com/opendatahub-io/models-as-a-service)
- [Kuadrant Documentation](https://kuadrant.io/)
- [vLLM Documentation](https://docs.vllm.ai/)
- [Gateway API Documentation](https://gateway-api.sigs.k8s.io/)
