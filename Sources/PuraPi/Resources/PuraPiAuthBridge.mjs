// PuraPi 的受控认证伴随进程。
// 只调用 Pi 官方 ModelRuntime，不创建 Agent Session，也不实现 OAuth 协议。

import {
  lstatSync,
  readFileSync,
  statSync,
  unlinkSync,
  writeFileSync,
  writeSync,
} from "node:fs";
import { pathToFileURL } from "node:url";
import { resolve as resolvePath } from "node:path";

const MAX_LINE_BYTES = 256 * 1024;
const MAX_OUTPUT_BYTES = 1024 * 1024;
const MAX_STRING_LENGTH = 4 * 1024;
const MAX_MODEL_COUNT = 1_000;
const MAX_MODELS_CONFIG_BYTES = 2 * 1024 * 1024;
const MAX_AUTH_FILE_BYTES = 1 * 1024 * 1024;
const MAX_CONFIG_NODES = 20_000;

function parseArguments(values) {
  const result = {};
  for (let index = 0; index < values.length; index += 1) {
    const value = values[index];
    if (!value.startsWith("--")) continue;
    const name = value.slice(2);
    const next = values[index + 1];
    if (next && !next.startsWith("--")) {
      result[name] = next;
      index += 1;
    } else {
      result[name] = true;
    }
  }
  return result;
}

const argumentsMap = parseArguments(process.argv.slice(2));
const entryPath = typeof argumentsMap.entry === "string"
  ? resolvePath(argumentsMap.entry)
  : undefined;
const authPath = typeof argumentsMap["auth-path"] === "string"
  ? resolvePath(argumentsMap["auth-path"])
  : undefined;
const modelsPath = typeof argumentsMap["models-path"] === "string"
  ? (argumentsMap["models-path"] === "-" ? null : resolvePath(argumentsMap["models-path"]))
  : null;
const modelsStorePath = typeof argumentsMap["models-store-path"] === "string"
  ? resolvePath(argumentsMap["models-store-path"])
  : undefined;
const readOnlyAuth = argumentsMap["read-only-auth"] === true;
let effectiveModelsPath = modelsPath;
let safeModelsConfigurationPath;

function safeString(value, limit = MAX_STRING_LENGTH) {
  if (typeof value !== "string") return "";
  return value.length > limit ? `${value.slice(0, limit)}…` : value;
}

function authFileRevision() {
  if (!authPath) return "missing";
  try {
    const stats = lstatSync(authPath, { bigint: true });
    if (!stats.isFile()) return "unsafe";
    return `${stats.dev}:${stats.ino}:${stats.size}:${stats.mtimeNs}:${stats.ctimeNs}`;
  } catch {
    return "missing";
  }
}

function assertAuthFileSize() {
  if (!authPath) return;
  try {
    const stats = lstatSync(authPath);
    if (!stats.isFile()) {
      throw new Error("auth.json 不是安全的普通文件。");
    }
    if (stats.size > MAX_AUTH_FILE_BYTES) {
      throw new Error("auth.json 超过认证桥接的安全限制。");
    }
    if ((stats.mode & 0o077) !== 0) {
      throw new Error("auth.json 权限过宽。");
    }
  } catch (error) {
    if (error?.code === "ENOENT") return;
    if (error?.message === "auth.json 超过认证桥接的安全限制。"
        || error?.message === "auth.json 不是安全的普通文件。"
        || error?.message === "auth.json 权限过宽。") throw error;
    throw new Error("无法读取 auth.json，认证桥接已停止。", { cause: error });
  }
}

function stripJsonComments(input) {
  return input
    .replace(/"(?:\\.|[^"\\])*"|\/\/[^\n]*/g, (match) => (match[0] === '"' ? match : ""))
    .replace(/"(?:\\.|[^"\\])*"|,(\s*[}\]])/g, (match, tail) => tail ?? (match[0] === '"' ? match : ""));
}

