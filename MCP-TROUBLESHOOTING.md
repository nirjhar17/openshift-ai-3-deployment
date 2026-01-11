# MCP (Model Context Protocol) Troubleshooting Guide

## Overview
This document captures the complete troubleshooting journey for enabling MCP tools with the GenAI Playground on OpenShift AI 3.0, including the request flow architecture and debugging strategies for each component.

---

## Request Flow Architecture

Understanding how a request flows through the system is critical for troubleshooting. Here's the complete path:

```
┌─────────────────────────────────────────────────────────────────────────────────────┐
│                           MCP Tool Call Request Flow                                 │
├─────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                     │
│  ┌──────────────┐                                                                   │
│  │    User      │  "What is the weather in Tokyo?"                                 │
│  │   Browser    │                                                                   │
│  └──────┬───────┘                                                                   │
│         │ ①                                                                          │
│         ▼                                                                           │
│  ┌──────────────────────────────────────────────────────────────────────────────┐  │
│  │                        GenAI Playground UI                                    │  │
│  │  (OpenShift AI Dashboard - Gen AI Studio)                                     │  │
│  │                                                                               │  │
│  │  • Captures user message                                                      │  │
│  │  • Adds system instructions                                                   │  │
│  │  • Attaches enabled MCP tool configurations                                   │  │
│  │  • Sends POST /v1/openai/v1/responses                                        │  │
│  └──────┬───────────────────────────────────────────────────────────────────────┘  │
│         │ ②                                                                          │
│         ▼                                                                           │
│  ┌──────────────────────────────────────────────────────────────────────────────┐  │
│  │                        LlamaStack Server                                      │  │
│  │  (lsd-genai-playground pod)                                                   │  │
│  │                                                                               │  │
│  │  • Receives request with tools[] configuration                               │  │
│  │  • Connects to MCP servers to discover available tools                       │  │
│  │  • Forwards inference request to vLLM with tool definitions                  │  │
│  └──────┬───────────────────────────────────────────────────────────────────────┘  │
│         │ ③                                                                          │
│         ▼                                                                           │
│  ┌──────────────────────────────────────────────────────────────────────────────┐  │
│  │                           vLLM Server                                         │  │
│  │  (qwen3-0-6b-kserve pod)                                                      │  │
│  │                                                                               │  │
│  │  • Receives POST /v1/chat/completions with tools[] parameter                 │  │
│  │  • Model generates response (may include tool call)                          │  │
│  │  • Tool Call Parser extracts structured tool calls from model output         │  │
│  │  • Returns response with tool_calls[] array                                  │  │
│  └──────┬───────────────────────────────────────────────────────────────────────┘  │
│         │ ④ (if tool_calls detected)                                                │
│         ▼                                                                           │
│  ┌──────────────────────────────────────────────────────────────────────────────┐  │
│  │                        LlamaStack Server                                      │  │
│  │  (Tool Execution)                                                             │  │
│  │                                                                               │  │
│  │  • Receives tool_calls from vLLM response                                    │  │
│  │  • Routes call to appropriate MCP server                                     │  │
│  └──────┬───────────────────────────────────────────────────────────────────────┘  │
│         │ ⑤                                                                          │
│         ▼                                                                           │
│  ┌──────────────────────────────────────────────────────────────────────────────┐  │
│  │                          MCP Server                                           │  │
│  │  (e.g., Weather API - https://weather-mcp-server.apify.actor/mcp)            │  │
│  │                                                                               │  │
│  │  • Receives tool call: get_current_weather(city="Tokyo")                     │  │
│  │  • Executes the actual API call                                              │  │
│  │  • Returns result: "Temperature: 15°C, Cloudy"                               │  │
│  └──────┬───────────────────────────────────────────────────────────────────────┘  │
│         │ ⑥                                                                          │
│         ▼                                                                           │
│  ┌──────────────────────────────────────────────────────────────────────────────┐  │
│  │                        LlamaStack Server                                      │  │
│  │  (Response Assembly)                                                          │  │
│  │                                                                               │  │
│  │  • Receives tool result from MCP server                                      │  │
│  │  • Sends result back to vLLM for final response generation                   │  │
│  │  • vLLM generates user-friendly response using tool result                   │  │
│  └──────┬───────────────────────────────────────────────────────────────────────┘  │
│         │ ⑦                                                                          │
│         ▼                                                                           │
│  ┌──────────────┐                                                                   │
│  │    User      │  "The weather in Tokyo is 15°C and Cloudy."                     │
│  │   Browser    │                                                                   │
│  └──────────────┘                                                                   │
│                                                                                     │
└─────────────────────────────────────────────────────────────────────────────────────┘
```

