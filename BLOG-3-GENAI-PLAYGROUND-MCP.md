# Building an AI Chat Interface with GenAI Playground and MCP Tools on OpenShift AI 3.0

*Part 3: Adding a web-based chat UI and connecting external tools to your LLM*

---

## Introduction

In [Part 1](https://github.com/nirjhar17/openshift-ai-3-deployment/blob/main/BLOG.md), we deployed an LLM using OpenShift AI 3.0's LLM-D architecture with intelligent load balancing and secure HTTPS access. But exposing a REST API is just the beginning — users need a friendly way to interact with the model.

**GenAI Playground** is OpenShift AI's built-in chat interface that connects directly to your deployed models. It's powered by **LlamaStack**, an open-source framework that provides:
- A web-based chat UI
- Agent capabilities (multi-turn conversations)
- **MCP (Model Context Protocol)** support for connecting external tools

In this blog, we'll:
- Enable the GenAI Playground in the OpenShift AI Dashboard
- Connect it to our deployed Qwen model
- Add MCP servers to give the LLM access to external tools (web search, code analysis, etc.)

**What we'll cover:**
- What is GenAI Playground and LlamaStack?
- Enabling the LlamaStack Operator
- Deploying a LlamaStackDistribution
- Understanding MCP (Model Context Protocol)
- Adding remote MCP servers
- Challenges and workarounds

**Prerequisites:** Complete [Part 1](https://github.com/nirjhar17/openshift-ai-3-deployment/blob/main/BLOG.md) first — you need a deployed model.

---

## What is GenAI Playground?

GenAI Playground is a **web-based chat interface** integrated into the OpenShift AI Dashboard. Think of it as your private ChatGPT UI, but connected to your own models running on OpenShift.

```
┌─────────────────────────────────────────────────────────────────────┐
│                     GenAI Playground Architecture                    │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│   ┌─────────────────┐                                               │
│   │   User Browser  │                                               │
│   │   (Chat UI)     │                                               │
│   └────────┬────────┘                                               │
│            │                                                        │
│            ▼                                                        │
│   ┌─────────────────────────────────────────────────────────────┐  │
│   │          OpenShift AI Dashboard                              │  │
│   │          (Gen AI Studio menu)                                │  │
│   └────────────────────────┬────────────────────────────────────┘  │
│                            │                                        │
│                            ▼                                        │
│   ┌─────────────────────────────────────────────────────────────┐  │
│   │          LlamaStack Server                                   │  │
│   │          (LlamaStackDistribution)                            │  │
│   │                                                              │  │
│   │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐          │  │
│   │  │  Inference  │  │   Agents    │  │    Tools    │          │  │
│   │  │    API      │  │    API      │  │   (MCP)     │          │  │
│   │  └──────┬──────┘  └─────────────┘  └──────┬──────┘          │  │
│   └─────────┼────────────────────────────────┼──────────────────┘  │
│             │                                │                      │
│             ▼                                ▼                      │
│   ┌─────────────────┐              ┌─────────────────┐             │
│   │  vLLM Pods      │              │  MCP Servers    │             │
│   │  (Your Model)   │              │  (External)     │             │
│   └─────────────────┘              └─────────────────┘             │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

### What is LlamaStack?

**LlamaStack** is an open-source framework (originally from Meta) that provides a unified API for:

| Component | Purpose |
|-----------|---------|
| **Inference API** | Connect to LLM backends (vLLM, TGI, OpenAI-compatible) |
| **Agents API** | Build multi-turn conversational agents |
| **Tools API** | Integrate external tools via MCP |
| **Safety API** | Content moderation and guardrails |
| **Vector IO** | RAG (Retrieval Augmented Generation) support |

OpenShift AI uses the `LlamaStackDistribution` Custom Resource to deploy a LlamaStack server in your namespace.

---

## Step 1: Enable the LlamaStack Operator

First, ensure the LlamaStack Operator is enabled in your DataScienceCluster:

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
      managementState: Managed  # <-- Enable this
```

```bash
# Apply or patch
oc patch datasciencecluster default-dsc --type='merge' -p '{"spec":{"components":{"llamastackoperator":{"managementState":"Managed"}}}}'

# Verify
oc get datasciencecluster default-dsc -o jsonpath='{.spec.components.llamastackoperator.managementState}'
# Should output: Managed
```

---

## Step 2: Enable GenAI Studio in Dashboard

The OpenShift AI Dashboard needs to have GenAI Studio enabled:

```yaml
# odh-dashboard-config.yaml
apiVersion: opendatahub.io/v1alpha1
kind: OdhDashboardConfig
metadata:
  name: odh-dashboard-config
  namespace: redhat-ods-applications
spec:
  dashboardConfig:
    genAiStudio: true          # <-- Enable GenAI Playground
    modelAsService: true       # <-- Enable Model-as-a-Service features
    disableModelRegistry: false
    disableModelCatalog: false
```

```bash
oc apply -f odh-dashboard-config.yaml

# Or patch existing config
oc patch odhdashboardconfig odh-dashboard-config -n redhat-ods-applications --type='merge' -p '{
  "spec": {
    "dashboardConfig": {
      "genAiStudio": true,
      "modelAsService": true
    }
  }
}'
```

After applying, refresh the OpenShift AI Dashboard. You should see **"Gen AI Studio"** in the left menu.

---

## Step 3: Deploy LlamaStackDistribution

Now deploy the LlamaStack server that will power the GenAI Playground:

```yaml
# llamastackdistribution.yaml
apiVersion: llamastack.opendatahub.io/v1
kind: LlamaStackDistribution
metadata:
  name: lsd-genai-playground
  namespace: my-first-model
  labels:
    opendatahub.io/dashboard: "true"  # Makes it visible in Dashboard
spec:
  # LlamaStack server image
  image: quay.io/opendatahub/llama-stack-server:latest
  
  # Configuration
  config:
    # API endpoints to enable
    apis:
      - agents       # Multi-turn conversation support
      - datasetio    # Dataset management
      - files        # File upload/download
      - inference    # LLM inference
      - safety       # Content moderation
      - scoring      # Response scoring
      - tool_runtime # MCP tool support
      - vector_io    # RAG support
    
    # Model provider configuration
    providers:
      inference:
        - provider_id: vllm-inference-1
          provider_type: remote::vllm
          config:
            # Connect to the vLLM service (internal cluster DNS)
            url: http://qwen3-0-6b-kserve-workload-svc.my-first-model.svc.cluster.local:8000/v1
            api_token: ${env.VLLM_API_TOKEN_1:=fake}
            max_tokens: ${env.VLLM_MAX_TOKENS:=4096}
            tls_verify: false  # Internal cluster traffic
    
    # Register the model
    models:
      - provider_id: vllm-inference-1
        model_id: qwen3-0-6b
        model_type: llm
        metadata:
          description: "Qwen3 0.6B model deployed with LLM-D"
          display_name: qwen3-0-6b
    
    # Server configuration
    server:
      port: 8321
```

```bash
oc apply -f llamastackdistribution.yaml

# Watch the pod start
oc get pods -n my-first-model -w

# Expected output:
# NAME                                    READY   STATUS    
# lsd-genai-playground-xxxxx              1/1     Running
```

### Finding the Correct Service URL

The `url` in the provider config must point to your model's internal service. To find it:

```bash
# List services in your namespace
oc get svc -n my-first-model

# Look for the workload service (not the router)
# Example: qwen3-0-6b-kserve-workload-svc

# The URL format is:
# http://<service-name>.<namespace>.svc.cluster.local:<port>/v1
```

---

## Step 4: Access GenAI Playground

1. Open the **OpenShift AI Dashboard**
2. Click **"Gen AI Studio"** in the left menu
3. You should see your LlamaStackDistribution listed
4. Click on it to open the chat interface

### Using the Chat Interface

The Playground provides:
- **Chat input**: Type your messages
- **Model selector**: Choose which model to use
- **System prompt**: Set the AI's behavior
- **Temperature/Max tokens**: Adjust generation parameters
- **MCP Tools**: Toggle external tools (if configured)

```
┌─────────────────────────────────────────────────────────────────────┐
│  Gen AI Studio - Chat                                               │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  Model: qwen3-0-6b ▼                                               │
│                                                                     │
│  ┌───────────────────────────────────────────────────────────────┐ │
│  │ System: You are a helpful AI assistant.                       │ │
│  └───────────────────────────────────────────────────────────────┘ │
│                                                                     │
│  ┌───────────────────────────────────────────────────────────────┐ │
│  │ User: What is Kubernetes?                                     │ │
│  │                                                               │ │
│  │ Assistant: Kubernetes is an open-source container            │ │
│  │ orchestration platform that automates the deployment,        │ │
│  │ scaling, and management of containerized applications...     │ │
│  └───────────────────────────────────────────────────────────────┘ │
│                                                                     │
│  ┌───────────────────────────────────────────────────────────────┐ │
│  │ Type your message...                              [Send]     │ │
│  └───────────────────────────────────────────────────────────────┘ │
│                                                                     │
│  Tools: [Web Search] [Code Analysis] [Sequential Thinking]         │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Understanding MCP (Model Context Protocol)

**MCP (Model Context Protocol)** is an open standard that allows LLMs to use external tools. Think of it as giving your AI assistant "hands" to interact with the outside world.

### How MCP Works

```
┌─────────────────────────────────────────────────────────────────────┐
│                        MCP Architecture                              │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  User: "What's the weather in Singapore?"                          │
│                                                                     │
│  ┌─────────────┐     ┌─────────────┐     ┌─────────────────────┐   │
│  │    LLM      │────▶│  LlamaStack │────▶│   MCP Server        │   │
│  │  (Qwen)     │     │  (Tool API) │     │   (Weather API)     │   │
│  └─────────────┘     └─────────────┘     └─────────────────────┘   │
│        │                   │                       │               │
│        │                   │                       │               │
│        │    1. User asks   │                       │               │
│        │    about weather  │                       │               │
│        │                   │                       │               │
│        │    2. LLM decides │                       │               │
│        │    to use tool    │                       │               │
│        │                   │                       │               │
│        │                   │  3. Call MCP server   │               │
│        │                   │────────────────────▶  │               │
│        │                   │                       │               │
│        │                   │  4. Return result     │               │
│        │                   │◀────────────────────  │               │
│        │                   │                       │               │
│        │    5. LLM formats │                       │               │
│        │    response       │                       │               │
│        │                   │                       │               │
│  Output: "The current temperature in Singapore is 31°C..."         │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

### MCP Server Types

| Transport | Description | Example |
|-----------|-------------|---------|
| **STDIO** | Local process communication | Local CLI tools |
| **SSE** | Server-Sent Events (HTTP) | Remote web services |
| **HTTP** | REST API | Cloud services |

OpenShift AI supports **remote MCP servers** via SSE/HTTP.

---

## Step 5: Adding MCP Servers

MCP servers are configured via a ConfigMap in the `redhat-ods-applications` namespace. The OpenShift AI Dashboard reads this ConfigMap and displays the tools in the Playground UI.

### ConfigMap Format

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

### Example: Adding Web Search and Code Analysis

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: gen-ai-aa-mcp-servers
  namespace: redhat-ods-applications
data:
  Fetch: |
    {
      "url": "https://remote.mcpservers.org/fetch",
      "description": "Fetch web content and convert HTML to markdown. Use for web browsing."
    }
  Semgrep: |
    {
      "url": "https://mcp.semgrep.ai/sse",
      "description": "Code security and quality analysis tool."
    }
  Sequential-Thinking: |
    {
      "url": "https://remote.mcpservers.org/sequentialthinking",
      "description": "Structured problem-solving through dynamic thinking process."
    }
```

```bash
oc apply -f mcp-servers.yaml
```

After applying, refresh the GenAI Playground. The tools should appear in the UI with toggle switches.

### Using GitHub Copilot MCP

GitHub provides an MCP server for Copilot:

```yaml
data:
  GitHub-MCP-Server: |
    {
      "url": "https://api.githubcopilot.com/mcp",
      "description": "GitHub Copilot MCP Server for code assistance"
    }
```

> ⚠️ **Note**: This requires GitHub Copilot authentication. You'll need to provide your GitHub token when enabling the tool.

---

## Challenges We Encountered

### Challenge 1: Remote MCP Servers Returning 404

**Problem**: Many public MCP servers (like `remote.mcpservers.org`) return 404 errors when the LlamaStack tries to connect.

**Cause**: These servers may be:
- Temporarily unavailable
- Requiring authentication
- Using different endpoint paths

**Workaround**: 
1. Use self-hosted MCP servers
2. Check the MCP server's documentation for correct endpoints
3. Verify the server is accessible from your cluster:
   ```bash
   # Test from a pod in your cluster
   oc run curl-test --image=curlimages/curl --rm -it -- \
     curl -v https://mcp-server-url/endpoint
   ```

### Challenge 2: MCP Server Authentication

**Problem**: Some MCP servers (like GitHub Copilot) require authentication tokens.

**Solution**: The GenAI Playground UI allows you to enter tokens when enabling a tool. Alternatively, configure tokens in the LlamaStackDistribution:

```yaml
spec:
  config:
    providers:
      tool_runtime:
        - provider_id: github-mcp
          provider_type: remote::mcp
          config:
            url: https://api.githubcopilot.com/mcp
            headers:
              Authorization: Bearer ${env.GITHUB_TOKEN}
```

### Challenge 3: Tool Not Appearing in UI

**Problem**: After creating the ConfigMap, tools don't appear in the Playground.

**Solutions**:
1. **Verify ConfigMap exists**:
   ```bash
   oc get configmap gen-ai-aa-mcp-servers -n redhat-ods-applications -o yaml
   ```

2. **Check JSON format**: The value must be valid JSON

3. **Restart Dashboard pod** (if needed):
   ```bash
   oc rollout restart deployment odh-dashboard -n redhat-ods-applications
   ```

4. **Hard refresh browser**: Clear cache and reload

### Challenge 4: LlamaStack Pod Not Starting

**Problem**: The LlamaStackDistribution pod enters CrashLoopBackOff.

**Common causes and fixes**:

| Error | Cause | Fix |
|-------|-------|-----|
| `fsGroup: Invalid value` | SCC restrictions | Let it retry — usually resolves automatically |
| `Connection refused` | Wrong model service URL | Check `oc get svc -n <namespace>` |
| `PermissionError: /.cache` | Non-root user | Add `HOME=/tmp` environment variable |

---

## Self-Hosting MCP Servers

For production use, consider deploying your own MCP servers on OpenShift:

### Example: Deploy a Simple MCP Server

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
          env:
            - name: API_KEY
              valueFrom:
                secretKeyRef:
                  name: mcp-secrets
                  key: api-key
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

Then reference it in the ConfigMap:

```yaml
data:
  My-Custom-Tool: |
    {
      "url": "http://my-mcp-server.my-first-model.svc.cluster.local:8080/sse",
      "description": "My custom MCP tool"
    }
```

---

## Building Agents

LlamaStack's **Agents API** allows you to create persistent conversational agents with:
- System prompts
- Tool access
- Memory (conversation history)

### Creating an Agent via API

```bash
# Create an agent
curl -X POST http://lsd-genai-playground.my-first-model.svc.cluster.local:8321/agents/create \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen3-0-6b",
    "instructions": "You are a helpful coding assistant.",
    "tools": [
      {"type": "web_search"},
      {"type": "code_interpreter"}
    ]
  }'

# Start a conversation
curl -X POST http://lsd-genai-playground.my-first-model.svc.cluster.local:8321/agents/<agent_id>/turn \
  -H "Content-Type: application/json" \
  -d '{
    "messages": [{"role": "user", "content": "Write a Python function to sort a list"}]
  }'
