# Third-party software and models

Murmur for Windows uses the following open-source projects. Their license files
are distributed beside this document in packaged builds.

- .NET / WPF / Windows Forms — Microsoft, MIT: https://github.com/dotnet/runtime
- NAudio 2.2.1 — Mark Heath and contributors, MIT: https://github.com/naudio/NAudio
- Whisper.net 1.9.1 — Sandro Hanea and contributors, MIT: https://github.com/sandrohanea/whisper.net
- whisper.cpp — ggml contributors, MIT: https://github.com/ggml-org/whisper.cpp
- Whisper models — OpenAI, MIT: https://github.com/openai/whisper
- LLamaSharp 0.26.0 — SciSharp and contributors, MIT: https://github.com/SciSharp/LLamaSharp
- llama.cpp — ggml contributors, MIT: https://github.com/ggml-org/llama.cpp
- Qwen2.5 1.5B Instruct (optional model) — Alibaba Cloud, Apache 2.0: https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct

The installer includes Microsoft's separately licensed Visual C++ Redistributable,
downloaded from Microsoft and checked for a valid Microsoft Authenticode signature
during packaging. Model weights are downloaded only when requested by the user.
