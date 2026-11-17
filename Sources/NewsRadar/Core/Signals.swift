import Foundation

/// Keyword tables behind "is this free / open source / local / Apple Silicon",
/// the category classifier and the boolean filters.
///
/// Everything here is plain lowercase English because that is what the feeds
/// publish. Keeping the tables in one file makes them testable from
/// `--selftest` and easy to extend without touching the classifier logic.
enum Signals {

    // MARK: - Category

    static let category: [Category: [String]] = [
        .llm: ["llm", "language model", "gpt", "claude", "gemini", "grok", "llama",
               "qwen", "deepseek", "mistral", "mixtral", "phi", "gemma", "model release",
               "frontier model", "chatbot", "context window", "parameters", "reasoning model",
               "multimodal", "foundation model", "tokenizer", "benchmark",
               "artificial intelligence model"],
        .agent: ["agent", "agents", "agentic", "autonomous", "computer use", "browser agent",
                 "tool use", "mcp", "workflow automation", "copilot agent", "multi-agent",
                 "orchestration", "a2a", "swarm"],
        .coding: ["coding", "code", "developer", "developers", "programming", "ide",
                  "code editor", "copilot", "cursor", "pull request", "refactor",
                  "repository", "repo", "typescript", "python library", "compiler",
                  "debug", "test generation", "vibe coding", "cli tool"],
        .imageVideo: ["image", "video", "photo", "graphics", "motion", "animation",
                      "render", "diffusion", "stable diffusion", "midjourney", "sora",
                      "flux", "comfyui", "upscale", "background removal", "3d model",
                      "text to video", "text to image", "image editing", "vfx",
                      "design tool", "poster", "thumbnail", "avatar",
                      "image generation", "video generation", "image model", "video model",
                      "generative video", "image generator", "video editor", "photo editing",
                      "image editor", "visual effects", "motion graphics", "storyboard",
                      "generated image", "generated video", "image synthesis",
                      "video synthesis"],
        .audio: ["audio", "voice", "speech", "music", "tts", "text to speech",
                 "transcription", "whisper", "podcast", "song", "dubbing", "sound"],
        .localLLM: ["local", "offline", "on-device", "llama.cpp", "ollama", "lm studio",
                    "gguf", "quantization", "quantized", "self-hosted", "self hosted",
                    "run locally", "mlx", "on your mac"],
        .hardware: ["chip", "gpu", "tpu", "npu", "silicon", "datacenter", "data center",
                    "server", "supercomputer", "cluster", "h100", "b200", "gb200",
                    "m4", "m5", "neural engine", "memory bandwidth", "fab", "wafer"],
        .research: ["paper", "arxiv", "research", "study", "benchmark", "evaluation",
                    "state of the art", "sota", "neurips", "icml", "iclr", "dataset",
                    "ablation", "preprint", "lab"],
        .business: ["funding", "raises", "valuation", "ipo", "acquisition", "acquires",
                    "revenue", "earnings", "market cap", "partnership", "investors",
                    "series a", "series b", "seed round", "layoffs", "hiring", "pricing"],
        .policy: ["regulation", "regulator", "law", "lawsuit", "court", "copyright",
                  "antitrust", "ban", "compliance", "eu ai act", "policy", "senate",
                  "congress", "privacy law", "safety institute", "executive order"],
        .tools: ["app", "tool", "platform", "assistant", "workspace", "saas",
                 "dashboard", "extension", "plugin", "api", "productivity",
                 "note taking", "presentation", "spreadsheet", "automation tool"]
    ]

    /// Single generic nouns that give a category a nudge but must never decide it
    /// on their own: they count as a tie-breaker (weight 1) instead of a phrase.
    /// Without this, "per token pricing" would classify paid image news as
    /// `business`.
    static let weak: Set<String> = [
        "api", "app", "tool", "image", "video", "photo", "model", "models", "code",
        "coding", "local", "agent", "audio", "memory", "search", "render", "motion",
        "design", "chip", "server", "data", "voice", "music", "robot", "ide",
        "pricing", "market", "ban", "law", "court", "policy", "developer",
        "developers", "report", "study", "test", "research", "paper", "llama",
        "gemini", "claude", "grok", "chatbot", "repository", "repo", "lab",
        "benchmark", "productivity", "automation", "extension", "plugin"
    ]

    // MARK: - Feature flags

    /// Words that mark an item as a paid/closed API rather than a free tool.
    static let paidAPI: [String] = [
        "api pricing", "per token", "per-token", "pay as you go", "pay-as-you-go",
        "enterprise plan", "paid plan", "subscription required", "usage based pricing",
        "commercial license", "api access", "credits required", "billed", "pricing tier"
    ]

    /// Words that mark an item as open source.
    static let openSource: [String] = [
        "open source", "open-source", "opensource", "open sourced", "open-sourced",
        "mit license", "apache 2.0", "apache-2.0", "gpl", "bsd license", "github.com",
        "repository", "source code", "open weights", "public repo", "self-hosted"
    ]

    /// Words that mark an item as free of charge.
    static let free: [String] = [
        "free", "free tier", "free to use", "no cost", "open weights", "open-source",
        "gratis", "free download", "community edition", "free plan", "free and open"
    ]