---

## Component Responsibilities

| Step | Component | Responsibility | Key Logs/Indicators |
|------|-----------|----------------|---------------------|
| ① | Playground UI | Send user message + tool config | Browser Network tab |
| ② | LlamaStack | Route request, discover MCP tools | `POST /v1/openai/v1/responses` |
| ③ | vLLM | Generate response, parse tool calls | `tool_call_parser`, `tool_calls[]` |
| ④ | LlamaStack | Execute tool via MCP protocol | `mcp.client` logs |
| ⑤ | MCP Server | Run actual tool logic | MCP server logs |
| ⑥ | LlamaStack | Assemble final response | Response streaming |
| ⑦ | Playground UI | Display result to user | UI response area |

---

## Environment
- **Model**: Qwen3-0.6B
- **Deployment**: LLMInferenceService with LLM-D (disaggregated inference)
- **Platform**: OpenShift AI 3.0 on ROSA
- **GPU**: Tesla T4
- **MCP Server**: Apify Weather MCP Server

---

## Troubleshooting by Component

### Step ① → ② : Playground UI to LlamaStack

#### Issue: Request Not Reaching LlamaStack

**Symptoms:**
- No response in chat
- Browser console shows network errors

**Debugging Steps:**
```bash
# 1. Check LlamaStack pod is running
oc get pods -n my-first-model | grep llama

# 2. Check LlamaStack logs
oc logs -n my-first-model -l app.kubernetes.io/managed-by=llama-stack-k8s-operator --tail=50

# 3. Check service exists
oc get svc -n my-first-model | grep llama
```

**Common Fixes:**
- Restart LlamaStack pod: `oc delete pod <llama-pod> -n my-first-model`
- Check LlamaStackDistribution CR is correctly configured

---

### Step ② → ③ : LlamaStack to vLLM

#### Issue: vLLM Returns 400 Bad Request

**Symptoms:**
- LlamaStack logs show `400 Bad Request` from vLLM
- Chat shows error or no response

**Root Cause:** vLLM doesn't have tool calling enabled.

**Debugging Steps:**
```bash
# 1. Check vLLM pod args
oc get pod <vllm-pod> -n my-first-model -o jsonpath='{.spec.containers[0].args}'

# 2. Check vLLM logs for errors
oc logs <vllm-pod> -n my-first-model --tail=50 | grep -i "400\|error\|tool"
```

**Solution:** Add tool calling flags to LLMInferenceService:
```bash
oc patch llminferenceservice qwen3-0-6b -n my-first-model --type='json' -p='[
  {
    "op": "replace",
    "path": "/spec/template/containers/0/env/2/value",
    "value": "--dtype=half --max-model-len=4096 --gpu-memory-utilization=0.85 --enforce-eager --enable-auto-tool-choice --tool-call-parser hermes"
  }
]'
```

---

### Step ③ : vLLM Tool Call Parsing

#### Issue: Model Generates Tool Call But `tool_calls[]` is Empty

**Symptoms:**
- Model's `<think>` shows it wants to use a tool
- But response has `"tool_calls": []`
- No actual tool execution happens

**This was our MAIN issue!**