function readModelsConfiguration() {
  if (!modelsPath) return { exists: false, content: null, value: undefined };
  let stats;
  try {
    stats = statSync(modelsPath);
  } catch (error) {
    if (error?.code === "ENOENT") {
      return { exists: false, content: null, value: undefined };
    }
    throw new Error("无法读取 models.json，认证桥接已停止。", { cause: error });
  }
  if (!stats.isFile() || stats.size > MAX_MODELS_CONFIG_BYTES) {
    throw new Error("models.json 超过认证桥接的安全限制。");
  }
  let content;
  try {
    content = readFileSync(modelsPath);
  } catch (error) {
    throw new Error("无法读取 models.json，认证桥接已停止。", { cause: error });
  }
  if (content.length > MAX_MODELS_CONFIG_BYTES) {
    throw new Error("models.json 超过认证桥接的安全限制。");
  }
  try {
    const value = JSON.parse(stripJsonComments(content.toString("utf8").replace(/^\uFEFF/u, "")));
    return { exists: true, content, value };
  } catch (error) {
    throw new Error("models.json 无法安全解析，认证桥接已停止。", { cause: error });
  }
}

function containsCommandReference(value, state = { count: 0 }, depth = 0) {
  if (++state.count > MAX_CONFIG_NODES || depth > 64) {
    throw new Error("models.json 结构超过认证桥接的安全限制。");
  }
  if (typeof value === "string") return value.startsWith("!");
  if (!value || typeof value !== "object") return false;
  if (Array.isArray(value)) {
    return value.some((entry) => containsCommandReference(entry, state, depth + 1));
  }
  return Object.values(value).some((entry) => containsCommandReference(entry, state, depth + 1));
}

function isEnvironmentReference(value) {
  return typeof value === "string"
    && (/^\$[A-Za-z_][A-Za-z0-9_]*$/u.test(value)
      || /^\$\{[A-Za-z_][A-Za-z0-9_]*\}$/u.test(value));
}

function sanitizeModelsConfiguration(value) {
  if (Array.isArray(value)) {
    return value.map((entry) => sanitizeModelsConfiguration(entry));
  }
  if (!value || typeof value !== "object") return value;

  const result = {};
  for (const [key, child] of Object.entries(value)) {
    const normalizedKey = key.toLowerCase().replaceAll("_", "");
    if (normalizedKey === "apikey") {
      // 环境变量名不是秘密；字面量 API Key 不复制进临时配置文件。
      if (isEnvironmentReference(child)) result[key] = child;
      continue;
    }
    if (normalizedKey === "headers") {
      // header 值无法可靠区分常量和认证材料，只保留环境变量引用。
      const safeHeaders = {};
      if (child && typeof child === "object" && !Array.isArray(child)) {
        for (const [header, headerValue] of Object.entries(child)) {
          if (isEnvironmentReference(headerValue)) safeHeaders[header] = headerValue;
        }
      }
      if (Object.keys(safeHeaders).length > 0) result[key] = safeHeaders;
      continue;
    }
    if (normalizedKey === "providers" && child && typeof child === "object" && !Array.isArray(child)) {
      const safeProviders = {};
      for (const [providerId, providerConfig] of Object.entries(child)) {
        const sanitizedProvider = sanitizeModelsConfiguration(providerConfig);
        if (sanitizedProvider && typeof sanitizedProvider === "object"
            && Object.keys(sanitizedProvider).length > 0) {
          safeProviders[providerId] = sanitizedProvider;
        }
      }
      if (Object.keys(safeProviders).length > 0) result[key] = safeProviders;
      continue;
    }
    if (["access", "refresh", "token", "secret", "password", "credential", "clientsecret", "authorization"]
      .includes(normalizedKey)
      || normalizedKey.includes("token")
      || normalizedKey.includes("secret")
      || normalizedKey.includes("password")
      || normalizedKey.includes("credential")
      || normalizedKey.endsWith("key")) {
      continue;
    }
    result[key] = sanitizeModelsConfiguration(child);
  }
  return result;
}

function prepareSafeModelsConfiguration() {
  const loaded = readModelsConfiguration();
  if (!loaded.exists) {
    // 显式传入的缺失路径不能回退到 SDK 默认的用户 models.json，避免绕过检查。
    effectiveModelsPath = null;
    return;
  }
  if (containsCommandReference(loaded.value)) {
    // Pi 的 models.json 支持以 ! 开头的 shell 命令。认证 sidecar 不具备
    // 项目 Runtime 的命令授权语义，因此必须拒绝这类配置，而不能间接执行。
    throw new Error("认证桥接不支持 models.json 中的命令型配置；请在普通 Pi Runtime 中使用。");
  }
  guardIsolatedModelsStore();
  const safeConfiguration = sanitizeModelsConfiguration(loaded.value);
  const serialized = JSON.stringify(safeConfiguration);
  safeModelsConfigurationPath = `${modelsStorePath}.config-${process.pid}-${Date.now()}.json`;
  try {
    writeFileSync(safeModelsConfigurationPath, serialized, {
      encoding: "utf8",
      mode: 0o600,
      flag: "wx",
    });
  } catch (error) {
    throw new Error("无法创建认证用的模型配置快照。", { cause: error });
  }
  effectiveModelsPath = safeModelsConfigurationPath;
}