```

---

## Complete Configuration Reference

### LlamaStackDistribution Full Example

```yaml
apiVersion: llamastack.opendatahub.io/v1
kind: LlamaStackDistribution
metadata:
  name: lsd-genai-playground
  namespace: my-first-model
  labels:
    opendatahub.io/dashboard: "true"
spec:
  image: quay.io/opendatahub/llama-stack-server:latest
  
  config:
    apis:
      - agents
      - datasetio
      - files
      - inference
      - safety
      - scoring
      - tool_runtime
      - vector_io
    
    providers:
      inference:
        - provider_id: vllm-inference-1
          provider_type: remote::vllm
          config:
            url: http://qwen3-0-6b-kserve-workload-svc.my-first-model.svc.cluster.local:8000/v1
            api_token: ${env.VLLM_API_TOKEN_1:=fake}
            max_tokens: 4096
            tls_verify: false
      
      # Add tool runtime provider for MCP
      tool_runtime:
        - provider_id: mcp-tools
          provider_type: remote::mcp
          config:
            mcp_servers:
              - url: http://my-mcp-server.my-first-model.svc.cluster.local:8080/sse
                name: my-custom-tool
    
    models:
      - provider_id: vllm-inference-1
        model_id: qwen3-0-6b
        model_type: llm
        metadata:
          description: "Qwen3 0.6B model deployed with LLM-D"
          display_name: qwen3-0-6b
    
    tool_groups:
      - toolgroup_id: web-tools
        provider_id: mcp-tools
    
    server:
      port: 8321
