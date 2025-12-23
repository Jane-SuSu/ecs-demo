from flask import Flask, request, jsonify
import requests
import os

# --- OpenTelemetry Imports ---
from opentelemetry import trace
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.flask import FlaskInstrumentor
from opentelemetry.instrumentation.requests import RequestsInstrumentor
from opentelemetry.sdk.resources import SERVICE_NAME, Resource
# AWS X-Ray ID Generator is crucial for X-Ray compatibility
from opentelemetry.sdk.extension.aws.trace import AwsXRayIdGenerator

# 1. 設定 Resource (Service Name)
resource = Resource(attributes={
    SERVICE_NAME: "world-service"
})

# 2. 設定 Provider 使用 AWS X-Ray ID Generator
provider = TracerProvider(
    resource=resource,
    id_generator=AwsXRayIdGenerator()
)

# 3. 設定 Exporter 指向 Sidecar (ADOT)
# ADOT Sidecar 預設在 localhost:4317 監聽 gRPC
otlp_exporter = OTLPSpanExporter(endpoint=os.environ.get("OTEL_EXPORTER_OTLP_ENDPOINT", "http://localhost:4317"), insecure=True)
processor = BatchSpanProcessor(otlp_exporter)
provider.add_span_processor(processor)

# 4. 套用設定
trace.set_tracer_provider(provider)

app = Flask(__name__)

# 5. 自動 Instrument Flask 和 Requests
FlaskInstrumentor().instrument_app(app)
RequestsInstrumentor().instrument()
# -----------------------------

HELLO_SERVICE_URL = os.environ.get("HELLO_SERVICE_URL")

@app.route('/')
def index():
    return "Welcome to World Service"

@app.route('/world')
def world():
    # 可以在 span 裡加自定義屬性
    tracer = trace.get_tracer(__name__)
    with tracer.start_as_current_span("world-operation"):
        return "world"

@app.route('/test')
def test():
    try:
        # RequestsInstrumentor 會自動把 Trace Context 注入到這裡的 Header
        response = requests.get(HELLO_SERVICE_URL + "/hello")
        hello_response = response.text
        return f"world {hello_response}"
    except requests.RequestException as e:
        return f"Error calling hello service: {str(e)}", 500

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5001, debug=True)