    /// Words that mark local / on-device execution.
    /// Phrases that mean the model really runs on the reader's own machine.
    ///
    /// The bare word "local" is deliberately absent: press releases use it in
    /// unrelated senses ("local celebration", "local market"), which wrongly
    /// labelled hardware announcements as running locally on this Mac.
    static let local: [String] = [
        "runs locally", "run locally", "running locally", "locally hosted",
        "locally on your", "local inference", "local model", "local models",
        "offline", "runs offline", "works offline", "fully offline", "offline mode",
        "on-device", "on device", "on your machine", "on your own machine",
        "llama.cpp", "ollama", "lm studio", "gguf", "mlx", "self-hosted",
        "self hosted", "run on your mac", "no cloud", "privacy-first", "air-gapped"
    ]

    /// Words that mark Apple Silicon compatibility.
    static let appleSilicon: [String] = [
        "apple silicon", "m1", "m2", "m3", "m4", "m5", "macos", "mac os",
        "mac studio", "mac mini", "macbook", "mlx", "core ml", "coreml",
        "metal acceleration", "neural engine", "unified memory", "arm mac", "apple gpu"
    ]

    /// Words that mean "this needs a proprietary backend", used to clear `free`
    /// even when the copy says "free trial".
    static let closedSignals: [String] = [
        "proprietary", "closed source", "commercial license only"
    ]

    /// Filename tokens that mark an image as a publication's branding rather than
    /// a story illustration, so it is never used as an article image. Matched
    /// against whole tokens, not substrings, so `silicon-valley.jpg` survives.
    static let brandingImageNames: Set<String> = [
        "logo", "logotype", "icon", "favicon", "brand", "branding", "sprite",
        "avatar", "default", "placeholder", "rss", "opengraph", "share"
    ]

    /// Vocabulary a Hacker News story must hit to enter the radar. HN publishes
    /// everything from politics to gardening, so without this gate the community
    /// sources would dominate the feed with stories the app does not cover.
    static let technicalTerms: Set<String> = [
        "ai", "llm", "llms", "gpt", "model", "models", "neural", "transformer",
        "machine learning", "deep learning", "inference", "training", "fine-tune",
        "fine-tuning", "quantization", "quantized", "gguf", "lora", "embedding",
        "embeddings", "diffusion", "stable diffusion", "midjourney", "llama",
        "mistral", "qwen", "deepseek", "gemma", "claude", "chatgpt", "openai",
        "anthropic", "gemini", "copilot", "cursor", "agent", "agents", "agentic",
        "rag", "vector database", "tokenizer", "cuda", "gpu", "tensor", "pytorch",
        "tensorflow", "onnx", "whisper", "tts", "speech", "vision",
        "open source", "open-source", "rust", "python", "compiler", "database",
        "api", "sdk", "cli", "developer", "devtool", "devtools", "programming",
        "software", "framework", "library", "server", "self-hosted", "docker",
        "linux", "kubernetes", "webassembly", "wasm", "terminal", "editor",
        "localhost", "on-device", "local model", "apple silicon", "m-series",
        "benchmark", "benchmarks", "latency", "throughput", "quantize", "vram",
        "chatbot", "prompt", "prompts", "prompting", "fine tuned", "dataset"
    ]

    /// Product/launch shapes that make a Show HN post a real item even when it
    /// names no model (a tool, an app, a service).
    static let launchTerms: Set<String> = [
        "show hn", "launch", "launched", "release", "released", "introducing",
        "open source", "open-source", "i built", "we built", "i made", "v1",
        "beta", "alpha", "self-hosted", "now available"
    ]

    /// Bodies that are a publishing placeholder rather than prose. Feeds publish
    /// these before an article body exists, and quoting one would show "TBD" as
    /// the summary of a card.
    static let placeholderBodies: Set<String> = [
        "tbd", "tba", "coming soon", "stay tuned", "more soon", "n/a", "na",
        "no description", "no description provided", "read more", "link"
    ]

    // MARK: - Tags

    /// Tag label plus the signals that trigger it, in display order.
    static let tagGroups: [(label: String, signals: [String])] = [
        ("open source", Signals.openSource),
        ("free", ["free", "free tier", "open weights"]),
        ("local", Signals.local),
        ("Apple Silicon", Signals.appleSilicon),
        ("multimodal", ["multimodal", "vision", "image understanding"]),
        ("reasoning", ["reasoning", "chain of thought", "thinking"]),
        ("coding tool", ["coding agent", "code editor", "copilot", "ide"]),
        ("image", ["image generation", "image editing", "text to image", "diffusion"]),
        ("video", ["video generation", "text to video", "image to video"]),
        ("motion graphics", ["motion graphics", "animation", "after effects", "motion design"]),
        ("audio", ["voice", "speech", "audio", "music"]),
        ("enterprise", ["enterprise", "on-prem", "on prem"]),
        ("mobile", ["ios", "android", "iphone", "mobile app"]),
        ("Apple", ["apple", "siri", "macos", "vision pro"]),
        ("regulation", ["regulation", "lawsuit", "copyright", "ban"]),
        ("funding", ["funding", "raises", "valuation", "ipo"]),
        ("benchmark", ["benchmark", "sota", "state of the art"]),
        ("paid API", Signals.paidAPI)
    ]
}