```

### MCP Servers ConfigMap Full Example

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: gen-ai-aa-mcp-servers
  namespace: redhat-ods-applications
data:
  # Web browsing
  Fetch: |
    {
      "url": "https://your-fetch-server/sse",
      "description": "Fetch web content and convert to markdown"
    }
  
  # Code analysis
  Code-Analysis: |
    {
      "url": "https://your-code-server/sse",
      "description": "Analyze code for security issues and best practices"
    }
  
  # Structured thinking
  Sequential-Thinking: |
    {
      "url": "https://your-thinking-server/sse",
      "description": "Break down complex problems step by step"
    }
  
  # GitHub integration (requires auth)
  GitHub: |
    {
      "url": "https://api.githubcopilot.com/mcp",
      "description": "GitHub Copilot integration for code assistance"
    }
```

---

## Verification Commands

```bash
# Check LlamaStackDistribution status
oc get llamastackdistribution -n my-first-model

# Check LlamaStack pod logs
oc logs -n my-first-model -l app.kubernetes.io/name=llama-stack-server

# Check MCP ConfigMap
oc get configmap gen-ai-aa-mcp-servers -n redhat-ods-applications -o yaml

# Test LlamaStack API directly
oc exec -n my-first-model deploy/lsd-genai-playground -- \
  curl -s http://localhost:8321/models/list | jq

# Check if Dashboard has GenAI Studio enabled
oc get odhdashboardconfig odh-dashboard-config -n redhat-ods-applications \
  -o jsonpath='{.spec.dashboardConfig.genAiStudio}'
```

