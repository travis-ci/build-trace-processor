require 'sinatra'
require 'aws-sdk-s3'
require 'opencensus'
require 'opencensus/stackdriver'


def json_params
    begin
        JSON.parse(request.body.read)
    rescue
        halt 400, { message:'Invalid JSON' }.to_json
    end
end

def s3
    @s3 ||= Aws::S3::Client.new
end

def process_span(job_id, span_context, trace_json)
    span = span_context.start_span trace_json['name'], skip_frames: 2
    span.put_attribute "app", "build"
    span.put_attribute "job_id", job_id
    span.start_time = Time.parse(trace_json['start_time'])
    span.end_time = Time.parse(trace_json['end_time'])
end

def s3_trace(job_id)
    obj = s3.get_object(bucket: ENV['S3_BUCKET'], key: "trace/#{job_id}")
    obj.body.read
end


# Setup

Aws.config.update({
    region: 'us-east-1',
    credentials: Aws::Credentials.new(ENV['S3_ACCESS_KEY_ID'], ENV['S3_SECRET_ACCESS_KEY'])
})

# Endpoints:

get '/' do
    'Welcome to the Travis Build Trace Processor'
end

post '/trace' do
    OpenCensus.configure do |c|
        c.trace.exporter = OpenCensus::Trace::Exporters::Stackdriver.new
        c.trace.default_sampler = OpenCensus::Trace::Samplers::AlwaysSample.new
    end

    job_id = json_params["job_id"]
    tracefile = s3_trace(job_id)

    # create new trace
    max_trace_id = OpenCensus::Trace::SpanContext::MAX_TRACE_ID
    trace_id = rand 1..max_trace_id
    trace_id = trace_id.to_s(16).rjust(32, "0")
    context = OpenCensus::Trace::TraceContextData.new(trace_id, '', 0x01)

    OpenCensus::Trace.start_request_trace \
    trace_context: context,
    same_process_as_parent: false do |span_context|
        tracefile.each_line do |line|
            process_span(job_id, span_context, JSON.parse(line))
        end
        OpenCensus::Trace.config.exporter.export(span_context.build_contained_spans)
    end
end