**Debugging Steps:**
```bash
# 1. Test vLLM directly with a tool call request
oc run curl-test --rm -i --restart=Never --image=curlimages/curl -n my-first-model -- \
  curl -k -s "https://qwen3-0-6b-kserve-workload-svc:8000/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen3-0.6B",
    "messages": [{"role": "user", "content": "What is weather in Tokyo?"}],
    "tools": [{
      "type": "function",
      "function": {
        "name": "get_weather",
        "description": "Get weather for city",
        "parameters": {
          "type": "object",
          "properties": {"city": {"type": "string"}},
          "required": ["city"]
        }
      }
    }],
    "max_tokens": 300
  }'

# 2. Check the response
# Look for:
# - "content": contains <tool_call> tags? 
# - "tool_calls": is it empty [] or populated?
# - "finish_reason": is it "tool_calls" or "stop"?
```

**What We Found:**

With `qwen3_xml` parser:
```json
{
  "content": "<think>...</think>\n<tool_call>{\"name\": \"get_weather\", \"arguments\": {\"city\": \"Tokyo\"}}</tool_call>",
  "tool_calls": [],  // EMPTY! Parser failed to extract
  "finish_reason": "stop"
}
```

With `hermes` parser:
```json
{
  "content": "<think>...</think>",
  "tool_calls": [
    {
      "id": "chatcmpl-tool-xxx",
      "type": "function", 
      "function": {
        "name": "get_weather",
        "arguments": "{\"city\": \"Tokyo\"}"
      }
    }
  ],
  "finish_reason": "tool_calls"  // Correctly detected!
}
```

**Root Cause:** The `qwen3_xml` parser doesn't handle `<think>` tags that Qwen3 outputs before `<tool_call>` tags.

**Solution:** Use `hermes` parser instead:
```bash
--tool-call-parser hermes
```

#### Parser Options Reference

| Model Family | Recommended Parser | Notes |
|--------------|-------------------|-------|
| Qwen3 | `hermes` | Works with thinking tags |
| Llama3 | `llama3_json` | JSON format |
| Mistral | `mistral` | Mistral-specific format |
| DeepSeek | `deepseek_v3` | DeepSeek format |
| Generic | `hermes` | Most compatible |

**Invalid Parser Error:**
```
KeyError: 'invalid tool call parser: qwen (chose from { hermes, llama3_json, mistral, ... })'
```
→ Use exact parser name from the supported list.

---

### Step ④ → ⑤ : LlamaStack to MCP Server

#### Issue: MCP Server Not Connecting

**Symptoms:**
- "View tools" button is disabled in Playground
- Lock icon in Auth column

**Debugging Steps:**
```bash
# 1. Check LlamaStack logs for MCP connection
oc logs <llama-pod> -n my-first-model | grep -i "mcp\|session"

# Expected output when working:
# INFO mcp.client.streamable_http: Received session ID: xxx
# INFO mcp.client.streamable_http: Negotiated protocol version: 2025-06-18
```

**Common Causes:**

1. **Authentication Required:**
   - MCP server needs API token
   - Click "Configure" button in Playground UI
   - Enter token in "Access token" field

2. **Server Unreachable:**
   ```bash
   # Test MCP server from cluster
   oc run curl-test --rm -i --restart=Never --image=curlimages/curl -n my-first-model -- \
     curl -v "https://mcp-server-url/mcp"
   ```

3. **Invalid URL in ConfigMap:**
   ```bash
   oc get configmap gen-ai-aa-mcp-servers -n redhat-ods-applications -o yaml
   ```

---

### Step ⑤ : MCP Server Execution

#### Issue: Tool Discovered But Not Executing

**Symptoms:**
- "View tools" button works and shows tools
- Model tries to call tool
- But no result returned

**Debugging Steps:**
```bash
# Check LlamaStack logs during tool execution
oc logs <llama-pod> -n my-first-model --tail=100 | grep -iE "tool|mcp|call|error"
```

**Common Causes:**
- MCP server rate limiting
- Tool parameters don't match schema
- Network timeout

---

## Complete Troubleshooting Checklist

