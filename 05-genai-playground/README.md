# GenAI Playground & MCP Setup Guide

This guide covers deploying the **GenAI Playground** (LlamaStack-based chat interface) and configuring **MCP (Model Context Protocol)** servers for external tool integration.

**Prerequisites:** Complete the main deployment first (see [../README.md](../README.md))

---

## What is GenAI Playground?

GenAI Playground is a **web-based chat interface** integrated into the OpenShift AI Dashboard. It's powered by **LlamaStack**, providing:

- Chat UI for interacting with deployed models
- Agent capabilities (multi-turn conversations)
- MCP tool integration (web search, code analysis, etc.)

```
┌─────────────────────────────────────────────────────────────────────┐
│                     Architecture                                     │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│   User Browser ──▶ OpenShift AI Dashboard ──▶ LlamaStack Server    │
│                        (Gen AI Studio)              │               │
│                                                     ▼               │
│                                              ┌─────────────┐        │
│                                              │  vLLM Pods  │        │
│                                              │  (Model)    │        │
│                                              └─────────────┘        │
│                                                     │               │
│                                                     ▼               │
│                                              ┌─────────────┐        │
│                                              │ MCP Servers │        │
│                                              │  (Tools)    │        │
│                                              └─────────────┘        │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Step 1: Enable LlamaStack Operator

Ensure the LlamaStack Operator is enabled in DataScienceCluster:

```bash
# Check current status
oc get datasciencecluster default-dsc -o jsonpath='{.spec.components.llamastackoperator.managementState}'

# Enable if not already
oc patch datasciencecluster default-dsc --type='merge' -p '{
  "spec": {
    "components": {
      "llamastackoperator": {
        "managementState": "Managed"
      }
    }
  }
}'
```

---

## Step 2: Enable GenAI Studio in Dashboard

```bash
oc patch odhdashboardconfig odh-dashboard-config -n redhat-ods-applications --type='merge' -p '{
  "spec": {
    "dashboardConfig": {
      "genAiStudio": true,
      "modelAsService": true
    }
  }
}'
```

After this, **refresh the OpenShift AI Dashboard** — you should see "Gen AI Studio" in the left menu.

---

## Step 3: Find Your Model's Service URL

Before deploying LlamaStackDistribution, find the correct service URL for your model:

```bash
# List services in your model namespace
oc get svc -n my-first-model

# Look for the workload service (not router)
# Example output:
# NAME                                TYPE        PORT(S)
# qwen3-0-6b-kserve-workload-svc      ClusterIP   8000/TCP  <-- Use this
# qwen3-0-6b-router-svc               ClusterIP   8080/TCP
```

The service URL format is:
```
http://<service-name>.<namespace>.svc.cluster.local:<port>/v1
```

Example:
```
http://qwen3-0-6b-kserve-workload-svc.my-first-model.svc.cluster.local:8000/v1
```

---

## Step 4: Deploy LlamaStackDistribution

Edit `llamastackdistribution.yaml` with your model's service URL:

```yaml
apiVersion: llamastack.opendatahub.io/v1
kind: LlamaStackDistribution
metadata:
  name: lsd-genai-playground
  namespace: my-first-model
  labels:
    opendatahub.io/dashboard: "true"  # Makes it visible in Dashboard
spec:
  image: quay.io/opendatahub/llama-stack-server:latest
  
  config:
    apis:
      - agents       # Multi-turn conversation
      - datasetio    # Dataset management
      - files        # File handling
      - inference    # LLM inference
      - safety       # Content moderation
      - scoring      # Response scoring
      - tool_runtime # MCP tool support
      - vector_io    # RAG support
    
    providers:
      inference:
        - provider_id: vllm-inference-1
          provider_type: remote::vllm
          config:
            # UPDATE THIS URL to match your model's service
            url: http://qwen3-0-6b-kserve-workload-svc.my-first-model.svc.cluster.local:8000/v1
            api_token: ${env.VLLM_API_TOKEN_1:=fake}
            max_tokens: 4096
            tls_verify: false
    
    models:
      - provider_id: vllm-inference-1
        model_id: qwen3-0-6b
        model_type: llm
        metadata:
          description: "Qwen3 0.6B model deployed with LLM-D"
          display_name: qwen3-0-6b
    
    server:
      port: 8321
```

Deploy:

```bash
oc apply -f llamastackdistribution.yaml

# Watch the pod start
oc get pods -n my-first-model -w