function guardIsolatedModelsStore() {
  if (!modelsStorePath) {
    throw new Error("认证桥接缺少隔离模型缓存路径。");
  }
}

function cleanupSafeModelsConfiguration() {
  if (!safeModelsConfigurationPath) return;
  try {
    unlinkSync(safeModelsConfigurationPath);
  } catch {
    // Swift 侧会在 sidecar 结束后删除整个私有缓存目录；这里仅做及时清理。
  }
  safeModelsConfigurationPath = undefined;
}

process.on("exit", cleanupSafeModelsConfiguration);

function safeError(error, limit = MAX_STRING_LENGTH) {
  const rawMessage = error instanceof Error ? error.message : String(error);
  // 先限制正则处理的输入，避免异常响应体很大时脱敏本身造成额外内存压力。
  let message = safeString(rawMessage, MAX_STRING_LENGTH * 16);
  // 错误文本可能包含 JSON、HTTP 或 provider 返回的敏感字段；字段名可能带引号，
  // 因此值匹配必须同时覆盖 quoted 和 unquoted 两种形状。
  message = message.replace(
    /(["']?(?:access[_ -]?token|refresh[_ -]?token|id[_ -]?token|api[_ -]?key|auth(?:orization)?|client[_ -]?secret|oauth[_ -]?token|password|secret|credential)["']?\s*[:=]\s*)(?:(?:Bearer|Basic)\s+[^\s,;\]}]+|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|[^\s,;\]}]+)/giu,
    "$1[已隐藏]",
  );
  // Provider 错误有时直接回显 sk-*、JWT 或 Bearer；即使没有字段名也不能传给 GUI。
  message = message.replace(/\bsk-[A-Za-z0-9_-]+\b/gu, "[凭据已隐藏]");
  message = message.replace(/\beyJ[A-Za-z0-9_-]+\b/gu, "[令牌已隐藏]");
  message = message.replace(/\b(?:Bearer|Basic)\s+[^\s,;\]}]+/giu, "[认证信息已隐藏]");
  message = message.replace(
    /([?&](?:code|state|token|key|secret|authorization)=)[^&\s"'<>]+/giu,
    "$1[已隐藏]",
  );
  return safeString(message, limit);
}

function emit(message) {
  try {
    let output = JSON.stringify(message);
    if (Buffer.byteLength(output, "utf8") > MAX_OUTPUT_BYTES && Array.isArray(message.models)) {
      let low = 0;
      let high = message.models.length;
      let best = 0;
      while (low <= high) {
        const middle = Math.floor((low + high) / 2);
        const candidate = JSON.stringify({
          ...message,
          models: message.models.slice(0, middle),
          modelsTruncated: true,
        });
        if (Buffer.byteLength(candidate, "utf8") <= MAX_OUTPUT_BYTES) {
          best = middle;
          low = middle + 1;
        } else {
          high = middle - 1;
        }
      }
      output = JSON.stringify({
        ...message,
        models: message.models.slice(0, best),
        modelsTruncated: true,
      });
    }
    if (Buffer.byteLength(output, "utf8") > MAX_OUTPUT_BYTES) {
      output = JSON.stringify({
        type: "protocol_error",
        message: "认证结果超过安全大小限制。",
      });
    }
    // 同步写完再返回，避免随后 process.exit() 在大模型目录结果上截断 stdout。
    writeSync(1, `${output}\n`, undefined, "utf8");
  } catch {
    // stdout 关闭时只能结束进程，不能把异常写到可能被当作协议的输出中。
    process.exitCode = 1;
  }
}

function safeProviderStatus(runtime, providerId, credentials) {
  const stored = credentials.find((credential) => credential.providerId === providerId);
  if (stored) {
    const provider = runtime.getProvider(providerId);
    return {
      configured: true,
      type: stored.type === "oauth" ? "oauth" : "api_key",
      source: "stored",
      subscription: stored.type === "oauth" && provider?.auth?.oauth?.isSubscription === true,
    };
  }
  const status = runtime.getProviderAuthStatus(providerId);
  if (!status?.configured) return null;
  const source = safeError(status.label ?? status.source ?? "", 160);
  return {
    configured: true,
    type: runtime.isUsingOAuth(providerId) ? "oauth" : "api_key",
    source: source || null,
    subscription: runtime.isUsingSubscription(providerId),
  };
}

function providerInfo(runtime, provider, credentials) {
  const authTypes = [];
  if (provider.auth?.oauth) {
    authTypes.push({
      type: "oauth",
      name: safeError(provider.auth.oauth.name, 240),
      isSubscription: provider.auth.oauth.isSubscription === true,
      loginLabel: provider.auth.oauth.loginLabel
        ? safeError(provider.auth.oauth.loginLabel, 240)
        : null,
      canLogin: typeof provider.auth.oauth.login === "function",
    });
  }
  if (provider.auth?.apiKey) {
    authTypes.push({
      type: "api_key",
      name: safeError(provider.auth.apiKey.name, 240),
      isSubscription: false,
      loginLabel: null,
      canLogin: typeof provider.auth.apiKey.login === "function",
    });
  }
  return {
    id: safeString(provider.id, 160),
    name: safeError(provider.name, 240),
    authTypes,
    status: safeProviderStatus(runtime, provider.id, credentials),
  };
}

function modelInfo(model) {
  const providerId = safeString(model.provider, 160);
  const id = safeString(model.id, 240);
  if (!providerId || !id) return null;
  return {
    providerId,
    id,
    name: safeError(model.name ?? model.id, 240),
    api: safeString(model.api, 120),
    reasoning: model.reasoning === true,
    input: Array.isArray(model.input)
      ? model.input.filter((item) => item === "text" || item === "image").slice(0, 8)
      : ["text"],
    contextWindow: Number.isSafeInteger(model.contextWindow) ? model.contextWindow : 0,
    maxTokens: Number.isSafeInteger(model.maxTokens) ? model.maxTokens : 0,
  };
}

async function snapshot(runtime, signal) {
  const credentials = (await runtime.listCredentials({ signal })).map((credential) => ({
    providerId: safeString(credential.providerId, 160),
    type: credential.type === "oauth" ? "oauth" : "api_key",
  }));
  const providers = runtime.getProviders().map((provider) => providerInfo(runtime, provider, credentials));

  // getAvailable 只检查认证并读取本地/缓存模型目录，不主动刷新远程目录。
  // 按 Provider 分开读取：某个自定义 Provider 配置损坏时，不能让整个账号页
  // 丢失其它 Provider 的状态和模型。
  const available = [];
  const availabilityErrors = [];
  for (const provider of runtime.getProviders()) {
    try {
      const models = await runtime.getAvailable(provider.id, { signal });
      available.push(...models);
    } catch (error) {
      if (signal.aborted) throw error;
      availabilityErrors.push({
        providerId: safeString(provider.id, 160),
        message: safeError(error),
      });
    }
  }
  const models = available.slice(0, MAX_MODEL_COUNT).map(modelInfo).filter(Boolean);
  return {
    providers,
    credentials,
    models,
    modelsTruncated: available.length > MAX_MODEL_COUNT,
    availabilityErrors,
    authStorageRevision: authFileRevision(),
  };
}

let runtime;
try {
  prepareSafeModelsConfiguration();
  assertAuthFileSize();
  if (!entryPath) throw new Error("缺少 Pi SDK 入口路径。");
  const module = await import(pathToFileURL(entryPath).href);
  if (!module.ModelRuntime) throw new Error("当前 Pi 安装没有导出 ModelRuntime。");
  const options = {
    allowModelNetwork: false,
    refreshOnCreate: true,
  };
  if (authPath) options.authPath = authPath;
  options.modelsPath = effectiveModelsPath;
  if (modelsStorePath !== undefined) options.modelsStorePath = modelsStorePath;
  if (readOnlyAuth) {
    if (!authPath) throw new Error("只读认证状态缺少 auth.json 路径。");
    let ReadOnlyAuthStorage = module.ReadOnlyAuthStorage;
    if (!ReadOnlyAuthStorage) {
      const authStorageModule = await import(new URL("./core/auth-storage.js", pathToFileURL(entryPath)).href);
      ReadOnlyAuthStorage = authStorageModule.ReadOnlyAuthStorage;
    }
    if (!ReadOnlyAuthStorage) {
      throw new Error("当前 Pi 安装没有可用的只读认证存储。");
    }
    // 优先使用官方入口公开的实现，否则从同一官方包的 core 模块读取；
    // 两条路径都避免状态查询创建或修改用户 auth.json。
    options.credentials = new ReadOnlyAuthStorage(authPath);
  }
  runtime = await module.ModelRuntime.create(options);
} catch (error) {
  emit({ type: "fatal_error", message: safeError(error) || "无法初始化 Pi 官方认证运行时。" });
  cleanupSafeModelsConfiguration();
  process.exitCode = 1;
  process.exit();
}

emit({ type: "ready", protocolVersion: 1 });

let activeOperation = null;
const pendingPrompts = new Map();
let promptSequence = 0;
let inputBuffer = Buffer.alloc(0);
let shuttingDown = false;
let forcedExitTimer;

function rejectPendingPrompts(error) {
  for (const pending of pendingPrompts.values()) {
    pending.reject(error);
  }
  pendingPrompts.clear();
}

function authInteraction(operation) {
  return {
    signal: operation.controller.signal,
    prompt: (prompt) => {
      if (operation.controller.signal.aborted) {
        return Promise.reject(new Error("Login cancelled"));
      }
      const promptId = `${operation.id}:prompt:${++promptSequence}`;
      const safePrompt = {
        id: promptId,
        type: ["text", "secret", "select", "manual_code"].includes(prompt.type)
          ? prompt.type
          : "text",
        message: safeError(prompt.message),
        placeholder: prompt.placeholder ? safeError(prompt.placeholder, 512) : null,
        options: Array.isArray(prompt.options)
          ? prompt.options.slice(0, 100).map((option) => ({
              id: safeString(option.id, 512),
              label: safeError(option.label, 512),
              description: option.description ? safeError(option.description, 1_024) : null,
            }))
          : [],
      };
      safePrompt.kind = safePrompt.type;
      const promptSignal = prompt.signal;
      const promise = new Promise((resolve, reject) => {
        const onAbort = () => {
          pendingPrompts.delete(promptId);
          operation.controller.signal.removeEventListener("abort", onAbort);
          promptSignal?.removeEventListener("abort", onAbort);
          reject(new Error("Login cancelled"));
        };
        if (promptSignal?.aborted) {
          reject(new Error("Login cancelled"));
          return;
        }
        pendingPrompts.set(promptId, {
          resolve,
          reject,
          onAbort,
          promptSignal,
          prompt: safePrompt,
        });
        operation.controller.signal.addEventListener("abort", onAbort, { once: true });
        promptSignal?.addEventListener("abort", onAbort, { once: true });
      });
      emit({
        type: "prompt",
        id: promptId,
        operationId: operation.id,
        prompt: safePrompt,
      });
      return promise;
    },
    notify: (event) => {
      if (!event || typeof event.type !== "string") return;
      const safeEvent = { type: safeString(event.type, 64) };
      if (event.message) safeEvent.message = safeError(event.message);
      if (event.url) safeEvent.url = safeString(event.url, 4_096);
      if (event.instructions) safeEvent.instructions = safeError(event.instructions);
      if (event.userCode) safeEvent.userCode = safeError(event.userCode, 512);
      if (event.verificationUri) safeEvent.verificationUri = safeString(event.verificationUri, 4_096);
      if (Number.isFinite(event.intervalSeconds)) safeEvent.intervalSeconds = event.intervalSeconds;
      if (Number.isFinite(event.expiresInSeconds)) safeEvent.expiresInSeconds = event.expiresInSeconds;
      if (Array.isArray(event.links)) {
        safeEvent.links = event.links.slice(0, 20).map((link) => ({
          url: safeString(link?.url, 4_096),
          label: link?.label ? safeError(link.label, 512) : null,
        }));
      }
      emit({ type: "auth_event", operationId: operation.id, event: safeEvent });
    },
  };
}

function finishProcess(code = 0, graceMilliseconds = 0) {
  if (shuttingDown) return;
  if (graceMilliseconds > 0) {
    shuttingDown = true;
    forcedExitTimer = setTimeout(() => {
      forcedExitTimer = undefined;
      shuttingDown = false;
      finishProcess(code);
    }, graceMilliseconds);
    return;
  }
  shuttingDown = true;
  cleanupSafeModelsConfiguration();
  setTimeout(() => {
    process.exitCode = code;
    process.exit();
  }, 0);
}

async function handleOperation(request) {
  const operation = {
    id: safeString(request.id, 160) || `operation-${Date.now()}`,
    controller: new AbortController(),
  };
  let mutationBeforeRevision;
  let mutationCommitted = false;
  let mutationProviderIDs = [];
  activeOperation = operation;
  try {
    let result;
    switch (request.type) {
      case "status":
      case "models":
        result = await snapshot(runtime, operation.controller.signal);
        break;
      case "validate": {
        const authErrors = [];
        const changedProviderIds = [];
        mutationBeforeRevision = authFileRevision();
        mutationProviderIDs = runtime.getProviders().map((provider) => safeString(provider.id, 160));
        for (const provider of runtime.getProviders()) {
          if (!runtime.getProviderAuthStatus(provider.id)?.configured) continue;
          // 只对官方 OAuth Provider 调用 getAuth，让 Pi 负责过期令牌刷新。
          // API Key 的 models.json 自定义解析器可能含有用户命令；这里只报告
          // 配置存在，不在 PuraPi 认证检查中主动执行它们。
          if (!runtime.isUsingOAuth(provider.id)) continue;
          const beforeRevision = authFileRevision();
          try {
            await runtime.getAuth(provider.id, { signal: operation.controller.signal });
            if (beforeRevision !== authFileRevision()) {
              changedProviderIds.push(safeString(provider.id, 160));
            }
          } catch (error) {
            if (beforeRevision !== authFileRevision()) {
              changedProviderIds.push(safeString(provider.id, 160));
            }
            authErrors.push({
              providerId: safeString(provider.id, 160),
              message: safeError(error),
            });
          }
        }
        result = await snapshot(runtime, operation.controller.signal);
        result.authErrors = authErrors;
        result.changedProviderIds = [...new Set(changedProviderIds)];
        break;
      }
      case "login": {
        const providerId = safeString(request.provider, 160);
        const authType = request.authType === "oauth" ? "oauth" : request.authType === "api_key" ? "api_key" : null;
        if (!providerId || !authType) throw new Error("认证请求缺少 provider 或认证类型。");
        mutationProviderIDs = [providerId];
        mutationBeforeRevision = authFileRevision();
        await runtime.login(providerId, authType, authInteraction(operation));
        mutationCommitted = true;
        result = await snapshot(runtime, operation.controller.signal);
        result.changedProviderId = providerId;
        result.changedProviderIds = [providerId];
        result.changedAuthType = authType;
        break;
      }
      case "logout": {
        const providerId = safeString(request.provider, 160);
        if (!providerId) throw new Error("退出认证请求缺少 provider。");
        mutationProviderIDs = [providerId];
        mutationBeforeRevision = authFileRevision();
        await runtime.logout(providerId, { signal: operation.controller.signal });
        mutationCommitted = true;
        result = await snapshot(runtime, operation.controller.signal);
        result.changedProviderId = providerId;
        result.changedProviderIds = [providerId];
        break;
      }
      case "refresh": {
        const providers = Array.isArray(request.providers)
          ? request.providers.map((value) => safeString(value, 160)).filter(Boolean)
          : undefined;
        const beforeRevision = authFileRevision();
        mutationBeforeRevision = beforeRevision;
        mutationProviderIDs = providers ?? runtime.getProviders().map((provider) => safeString(provider.id, 160));
        const refreshResult = await runtime.refresh({
          allowNetwork: request.allowNetwork === true,
          force: request.force === true,
          providers,
          signal: operation.controller.signal,
        });
        result = await snapshot(runtime, operation.controller.signal);
        result.refreshAborted = refreshResult.aborted === true;
        if (beforeRevision !== authFileRevision()) {
          // 文件修订变化时无法仅凭快照判断哪一项 OAuth 被刷新；把本次
          // refresh 候选全部报告给协调器，宁可多提示一次，也不能漏掉旧 Runtime。
          result.changedProviderIds = [...new Set(mutationProviderIDs)];
        }
        result.refreshErrors = [...refreshResult.errors.entries()].map(([providerId, error]) => ({
          providerId: safeString(providerId, 160),
          message: safeError(error),
        }));
        break;
      }
      default:
        throw new Error(`未知认证操作：${safeString(request.type, 80)}`);
    }
    emit({
      type: "result",
      id: operation.id,
      operation: safeString(request.type, 80),
      ...result,
    });
    activeOperation = null;
    rejectPendingPrompts(new Error("认证操作已完成。"));
    finishProcess(0);
  } catch (error) {
    activeOperation = null;
    rejectPendingPrompts(error);
    const revisionChanged = mutationBeforeRevision !== undefined
      && mutationBeforeRevision !== authFileRevision();
    const credentialCommitted = mutationCommitted
      || revisionChanged
      || error?.name === "CredentialSynchronizationError";
    emit({
      type: "error",
      id: operation.id,
      operation: safeString(request.type, 80),
      cancelled: operation.controller.signal.aborted,
      credentialCommitted,
      changedProviderIds: credentialCommitted ? [...new Set(mutationProviderIDs)] : [],
      message: safeError(error) || "认证操作失败。",
    });
    finishProcess(operation.controller.signal.aborted ? 2 : 1);
  }
}

function handlePromptResponse(request) {
  if (!activeOperation || typeof request.id !== "string") return;
  const pending = pendingPrompts.get(request.id);
  if (!pending) return;
  pendingPrompts.delete(request.id);
  activeOperation.controller.signal.removeEventListener("abort", pending.onAbort);
  pending.promptSignal?.removeEventListener("abort", pending.onAbort);
  if (typeof request.value !== "string" || request.value.length > 64 * 1024) {
    pending.reject(new Error("输入内容超过认证安全限制。"));
    return;
  }
  if (pending.prompt.kind === "select"
      && !pending.prompt.options.some((option) => option.id === request.value)) {
    pending.reject(new Error("认证选择项无效。"));
    return;
  }
  pending.resolve(request.value);
}

function handleInputLine(line) {
  let request;
  try {
    request = JSON.parse(line);
  } catch {
    emit({ type: "protocol_error", message: "认证桥接收到无效 JSON。" });
    return;
  }
  if (!request || typeof request !== "object") return;
  if (request.type === "prompt_response") {
    handlePromptResponse(request);
    return;
  }
  if (request.type === "cancel") {
    if (activeOperation && (!request.id || request.id === activeOperation.id)) {
      activeOperation.controller.abort();
      rejectPendingPrompts(new Error("Login cancelled"));
    }
    return;
  }
  if (activeOperation) {
    emit({ type: "error", id: safeString(request.id, 160), message: "已有认证操作正在进行。" });
    return;
  }
  void handleOperation(request);
}

process.stdin.on("data", (chunk) => {
  if (shuttingDown) return;
  inputBuffer = Buffer.concat([inputBuffer, Buffer.from(chunk)]);
  if (inputBuffer.length > MAX_LINE_BYTES && !inputBuffer.includes(0x0a)) {
    emit({ type: "protocol_error", message: "认证请求超过安全大小限制。" });
    finishProcess(1);
    return;
  }
  while (true) {
    const newline = inputBuffer.indexOf(0x0a);
    if (newline < 0) break;
    const lineBuffer = inputBuffer.subarray(0, newline);
    inputBuffer = inputBuffer.subarray(newline + 1);
    if (lineBuffer.length > MAX_LINE_BYTES) {
      emit({ type: "protocol_error", message: "认证请求单行超过安全大小限制。" });
      finishProcess(1);
      return;
    }
    const line = lineBuffer.toString("utf8").replace(/\r$/u, "");
    if (line.length > 0) handleInputLine(line);
  }
});

process.stdin.on("end", () => {
  if (activeOperation) {
    activeOperation.controller.abort();
    rejectPendingPrompts(new Error("认证桥接输入已关闭。"));
    finishProcess(2, 1_500);
  } else {
    finishProcess(0);
  }
});

process.on("SIGTERM", () => {
  if (activeOperation) {
    activeOperation.controller.abort();
    rejectPendingPrompts(new Error("Login cancelled"));
    finishProcess(2, 1_500);
  } else {
    finishProcess(2);
  }
});
