import Foundation

enum TranslationProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case openAI, anthropic, glm, openRouter, volcengine, deepSeek, custom

    var id: String { rawValue }
    var title: String {
        switch self {
        case .openAI: "OpenAI"
        case .anthropic: "Claude（Anthropic）"
        case .glm: "智谱 GLM"
        case .openRouter: "OpenRouter"
        case .volcengine: "火山引擎（方舟）"
        case .deepSeek: "DeepSeek"
        case .custom: "自定义服务"
        }
    }

    var baseURL: String {
        switch self {
        case .openAI: "https://api.openai.com/v1"
        case .anthropic: "https://api.anthropic.com/v1"
        case .glm: "https://open.bigmodel.cn/api/paas/v4"
        case .openRouter: "https://openrouter.ai/api/v1"
        case .volcengine: "https://ark.cn-beijing.volces.com/api/v3"
        case .deepSeek: "https://api.deepseek.com"
        case .custom: ""
        }
    }

    var apiFormat: TranslationAPIFormat { self == .anthropic ? .anthropic : .openAI }

    /// A small editable catalog, not a promise of account entitlement or measured latency.
    var models: [String] {
        switch self {
        case .openAI: ["gpt-4.1-mini", "gpt-4.1", "gpt-4o-mini"]
        case .anthropic: ["claude-haiku-4-5-20251001", "claude-sonnet-4-6"]
        case .glm: ["glm-4.7-flash", "glm-4.7", "glm-5.2"]
        case .openRouter: ["openai/gpt-4.1-mini", "anthropic/claude-haiku-4.5", "deepseek/deepseek-v4-flash"]
        case .volcengine: ["doubao-seed-2-0-mini-260215"]
        case .deepSeek: ["deepseek-v4-flash", "deepseek-v4-pro"]
        case .custom: []
        }
    }

    var note: String {
        switch self {
        case .volcengine:
            "预设为方舟通用 API，并非 Coding Plan。请先开通模型；也可填控制台的 ep- 接入点 ID。"
        case .glm:
            "预设为智谱中国站通用 API，并非 Coding Plan。套餐地址与适用场景不同，请按官方说明配置。"
        case .anthropic:
            "使用 Anthropic 原生 Messages 接口，需要 Claude API Key；聊天订阅不等同于 API 额度。"
        case .openRouter:
            "使用 OpenRouter 的 Key；模型 ID 需要保留 openai/、anthropic/ 等前缀。"
        case .custom:
            "支持兼容服务和本机服务。选择匹配的接口格式，模型名称可自由输入。"
        default:
            "预置模型仅供快捷填写，实际可用模型及费用以服务商账户为准。"
        }
    }
}

/// Non-secret settings only. Keys live in a separate, restricted local file.
struct ModelTranslationProfile: Codable, Equatable, Sendable {
    var baseURL: String
    var model: String
    var apiFormat: TranslationAPIFormat
    var streamsResponse: Bool
    var optimizesForTranslation: Bool
    var prompt: String

    init(provider: TranslationProvider) {
        baseURL = provider.baseURL
        model = provider.models.first ?? ""
        apiFormat = provider.apiFormat
        streamsResponse = true
        optimizesForTranslation = true
        prompt = ModelTranslationConfiguration.defaultPrompt
    }

    init(configuration: ModelTranslationConfiguration) {
        baseURL = configuration.baseURL
        model = configuration.model
        apiFormat = configuration.apiFormat
        streamsResponse = configuration.streamsResponse
        optimizesForTranslation = configuration.optimizesForTranslation
        prompt = configuration.prompt
    }
}