# Check status
oc get llamastackdistribution -n my-first-model
```

---

## Step 5: Access GenAI Playground

1. Open **OpenShift AI Dashboard**
2. Click **"Gen AI Studio"** in the left menu
3. Your LlamaStackDistribution should appear
4. Click on it to open the chat interface

---

## Adding MCP Servers

MCP (Model Context Protocol) allows your LLM to use external tools like web search, code analysis, etc.

### ConfigMap Format

MCP servers are registered via a ConfigMap in `redhat-ods-applications`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: gen-ai-aa-mcp-servers
  namespace: redhat-ods-applications
data:
  # Each key is a tool name, value is JSON config
  Tool-Name: |
    {
      "url": "https://mcp-server-url/endpoint",
      "description": "What this tool does"
    }
```

### Example: Multiple MCP Servers

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: gen-ai-aa-mcp-servers
  namespace: redhat-ods-applications
data:
  Web-Fetch: |
    {
      "url": "https://your-fetch-server/sse",
      "description": "Fetch web content and convert HTML to markdown"
    }
  Code-Analysis: |
    {
      "url": "https://your-code-server/sse",
      "description": "Analyze code for security issues"
    }
  GitHub: |
    {
      "url": "https://api.githubcopilot.com/mcp",
      "description": "GitHub Copilot integration (requires auth token)"
    }
```

```bash
oc apply -f mcp-servers-configmap.yaml
```

After applying, **refresh the GenAI Playground** — tools should appear with toggle switches.

---

## Self-Hosting MCP Servers

For production, deploy your own MCP servers on OpenShift:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-mcp-server
  namespace: my-first-model
spec:
  replicas: 1
  selector:
    matchLabels:
      app: my-mcp-server
  template:
    metadata:
      labels:
        app: my-mcp-server
    spec:
      containers:
        - name: mcp-server
          image: your-registry/your-mcp-server:latest
          ports:
            - containerPort: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: my-mcp-server
  namespace: my-first-model
spec:
  selector:
    app: my-mcp-server
  ports:
    - port: 8080
      targetPort: 8080
```

Reference in ConfigMap:
```yaml
data:
  My-Tool: |
    {
      "url": "http://my-mcp-server.my-first-model.svc.cluster.local:8080/sse",
      "description": "My custom MCP tool"
    }
```

---

## Verification Commands

```bash
# Check LlamaStackDistribution status
oc get llamastackdistribution -n my-first-model

# Check LlamaStack pod logs
oc logs -n my-first-model -l app.kubernetes.io/name=llama-stack-server --tail=50

# Check MCP ConfigMap
oc get configmap gen-ai-aa-mcp-servers -n redhat-ods-applications -o yaml

# Test LlamaStack API
oc exec -n my-first-model deploy/lsd-genai-playground -- \
  curl -s http://localhost:8321/models/list

# Check Dashboard config
oc get odhdashboardconfig odh-dashboard-config -n redhat-ods-applications \
  -o jsonpath='{.spec.dashboardConfig.genAiStudio}'
```

---

## Troubleshooting

### LlamaStack Pod Not Starting

| Error | Cause | Fix |
|-------|-------|-----|
| `fsGroup: Invalid value` | SCC restrictions | Wait — usually auto-resolves on retry |
| `Connection refused` | Wrong model URL | Check `oc get svc -n <namespace>` |
| `PermissionError: /.cache` | Non-root user issue | Container will work, this is a warning |

### Tools Not Appearing in UI

1. Verify ConfigMap exists and has valid JSON:
   ```bash
   oc get configmap gen-ai-aa-mcp-servers -n redhat-ods-applications -o yaml
   ```

2. Restart Dashboard:
   ```bash
   oc rollout restart deployment odh-dashboard -n redhat-ods-applications
   ```

3. Hard refresh browser (Ctrl+Shift+R)

### MCP Server Returns 404

Public MCP servers may be unreliable. Test connectivity:
```bash
oc run curl-test --image=curlimages/curl --rm -it -- \
  curl -v https://mcp-server-url/endpoint
```

Consider self-hosting MCP servers for production.

### Chat Not Working

1. Check model pods are running:
   ```bash
   oc get pods -n my-first-model
   ```

2. Check LlamaStack can reach the model:
   ```bash
   oc exec -n my-first-model deploy/lsd-genai-playground -- \
     curl -s http://qwen3-0-6b-kserve-workload-svc:8000/v1/models
   ```

---

## Files in This Directory

| File | Purpose |
|------|---------|
| `llamastackdistribution.yaml` | LlamaStack server deployment |
| `README.md` | This guide |

---

## References

- [GenAI Playground Showroom Module](https://rhpds.github.io/redhat-openshift-ai-3-showroom/modules/03-04-genai-playground.html)
- [MCP Servers Showroom Module](https://rhpds.github.io/redhat-openshift-ai-3-showroom/modules/03-05-deploy-mcp.html)
- [LlamaStack GitHub](https://github.com/meta-llama/llama-stack)
- [MCP Specification](https://modelcontextprotocol.io/)
- [Blog: GenAI Playground + MCP](../BLOG-3-GENAI-PLAYGROUND-MCP.md)

