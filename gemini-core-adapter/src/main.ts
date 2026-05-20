import readline from "node:readline";
import { randomUUID } from "node:crypto";
import {
  AuthType,
  DEFAULT_MODEL_CONFIGS,
  GEMINI_MODEL_ALIAS_FLASH,
  GEMINI_MODEL_ALIAS_FLASH_LITE,
  GEMINI_MODEL_ALIAS_AUTO,
  GEMINI_MODEL_ALIAS_PRO,
  LlmRole,
  ModelConfigService,
  createCodeAssistContentGenerator,
  getChannelFromVersion,
  getVersion,
  isPreviewModel,
  resolveModel,
  type CodeAssistServer,
  type ContentGenerator,
} from "@google/gemini-cli-core";

interface JsonRpcRequest {
  id?: string | number | null;
  method?: string;
  params?: unknown;
}

interface JsonRpcError {
  code: number;
  message: string;
  data?: Record<string, unknown>;
}

interface GenerateParams {
  prompt: string;
  model?: string;
}

interface GeminiModelInfo {
  id: string;
  name: string;
  description: string;
  tier: string;
  source: "gemini-cli-core";
  quota?: {
    remainingAmount?: number;
    remainingFraction?: number;
    resetTime?: string;
  };
}

interface CoreState {
  generator: ContentGenerator;
  modelConfigService: ModelConfigService;
  config: Record<string, unknown>;
  releaseChannel: string;
}

type GeminiModelOption = ReturnType<ModelConfigService["getAvailableModelOptions"]>[number];

let statePromise: Promise<CoreState> | undefined;
let quotaPromise: Promise<Map<string, GeminiModelInfo["quota"]>> | undefined;

const MODEL_ALIAS_FALLBACK_TIERS: Record<string, string[]> = {
  [GEMINI_MODEL_ALIAS_AUTO]: ["pro", "flash", "flash-lite"],
  [GEMINI_MODEL_ALIAS_PRO]: ["pro", "flash", "flash-lite"],
  [GEMINI_MODEL_ALIAS_FLASH]: ["flash", "flash-lite"],
  [GEMINI_MODEL_ALIAS_FLASH_LITE]: ["flash-lite"],
  "auto-gemini-3": ["pro", "flash", "flash-lite"],
  "auto-gemini-2.5": ["pro", "flash", "flash-lite"],
};

const TIER_PRIORITY: Record<string, number> = {
  pro: 0,
  flash: 1,
  "flash-lite": 2,
  custom: 3,
};

function minimalGeminiConfig(
  modelConfigService: ModelConfigService,
  releaseChannel: string,
): Record<string, unknown> {
  return {
    modelConfigService,
    getProxy: () => undefined,
    isBrowserLaunchSuppressed: () => true,
    isInteractive: () => false,
    getAcpMode: () => false,
    getValidationHandler: () => undefined,
    getUsageStatisticsEnabled: () => false,
    getContentGeneratorConfig: () => ({ authType: AuthType.LOGIN_WITH_GOOGLE }),
    getModel: () => GEMINI_MODEL_ALIAS_AUTO,
    getActiveModel: () => GEMINI_MODEL_ALIAS_AUTO,
    getClientName: () => "soa",
    getExperimentalDynamicModelConfiguration: () => true,
    getReleaseChannel: () => releaseChannel,
    getGemini31LaunchedSync: () => false,
    getGemini31FlashLiteLaunchedSync: () => false,
    getUseCustomToolModelSync: () => false,
    getHasAccessToPreviewModel: () => false,
  };
}

async function getState(): Promise<CoreState> {
  if (!statePromise) {
    process.env.GOOGLE_GENAI_USE_GCA = "true";
    const version = await getVersion();
    const releaseChannel = getChannelFromVersion(version);
    const modelConfigService = new ModelConfigService(DEFAULT_MODEL_CONFIGS);
    const config = minimalGeminiConfig(modelConfigService, releaseChannel);
    statePromise = createCodeAssistContentGenerator(
      {},
      AuthType.LOGIN_WITH_GOOGLE,
      config as never,
      `soa-gemini-${process.pid}`,
    ).then((generator) => ({ generator, modelConfigService, config, releaseChannel }));
  }
  return statePromise;
}

function asCodeAssistServer(generator: ContentGenerator): CodeAssistServer | undefined {
  const candidate = generator as Partial<CodeAssistServer>;
  if (candidate.projectId && typeof candidate.retrieveUserQuota === "function") {
    return candidate as CodeAssistServer;
  }
  return undefined;
}

