# OpenShift AI 3.0 - Complete Architecture & Request Flow

## 1. High-Level Architecture

```
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                                    INTERNET                                              │
│                              (User sends HTTPS request)                                  │
└─────────────────────────────────────────────┬───────────────────────────────────────────┘
                                              │
                                              │ HTTPS (port 443)
                                              ▼
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                              AWS LOAD BALANCER (ELB)                                     │
│                     aed7822c...elb.amazonaws.com                                         │
│                                                                                          │
│  • Created automatically by Gateway                                                      │
│  • Routes traffic to OpenShift cluster                                                   │
└─────────────────────────────────────────────┬───────────────────────────────────────────┘
                                              │
                                              ▼
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                                                                                          │
│  ┌───────────────────────────────────────────────────────────────────────────────────┐  │
│  │                         NAMESPACE: openshift-ingress                               │  │
│  │  ┌─────────────────────────────────────────────────────────────────────────────┐  │  │
│  │  │                    GATEWAY: openshift-ai-inference                          │  │  │
│  │  │  ┌───────────────────────────────────────────────────────────────────────┐  │  │  │
│  │  │  │  Listeners:                                                           │  │  │  │
│  │  │  │  • HTTP  (port 80)  → allowedRoutes: All namespaces                   │  │  │  │
│  │  │  │  • HTTPS (port 443) → TLS termination                                 │  │  │  │
│  │  │  │                       Certificate: default-gateway-tls                │  │  │  │
│  │  │  └───────────────────────────────────────────────────────────────────────┘  │  │  │
│  │  └─────────────────────────────────────────────────────────────────────────────┘  │  │
│  │                                        │                                          │  │
│  │  ┌─────────────────────────────────────┼─────────────────────────────────────┐   │  │
│  │  │  ENVOY PROXY (Istio)                │                                     │   │  │
│  │  │  • Routes based on path             │                                     │   │  │
│  │  │  • Applies AuthPolicy               ▼                                     │   │  │
│  │  │  ┌─────────────────────────────────────────────────────────────────────┐  │   │  │
│  │  │  │  EnvoyFilter: kuadrant-auth-openshift-ai-inference                  │  │   │  │
│  │  │  │  • Intercepts requests                                              │  │   │  │
│  │  │  │  • Sends to Authorino for auth check                                │  │   │  │
│  │  │  └─────────────────────────────────────────────────────────────────────┘  │   │  │
│  │  └───────────────────────────────────────────────────────────────────────────┘   │  │
│  └───────────────────────────────────────────────────────────────────────────────────┘  │
│                                                                                          │
└─────────────────────────────────────────────┬───────────────────────────────────────────┘
                                              │
                                              │ gRPC call (port 50051)
                                              ▼
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                                                                                          │
│  ┌───────────────────────────────────────────────────────────────────────────────────┐  │
│  │                         NAMESPACE: kuadrant-system                                 │  │
│  │                                                                                    │  │
│  │  ┌─────────────────────────────────────────────────────────────────────────────┐  │  │
│  │  │                    AUTHORINO (Authentication)                               │  │  │
│  │  │                                                                             │  │  │
│  │  │  Checks AuthPolicy:                                                         │  │  │
│  │  │  ┌───────────────────────────────────────────────────────────────────────┐  │  │  │
│  │  │  │  IF enable-auth: "false"  →  anonymous: {}  →  ALLOW ALL             │  │  │  │
│  │  │  │  IF enable-auth: "true"   →  kubernetesTokenReview  →  CHECK TOKEN   │  │  │  │
│  │  │  └───────────────────────────────────────────────────────────────────────┘  │  │  │
│  │  └─────────────────────────────────────────────────────────────────────────────┘  │  │
│  │                                                                                    │  │
│  │  ┌─────────────────────────────────────────────────────────────────────────────┐  │  │
│  │  │                    LIMITADOR (Rate Limiting)                                │  │  │
│  │  │                                                                             │  │  │
│  │  │  • Enforces RateLimitPolicy (if configured)                                 │  │  │
│  │  │  • Counts requests per user/IP                                              │  │  │
│  │  └─────────────────────────────────────────────────────────────────────────────┘  │  │
│  └───────────────────────────────────────────────────────────────────────────────────┘  │
│                                                                                          │
└─────────────────────────────────────────────┬───────────────────────────────────────────┘
                                              │
                                              │ Auth passed ✓
                                              ▼
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                                                                                          │
│  ┌───────────────────────────────────────────────────────────────────────────────────┐  │
│  │                         NAMESPACE: my-first-model                                  │  │
│  │                                                                                    │  │
│  │  ┌─────────────────────────────────────────────────────────────────────────────┐  │  │
│  │  │  HTTPRoute: qwen3-0-6b-kserve-route                                         │  │  │
│  │  │                                                                             │  │  │
│  │  │  Path: /my-first-model/qwen3-0-6b/*                                         │  │  │
│  │  │  Backend: qwen3-0-6b-inference-pool (port 8000)                             │  │  │
│  │  └─────────────────────────────────────────────────────────────────────────────┘  │  │
│  │                                        │                                          │  │
│  │                                        ▼                                          │  │
│  │  ┌─────────────────────────────────────────────────────────────────────────────┐  │  │
│  │  │  InferencePool: qwen3-0-6b-inference-pool                                   │  │  │
│  │  │                                                                             │  │  │
│  │  │  • Groups all vLLM pods serving the model                                   │  │  │
│  │  │  • Provides stable endpoint for routing                                     │  │  │
│  │  └─────────────────────────────────────────────────────────────────────────────┘  │  │
│  │                                        │                                          │  │
│  │                                        ▼                                          │  │
│  │  ┌─────────────────────────────────────────────────────────────────────────────┐  │  │
│  │  │  EPP Scheduler: qwen3-0-6b-epp-scheduler                                    │  │  │
│  │  │  (Endpoint Picker Protocol)                                                 │  │  │
│  │  │                                                                             │  │  │
│  │  │  Scoring Plugins:                                                           │  │  │
│  │  │  ┌─────────────────────────────────────────────────────────────────────┐    │  │  │
│  │  │  │  queue-scorer (weight: 2)                                           │    │  │  │
│  │  │  │  → Pick pod with shortest request queue                             │    │  │  │
│  │  │  ├─────────────────────────────────────────────────────────────────────┤    │  │  │
│  │  │  │  kv-cache-utilization-scorer (weight: 2)                            │    │  │  │
│  │  │  │  → Pick pod with most free KV cache                                 │    │  │  │
│  │  │  ├─────────────────────────────────────────────────────────────────────┤    │  │  │
│  │  │  │  prefix-cache-scorer (weight: 3)                                    │    │  │  │
│  │  │  │  → Pick pod that already has similar prompt cached                  │    │  │  │
│  │  │  └─────────────────────────────────────────────────────────────────────┘    │  │  │
│  │  │                                                                             │  │  │
│  │  │  Decision: Route to Pod with highest score                                  │  │  │
│  │  └─────────────────────────────────────────────────────────────────────────────┘  │  │
│  │                                        │                                          │  │
│  │                    ┌───────────────────┴───────────────────┐                      │  │
│  │                    ▼                                       ▼                      │  │
│  │  ┌──────────────────────────────┐    ┌──────────────────────────────┐             │  │
│  │  │  vLLM Pod 1                  │    │  vLLM Pod 2                  │             │  │
│  │  │  qwen3-0-6b-predictor-xxx    │    │  qwen3-0-6b-predictor-yyy    │             │  │
│  │  │                              │    │                              │             │  │
│  │  │  ┌────────────────────────┐  │    │  ┌────────────────────────┐  │             │  │
│  │  │  │  Container: vllm       │  │    │  │  Container: vllm       │  │             │  │
│  │  │  │  Image: vllm-openai    │  │    │  │  Image: vllm-openai    │  │             │  │
│  │  │  │  Model: Qwen3-0.6B     │  │    │  │  Model: Qwen3-0.6B     │  │             │  │
│  │  │  │  GPU: 1x NVIDIA T4     │  │    │  │  GPU: 1x NVIDIA T4     │  │             │  │
│  │  │  └────────────────────────┘  │    │  └────────────────────────┘  │             │  │
│  │  │                              │    │                              │             │  │
│  │  │  Port: 8000 (inference)      │    │  Port: 8000 (inference)      │             │  │
│  │  └──────────────────────────────┘    └──────────────────────────────┘             │  │
│  │                                                                                    │  │
│  └───────────────────────────────────────────────────────────────────────────────────┘  │
│                                                                                          │
└─────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. All Kubernetes Objects Created

### When You Apply `LLMInferenceService`:

```
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                                                                                          │
│   YOU CREATE:                          SYSTEM AUTO-CREATES:                              │
│   ───────────                          ────────────────────                              │
│                                                                                          │
│   ┌─────────────────────┐              ┌─────────────────────────────────────────────┐  │
│   │ LLMInferenceService │──────────────► InferencePool                               │  │
│   │ (qwen3-0-6b)        │              │ (qwen3-0-6b-inference-pool)                 │  │
│   └─────────────────────┘              └─────────────────────────────────────────────┘  │
│                                                                                          │
│                                        ┌─────────────────────────────────────────────┐  │
│                                   ────► HTTPRoute                                    │  │
│                                        │ (qwen3-0-6b-kserve-route)                   │  │
│                                        └─────────────────────────────────────────────┘  │
│                                                                                          │
│                                        ┌─────────────────────────────────────────────┐  │
│                                   ────► AuthPolicy                                   │  │
│                                        │ (qwen3-0-6b-kserve-route-authn)             │  │
│                                        └─────────────────────────────────────────────┘  │
│                                                                                          │
│                                        ┌─────────────────────────────────────────────┐  │
│                                   ────► Deployment (Scheduler)                       │  │
│                                        │ (qwen3-0-6b-epp-scheduler)                  │  │
│                                        └─────────────────────────────────────────────┘  │
│                                                                                          │
│                                        ┌─────────────────────────────────────────────┐  │
│                                   ────► Deployment (vLLM Pods)                       │  │
│                                        │ (qwen3-0-6b-predictor)                      │  │
│                                        └─────────────────────────────────────────────┘  │
│                                                                                          │
│                                        ┌─────────────────────────────────────────────┐  │
│                                   ────► Service                                      │  │
│                                        │ (qwen3-0-6b-predictor)                      │  │
│                                        └─────────────────────────────────────────────┘  │
│                                                                                          │
└─────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## 3. Complete Object Map

