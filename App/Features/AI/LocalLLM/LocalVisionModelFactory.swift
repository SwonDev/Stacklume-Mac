import MLXVLM

enum LocalVisionModelFactory {
    // MiMo conserva un preprocessor_config compatible, pero omite processor_class.
    // El resolver se limita a esta factory de Qwen3.5; no altera pesos ni archivos del usuario.
    static let shared = VLMModelFactory(
        typeRegistry: VLMTypeRegistry.shared,
        processorRegistry: VLMProcessorTypeRegistry.shared,
        modelRegistry: VLMRegistry.shared,
        processorLoadingRegistry: VLMProcessorLoadingRegistry(resolvers: [
            Qwen35ProcessorLoadingResolver(),
            ModelTypeProcessorResolver(processorTypes: ["qwen3_5": "Qwen3VLProcessor"])
        ])
    )
}
