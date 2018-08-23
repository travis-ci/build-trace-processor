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

def process_span(job_id, trace_id, trace_json)
    builder = OpenCensus::Trace::SpanBuilder::PieceBuilder.new 
    span_name = builder.truncatable_string(trace_json['name'])
    status = builder.convert_status(trace_json['status'], "")
    attributes = builder.convert_attributes({"app"=>"build_test", "job_id"=>job_id})
    return OpenCensus::Trace::Span.new trace_id, trace_json['id'], span_name, Time.at(trace_json['start_time'].to_i*1e-9), Time.at(trace_json['end_time'].to_i*1e-9), parent_span_id: trace_json['parent_id'], attributes: attributes, status: status
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
    spans = []
    tracefile.each_line do |line|
        spans << process_span(job_id, trace_id, JSON.parse(line))
    end
    OpenCensus::Trace.config.exporter.export spans
end