```
CLUSTER SCOPE
├── GatewayClass: openshift-ai-inference
│   └── Controller: openshift.io/gateway-controller/v1
│
├── HardwareProfile: gpu-profile (in redhat-ods-applications)
│   └── Defines: CPU, Memory, GPU limits
│
└── ClusterPolicy: gpu-cluster-policy
    └── NVIDIA GPU Operator configuration

NAMESPACE: openshift-ingress
├── Gateway: openshift-ai-inference
│   ├── Listener: HTTP (80)
│   ├── Listener: HTTPS (443)
│   │   └── TLS Secret: default-gateway-tls
│   └── Creates: AWS LoadBalancer (ELB)
│
├── EnvoyFilter: kuadrant-auth-openshift-ai-inference
│   └── Routes auth checks to Authorino
│
└── AuthPolicy: openshift-ai-inference-authn
    └── Gateway-level authentication rules

NAMESPACE: kuadrant-system
├── Kuadrant: kuadrant
│   └── Enables Authorino + Limitador
│
├── Authorino: authorino
│   ├── Service: authorino-authorino-authorization
│   └── TLS Secret: authorino-tls
│
└── Limitador: limitador
    └── Service: limitador-limitador

NAMESPACE: my-first-model
├── LLMInferenceService: qwen3-0-6b
│   └── YOUR MAIN RESOURCE
│
├── InferencePool: qwen3-0-6b-inference-pool
│   └── Groups vLLM pods
│
├── HTTPRoute: qwen3-0-6b-kserve-route
│   ├── Path: /my-first-model/qwen3-0-6b/*
│   └── ParentRef: openshift-ai-inference Gateway
│
├── AuthPolicy: qwen3-0-6b-kserve-route-authn
│   └── anonymous: {} (public access)
│
├── Deployment: qwen3-0-6b-epp-scheduler
│   └── Pod: EPP Scheduler
│
├── Deployment: qwen3-0-6b-predictor
│   └── Pods: vLLM (x2 replicas)
│
└── Service: qwen3-0-6b-predictor
    └── ClusterIP for internal routing

NAMESPACE: redhat-ods-applications
├── DataScienceCluster: default-dsc
│   └── Enables: kserve, dashboard, llamastackoperator
│
└── OdhDashboardConfig: odh-dashboard-config
    └── Enables: genAiStudio, modelAsService
```