---

## Conclusion

We've successfully set up the GenAI Playground — a web-based chat interface for interacting with our deployed LLM. Key takeaways:

1. **LlamaStack powers the Playground** — it provides inference, agents, and tool APIs
2. **MCP enables external tools** — give your LLM access to web search, code analysis, etc.
3. **ConfigMap-based tool registration** — easy to add/remove MCP servers
4. **Self-hosted MCP servers recommended** — public servers may be unreliable

### What's Next?

In **Part 2**, we explored RateLimitPolicy for tiered access. The complete series:

- **Part 1**: [LLM Deployment with LLM-D](https://github.com/nirjhar17/openshift-ai-3-deployment/blob/main/BLOG.md) ✅
- **Part 2**: RateLimitPolicy & DNSPolicy (coming soon)
- **Part 3**: GenAI Playground + MCP (this blog) ✅

---

## Resources

- **GitHub Repository**: [github.com/nirjhar17/openshift-ai-3-deployment](https://github.com/nirjhar17/openshift-ai-3-deployment)
- **LlamaStack Documentation**: [github.com/meta-llama/llama-stack](https://github.com/meta-llama/llama-stack)
- **MCP Specification**: [modelcontextprotocol.io](https://modelcontextprotocol.io/)
- **OpenShift AI 3.0 Showroom**: [GenAI Playground Module](https://rhpds.github.io/redhat-openshift-ai-3-showroom/modules/03-04-genai-playground.html)
- **OpenShift AI Documentation**: [docs.redhat.com](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.0)

---

*Author: Nirjhar Jajodia*  
*Date: January 2026*