```
┌─────────────────────────────────────────────────────────────────────────────────────┐
│                        MCP Troubleshooting Checklist                                 │
├─────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                     │
│  □ PLAYGROUND UI                                                                    │
│    □ GenAI Studio enabled in OdhDashboardConfig?                                   │
│    □ Model visible and selectable (not greyed out)?                                │
│    □ MCP server checkbox enabled?                                                  │
│                                                                                     │
│  □ LLAMASTACK                                                                       │
│    □ Pod running? (oc get pods | grep llama)                                       │
│    □ Logs show "Received session ID"?                                              │
│    □ No connection errors to vLLM?                                                 │
│                                                                                     │
│  □ VLLM                                                                             │
│    □ Pod running with GPU? (1/1 Running)                                           │
│    □ --enable-auto-tool-choice flag present?                                       │
│    □ --tool-call-parser hermes (not qwen3_xml)?                                    │
│    □ Direct API test returns tool_calls[] populated?                               │
│                                                                                     │
│  □ MCP SERVER                                                                       │
│    □ Server URL correct in ConfigMap?                                              │
│    □ Authentication token provided (if required)?                                  │
│    □ "View tools" button enabled and shows tools?                                  │
│    □ Server reachable from cluster?                                                │
│                                                                                     │
└─────────────────────────────────────────────────────────────────────────────────────┘
```

---

## Useful Commands Reference

### Check All Components
```bash
# vLLM pod status
oc get pods -n my-first-model | grep qwen

# LlamaStack pod status  
oc get pods -n my-first-model | grep llama

# vLLM logs
oc logs <vllm-pod> -n my-first-model --tail=50

# LlamaStack logs
oc logs <llama-pod> -n my-first-model --tail=50

# MCP ConfigMap
oc get configmap gen-ai-aa-mcp-servers -n redhat-ods-applications -o yaml

# vLLM command args
oc get pod <vllm-pod> -n my-first-model -o jsonpath='{.spec.containers[0].args}'
```

### Direct API Testing
```bash
# Test vLLM tool calling
oc run curl-test --rm -i --restart=Never --image=curlimages/curl -n my-first-model -- \
  curl -k -s "https://<vllm-service>:8000/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{"model":"<model-name>","messages":[{"role":"user","content":"test"}],"tools":[...],"max_tokens":300}'
```

---

## Final Working Configuration

### LLMInferenceService vLLM Args
```
--dtype=half 
--max-model-len=4096 
--gpu-memory-utilization=0.85 
--enforce-eager 
--enable-auto-tool-choice 
--tool-call-parser hermes
```

### MCP Server ConfigMap
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: gen-ai-aa-mcp-servers
  namespace: redhat-ods-applications
data:
  Weather: |
    {
      "url": "https://jiri-spilka--weather-mcp-server.apify.actor/mcp",
      "description": "Get real-time weather data. Requires Apify API token."
    }
```

---

## Verified Working Example

**User Query:** "What is the weather of Kuala Lumpur?"

**Model Thinking:**
```
<think>
Okay, the user is asking about the weather in Kuala Lumpur. 
Let me check the tools available. There's a function called get_current_weather...
I need to call that function with the city parameter set to "Kuala Lumpur".
</think>
```

**Tool Call Made:**
```json
{
  "name": "get_current_weather",
  "arguments": {"city": "Kuala Lumpur"}
}
```

**MCP Server Response:**
```
The weather in Kuala Lumpur is Overcast with a temperature of 25.4°C, 
Relative humidity at 2 meters: 87%, 
Dew point temperature at 2 meters: 23.1
```

**Final Response to User:**
```
The weather in Kuala Lumpur is Overcast with a temperature of 25.4°C 
and a relative humidity of 87%. The dew point temperature at 2 meters is 23.1°C.
```

---

## Key Learnings

1. **Parser matters most**: `qwen3_xml` ≠ `hermes` - wrong parser = empty tool_calls
2. **Direct API testing is essential**: Always test vLLM directly to isolate issues
3. **MCP auth is session-based**: Tokens must be re-entered after pod restarts
4. **Check finish_reason**: `"tool_calls"` = working, `"stop"` = parser failed
5. **Model thinks but doesn't act**: Usually means parser isn't extracting the call

---

*Last updated: January 11, 2026*