---

## 4. Request Flow (Step by Step)

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│ STEP 1: User Request                                                                    │
├────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                         │
│  curl https://aed7822c...elb.amazonaws.com/my-first-model/qwen3-0-6b/v1/chat/completions│
│                                                                                         │
│  Request: POST /my-first-model/qwen3-0-6b/v1/chat/completions                          │
│  Body: {"model": "Qwen/Qwen3-0.6B", "messages": [...]}                                 │
│                                                                                         │
└────────────────────────────────────────────────────────────────────────────────────────┘
                                              │
                                              ▼
┌────────────────────────────────────────────────────────────────────────────────────────┐
│ STEP 2: AWS Load Balancer                                                               │
├────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                         │
│  • Receives HTTPS request                                                               │
│  • Forwards to OpenShift cluster (Gateway pods)                                         │
│                                                                                         │
└────────────────────────────────────────────────────────────────────────────────────────┘
                                              │
                                              ▼
┌────────────────────────────────────────────────────────────────────────────────────────┐
│ STEP 3: Gateway (TLS Termination)                                                       │
├────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                         │
│  • Terminates TLS (decrypts HTTPS → HTTP)                                              │
│  • Uses certificate from: default-gateway-tls                                          │
│  • Passes request to Envoy proxy                                                        │
│                                                                                         │
└────────────────────────────────────────────────────────────────────────────────────────┘
                                              │
                                              ▼
