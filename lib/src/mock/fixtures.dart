// Recorded-format SSE samples, hand-written from the providers' documented
// event shapes (not copied model output). The same bytes live in
// fixtures/sse/*.sse for reading; test/usage_tap_test.dart checks both copies
// are identical. They are embedded here so `demo` and `serve --mock` also
// work from a compiled executable or a Docker image.

const String openaiChatSse =
    r'''data: {"id":"chatcmpl-mock1","object":"chat.completion.chunk","created":1731542400,"model":"gpt-4o-mini","choices":[{"index":0,"delta":{"role":"assistant","content":"Hello"},"finish_reason":null}],"usage":null}

data: {"id":"chatcmpl-mock1","object":"chat.completion.chunk","created":1731542400,"model":"gpt-4o-mini","choices":[{"index":0,"delta":{"content":" from"},"finish_reason":null}],"usage":null}

data: {"id":"chatcmpl-mock1","object":"chat.completion.chunk","created":1731542400,"model":"gpt-4o-mini","choices":[{"index":0,"delta":{"content":" the mock"},"finish_reason":null}],"usage":null}

data: {"id":"chatcmpl-mock1","object":"chat.completion.chunk","created":1731542400,"model":"gpt-4o-mini","choices":[{"index":0,"delta":{"content":" upstream."},"finish_reason":"stop"}],"usage":null}

data: {"id":"chatcmpl-mock1","object":"chat.completion.chunk","created":1731542400,"model":"gpt-4o-mini","choices":[],"usage":{"prompt_tokens":9,"completion_tokens":4,"total_tokens":13}}

data: [DONE]

''';

const String anthropicMessagesSse = r'''event: message_start
data: {"type":"message_start","message":{"id":"msg_mock1","type":"message","role":"assistant","content":[],"model":"claude-mock","stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":25,"output_tokens":1}}}

event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

event: ping
data: {"type":"ping"}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" from the mock upstream."}}

event: content_block_stop
data: {"type":"content_block_stop","index":0}

event: message_delta
data: {"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":15}}

event: message_stop
data: {"type":"message_stop"}

''';

const String geminiStreamSse =
    r'''data: {"candidates":[{"content":{"parts":[{"text":"Hello"}],"role":"model"},"index":0}],"usageMetadata":{"promptTokenCount":8,"candidatesTokenCount":1,"totalTokenCount":9},"modelVersion":"gemini-mock"}

data: {"candidates":[{"content":{"parts":[{"text":" from the"}],"role":"model"},"index":0}],"usageMetadata":{"promptTokenCount":8,"candidatesTokenCount":3,"totalTokenCount":11},"modelVersion":"gemini-mock"}

data: {"candidates":[{"content":{"parts":[{"text":" mock upstream."}],"role":"model"},"finishReason":"STOP","index":0}],"usageMetadata":{"promptTokenCount":8,"candidatesTokenCount":5,"totalTokenCount":13},"modelVersion":"gemini-mock"}

''';