async function getQuotaByModel(state: CoreState): Promise<Map<string, GeminiModelInfo["quota"]>> {
  if (!quotaPromise) {
    quotaPromise = (async () => {
      const server = asCodeAssistServer(state.generator);
      const quotaByModel = new Map<string, GeminiModelInfo["quota"]>();
      if (!server?.projectId) {
        return quotaByModel;
      }
      const quota = await server.retrieveUserQuota({ project: server.projectId });
      for (const bucket of quota.buckets ?? []) {
        if (!bucket.modelId) {
          continue;
        }
        quotaByModel.set(bucket.modelId, {
          remainingAmount:
            typeof bucket.remainingAmount === "string"
              ? Number.parseInt(bucket.remainingAmount, 10)
              : undefined,
          remainingFraction: bucket.remainingFraction,
          resetTime: bucket.resetTime,
        });
      }
      return quotaByModel;
    })().catch(() => new Map<string, GeminiModelInfo["quota"]>());
  }
  return quotaPromise;
}

async function hasPreviewAccess(state: CoreState): Promise<boolean> {
  const quotaByModel = await getQuotaByModel(state);
  for (const modelId of quotaByModel.keys()) {
    if (isPreviewModel(modelId, state.config as never)) {
      return true;
    }
  }
  return false;
}

async function resolveRequestedModel(
  state: CoreState,
  requestedModel: string | undefined,
): Promise<string> {
  const model = requestedModel?.trim() || process.env.GEMINI_MODEL?.trim() || GEMINI_MODEL_ALIAS_AUTO;
  return resolveModel(
    model,
    false,
    false,
    false,
    await hasPreviewAccess(state),
    state.config as never,
    state.releaseChannel,
  );
}

function requestedModelAlias(requestedModel: string | undefined): string {
  return requestedModel?.trim() || process.env.GEMINI_MODEL?.trim() || GEMINI_MODEL_ALIAS_AUTO;
}

function isConcreteModelRequest(model: string): boolean {
  return !Object.prototype.hasOwnProperty.call(MODEL_ALIAS_FALLBACK_TIERS, model);
}

function quotaRank(quota: GeminiModelInfo["quota"] | undefined): number {
  if (quota?.remainingFraction === undefined) {
    return 1;
  }
  return quota.remainingFraction > 0 ? 0 : 2;
}

function modelOptionRank(
  state: CoreState,
  quotaByModel: Map<string, GeminiModelInfo["quota"]>,
  option: GeminiModelOption,
): number[] {
  const isPreview = isPreviewModel(option.modelId, state.config as never) ? 1 : 0;
  const tier = TIER_PRIORITY[option.tier] ?? TIER_PRIORITY.custom;
  const quota = quotaByModel.get(option.modelId);
  return [isPreview, tier, quotaRank(quota), -(quota?.remainingFraction ?? -1)];
}

function compareModelOptions(
  state: CoreState,
  quotaByModel: Map<string, GeminiModelInfo["quota"]>,
  left: GeminiModelOption,
  right: GeminiModelOption,
): number {
  const leftRank = modelOptionRank(state, quotaByModel, left);
  const rightRank = modelOptionRank(state, quotaByModel, right);
  for (let index = 0; index < leftRank.length; index += 1) {
    const delta = leftRank[index] - rightRank[index];
    if (delta !== 0) {
      return delta;
    }
  }
  return left.modelId.localeCompare(right.modelId);
}

async function generateModelCandidates(
  state: CoreState,
  requestedModel: string | undefined,
): Promise<string[]> {
  const alias = requestedModelAlias(requestedModel);
  const resolved = await resolveRequestedModel(state, requestedModel);
  if (isConcreteModelRequest(alias)) {
    return [resolved];
  }

  const quotaByModel = await getQuotaByModel(state);
  const allowedTiers = new Set(MODEL_ALIAS_FALLBACK_TIERS[alias] ?? MODEL_ALIAS_FALLBACK_TIERS.auto);
  const hasAccessToPreview = await hasPreviewAccess(state);
  const candidates = state.modelConfigService
    .getAvailableModelOptions({
      releaseChannel: state.releaseChannel,
      hasAccessToPreview,
    })
    .filter((option) => option.tier !== "auto")
    .filter((option) => allowedTiers.has(option.tier))
    .filter((option) => quotaByModel.get(option.modelId)?.remainingFraction !== 0)
    .sort((left, right) => compareModelOptions(state, quotaByModel, left, right))
    .map((option) => option.modelId);

  return [...new Set([resolved, ...candidates])];
}

function shouldTryFallback(error: unknown): boolean {
  const code =
    typeof error === "object" && error && "code" in error
      ? Number((error as { code?: unknown }).code)
      : NaN;
  const message = error instanceof Error ? error.message : String(error);
  return (
    code === 429 ||
    /\b(capacity|quota|rate limit|rate-limit|exhausted)\b/i.test(message)
  );
}