┌────────────────────────────────────────────────────────────────────────────────────────┐
│ STEP 4: EnvoyFilter (Auth Intercept)                                                    │
├────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                         │
│  • EnvoyFilter intercepts request                                                       │
│  • Sends gRPC call to Authorino (port 50051)                                           │
│  • Question: "Is this request allowed?"                                                 │
│                                                                                         │
└────────────────────────────────────────────────────────────────────────────────────────┘
                                              │
                                              ▼
┌────────────────────────────────────────────────────────────────────────────────────────┐
│ STEP 5: Authorino (Authentication)                                                      │
├────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                         │
│  Checks AuthPolicy for this route:                                                      │
│                                                                                         │
│  AuthPolicy: qwen3-0-6b-kserve-route-authn                                             │
│  Rule: anonymous: {}                                                                    │
│                                                                                         │
│  Result: ✅ ALLOWED (no token required)                                                │
│                                                                                         │
└────────────────────────────────────────────────────────────────────────────────────────┘
                                              │
                                              ▼
┌────────────────────────────────────────────────────────────────────────────────────────┐
│ STEP 6: HTTPRoute (Path Matching)                                                       │
├────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                         │
│  HTTPRoute: qwen3-0-6b-kserve-route                                                    │
│                                                                                         │
│  Match: /my-first-model/qwen3-0-6b/*  ✅ MATCHES                                       │
│  Backend: qwen3-0-6b-inference-pool:8000                                               │
│                                                                                         │
└────────────────────────────────────────────────────────────────────────────────────────┘
                                              │
                                              ▼
┌────────────────────────────────────────────────────────────────────────────────────────┐
│ STEP 7: InferencePool                                                                   │
├────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                         │
│  InferencePool: qwen3-0-6b-inference-pool                                              │
│                                                                                         │
│  • Receives request                                                                     │
│  • Forwards to EPP Scheduler for routing decision                                       │
│                                                                                         │
└────────────────────────────────────────────────────────────────────────────────────────┘
                                              │
                                              ▼
┌────────────────────────────────────────────────────────────────────────────────────────┐
│ STEP 8: EPP Scheduler (Intelligent Routing)                                             │
├────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                         │
│  Scoring each pod:                                                                      │
│                                                                                         │
│  ┌─────────────────────────────────────────────────────────────────────────────────┐   │
│  │  Pod 1:                              Pod 2:                                     │   │
│  │  • Queue: 3 requests (score: 7)      • Queue: 1 request (score: 9)             │   │
│  │  • KV Cache: 60% used (score: 4)     • KV Cache: 40% used (score: 6)           │   │
│  │  • Prefix match: No (score: 0)       • Prefix match: Yes (score: 10)           │   │
│  │  ─────────────────────────           ─────────────────────────                 │   │
│  │  TOTAL: 11                           TOTAL: 25  ← WINNER                       │   │
│  └─────────────────────────────────────────────────────────────────────────────────┘   │
│                                                                                         │
│  Decision: Route to Pod 2                                                               │
│                                                                                         │
└────────────────────────────────────────────────────────────────────────────────────────┘
                                              │
                                              ▼
┌────────────────────────────────────────────────────────────────────────────────────────┐
│ STEP 9: vLLM Pod (Inference)                                                            │
├────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                         │
│  Pod: qwen3-0-6b-predictor-yyy                                                         │
│                                                                                         │
│  • Receives prompt: "What is Kubernetes?"                                               │
│  • Loads from KV cache (if prefix matched)                                              │
│  • Runs inference on GPU                                                                │
│  • Generates response tokens                                                            │
│                                                                                         │
└────────────────────────────────────────────────────────────────────────────────────────┘
                                              │
                                              ▼
┌────────────────────────────────────────────────────────────────────────────────────────┐
│ STEP 10: Response                                                                       │
├────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                         │
│  Response flows back:                                                                   │
│  vLLM Pod → InferencePool → HTTPRoute → Gateway → LoadBalancer → User                  │
│                                                                                         │
│  {                                                                                      │
│    "choices": [{                                                                        │
│      "message": {                                                                       │
│        "content": "Kubernetes is an open-source container orchestration platform..."   │
│      }                                                                                  │
│    }]                                                                                   │
│  }                                                                                      │
│                                                                                         │
└────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## 5. Operators & Their Responsibilities

```
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                              OPERATORS INSTALLED                                         │
├─────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                          │
│  ┌─────────────────────────────────────────────────────────────────────────────────┐    │
│  │  RED HAT OPENSHIFT AI OPERATOR (rhods-operator)                                 │    │
│  │                                                                                 │    │
│  │  Creates & Manages:                                                             │    │
│  │  • DataScienceCluster          → Configures AI platform components              │    │
│  │  • KServe                      → Model serving runtime                          │    │
│  │  • ODH Model Controller        → Creates HTTPRoutes, AuthPolicies              │    │
│  │  • LlamaStack Operator         → GenAI Playground                              │    │
│  │  • Dashboard                   → Web UI                                         │    │
│  └─────────────────────────────────────────────────────────────────────────────────┘    │
│                                                                                          │
│  ┌─────────────────────────────────────────────────────────────────────────────────┐    │
│  │  NVIDIA GPU OPERATOR                                                            │    │
│  │                                                                                 │    │
│  │  Creates & Manages:                                                             │    │
│  │  • GPU Device Plugin           → Makes GPUs visible to K8s                      │    │
│  │  • NVIDIA Drivers              → Installs on GPU nodes                          │    │
│  │  • CUDA Toolkit                → GPU computing libraries                        │    │
│  │  • DCGM Exporter               → GPU metrics                                    │    │
│  └─────────────────────────────────────────────────────────────────────────────────┘    │
│                                                                                          │
│  ┌─────────────────────────────────────────────────────────────────────────────────┐    │
│  │  RED HAT CONNECTIVITY LINK (Kuadrant Operator)                                  │    │
│  │                                                                                 │    │
│  │  Creates & Manages:                                                             │    │
│  │  • Authorino Operator          → Authentication engine                          │    │
│  │  • Limitador Operator          → Rate limiting engine                           │    │
│  │  • DNS Operator                → DNS management                                 │    │
│  │  • Kuadrant CR                 → Activates the system                          │    │
│  │  • AuthPolicy                  → Per-route authentication rules                 │    │
│  │  • RateLimitPolicy             → Per-route rate limits                          │    │
│  │  • EnvoyFilter                 → Integrates with Gateway                        │    │
│  └─────────────────────────────────────────────────────────────────────────────────┘    │
│                                                                                          │
│  ┌─────────────────────────────────────────────────────────────────────────────────┐    │
│  │  OPENSHIFT GATEWAY CONTROLLER (Built-in)                                        │    │
│  │                                                                                 │    │
│  │  Creates & Manages:                                                             │    │
│  │  • Gateway resources           → Ingress points                                 │    │
│  │  • LoadBalancer services       → AWS ELB                                        │    │
│  │  • TLS certificates            → default-gateway-tls                            │    │
│  │  • Envoy proxy                 → Request routing                                │    │
│  └─────────────────────────────────────────────────────────────────────────────────┘    │
│                                                                                          │
└─────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## 6. Simple Summary

```
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                                                                                          │
│   User Request                                                                           │
│        │                                                                                 │
│        ▼                                                                                 │
│   ┌─────────┐    ┌───────────┐    ┌───────────┐    ┌───────────┐    ┌─────────┐        │
│   │   ELB   │───►│  Gateway  │───►│ Authorino │───►│HTTPRoute  │───►│   EPP   │        │
│   │         │    │  (TLS)    │    │  (Auth)   │    │           │    │Scheduler│        │
│   └─────────┘    └───────────┘    └───────────┘    └───────────┘    └────┬────┘        │
│                                                                          │              │
│                                                           ┌──────────────┴──────────┐   │
│                                                           ▼                         ▼   │
│                                                      ┌─────────┐              ┌─────────┐│
│                                                      │vLLM Pod1│              │vLLM Pod2││
│                                                      │  (GPU)  │              │  (GPU)  ││
│                                                      └─────────┘              └─────────┘│
│                                                                                          │
│   OBJECTS: Gateway → EnvoyFilter → Authorino → HTTPRoute → InferencePool → Pods        │
│                                                                                          │
└─────────────────────────────────────────────────────────────────────────────────────────┘
```

---

*This architecture diagram shows the complete request flow through OpenShift AI 3.0 with LLM-D.*