function retryDelayMs(error: unknown): number | undefined {
  const message = error instanceof Error ? error.message : String(error);
  const match = message.match(/\b(?:retry in|reset after)\s+(\d+(?:\.\d+)?)\s*(ms|s|m)\b/i);
  if (!match) {
    return undefined;
  }
  const amount = Number.parseFloat(match[1]);
  if (!Number.isFinite(amount)) {
    return undefined;
  }
  switch (match[2].toLowerCase()) {
    case "ms":
      return amount;
    case "s":
      return amount * 1000;
    case "m":
      return amount * 60_000;
    default:
      return undefined;
  }
}

async function sleep(ms: number): Promise<void> {
  await new Promise((resolve) => setTimeout(resolve, ms));
}

function asGenerateParams(params: unknown): GenerateParams {
  if (!params || typeof params !== "object") {
    throw new Error("generate params must be an object");
  }
  const value = params as { prompt?: unknown; model?: unknown };
  if (typeof value.prompt !== "string" || value.prompt.trim().length === 0) {
    throw new Error("generate params.prompt must be a non-empty string");
  }
  const model = typeof value.model === "string" ? value.model.trim() : undefined;
  return { prompt: value.prompt, model };
}

function responseText(response: unknown): string {
  const candidate = (
    response as { candidates?: Array<{ content?: { parts?: Array<{ text?: string }> } }> }
  ).candidates?.[0];
  const parts = candidate?.content?.parts ?? [];
  return parts
    .map((part) => (typeof part.text === "string" ? part.text : ""))
    .join("");
}

async function handle(request: JsonRpcRequest): Promise<unknown> {
  switch (request.method) {
    case "generate": {
      const params = asGenerateParams(request.params);
      const state = await getState();
      const models = await generateModelCandidates(state, params.model);
      let lastError: unknown;
      for (const [index, model] of models.entries()) {
        try {
          const response = await state.generator.generateContent(
            {
              model,
              contents: params.prompt,
            },
            randomUUID(),
            LlmRole.MAIN,
          );

          return {
            text: responseText(response),
            provider: "gemini-cli-core",
            model,
          };
        } catch (error) {
          let currentError = error;
          const delayMs = retryDelayMs(error);
          if (delayMs !== undefined && delayMs <= 10_000) {
            await sleep(delayMs + 250);
            try {
              const response = await state.generator.generateContent(
                {
                  model,
                  contents: params.prompt,
                },
                randomUUID(),
                LlmRole.MAIN,
              );

              return {
                text: responseText(response),
                provider: "gemini-cli-core",
                model,
              };
            } catch (retryError) {
              currentError = retryError;
            }
          }
          lastError = currentError;
          if (index === models.length - 1 || !shouldTryFallback(currentError)) {
            throw currentError;
          }
        }
      }
      throw lastError;
    }
    case "models": {
      const state = await getState();
      const quotaByModel = await getQuotaByModel(state);
      const hasAccessToPreview = await hasPreviewAccess(state);
      const models: GeminiModelInfo[] = state.modelConfigService
        .getAvailableModelOptions({
          releaseChannel: state.releaseChannel,
          hasAccessToPreview,
        })
        .map((model) => ({
          id: model.modelId,
          name: model.name,
          description: model.description,
          tier: model.tier,
          source: "gemini-cli-core",
          quota: quotaByModel.get(model.modelId),
        }));
      return {
        provider: "gemini-cli-core",
        releaseChannel: state.releaseChannel,
        models,
      };
    }
    default:
      throw Object.assign(new Error(`unsupported method: ${String(request.method)}`), {
        code: -32601,
      });
  }
}

function toError(error: unknown): JsonRpcError {
  const maybeCode =
    typeof error === "object" && error && "code" in error
      ? Number((error as { code?: unknown }).code)
      : NaN;
  const message = error instanceof Error ? error.message : String(error);
  return {
    code: Number.isFinite(maybeCode) ? maybeCode : -32000,
    message,
    data: error instanceof Error ? { name: error.name } : undefined,
  };
}

async function main(): Promise<void> {
  const lines = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
  for await (const line of lines) {
    if (!line.trim()) {
      continue;
    }
    let request: JsonRpcRequest;
    try {
      request = JSON.parse(line) as JsonRpcRequest;
    } catch (error) {
      process.stdout.write(JSON.stringify({ id: null, error: toError(error) }) + "\n");
      continue;
    }

    try {
      const result = await handle(request);
      process.stdout.write(JSON.stringify({ id: request.id ?? null, result }) + "\n");
    } catch (error) {
      process.stdout.write(JSON.stringify({ id: request.id ?? null, error: toError(error) }) + "\n");
    }
  }
}

main().catch((error: unknown) => {
  process.stdout.write(JSON.stringify({ id: null, error: toError(error) }) + "\n");
  process.exitCode = 1;
});
