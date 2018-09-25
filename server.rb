require 'sinatra'
require 'aws-sdk-s3'
require "logger"
require 'opencensus'
require 'opencensus/stackdriver'


log = Logger.new(STDOUT)
log.level = Logger::WARN

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

def coalesce_spans(tracefile)
    spans = {}
    spans.default = {}
    tracefile.each_line do |line|
        span = JSON.parse(line)
        spans[span['id']] = spans[span['id']].merge(span)
    end
    return spans
end

def process_span(job_id, trace_id, span)
    builder = OpenCensus::Trace::SpanBuilder::PieceBuilder.new
    if span['name'] == 'root'
        span_name = builder.truncatable_string(job_id.to_s)
    else
        span_name = builder.truncatable_string(span['name'])
    end
    status = builder.convert_status(span['status'], "")
    attributes = builder.convert_attributes({"app"=>"build", "job_id"=>job_id})
    return OpenCensus::Trace::Span.new trace_id, span['id'], span_name, Time.at(span['start_time'].to_i*1e-9), Time.at(span['end_time'].to_i*1e-9), parent_span_id: span['parent_id'], attributes: attributes, status: status
end

def s3_trace(job_id)
    obj = s3.get_object(bucket: ENV['S3_BUCKET'], key: "trace/#{job_id}")
    obj.body.read
end

# Endpoints:

if ENV['AUTH_TOKEN']
  use Rack::Auth::Basic, "Protected Area" do |username, password|
    Rack::Utils.secure_compare(password, ENV['AUTH_TOKEN'])
  end
end

get '/' do
    'Welcome to the Travis Build Trace Processor'
end

post '/trace' do
    OpenCensus.configure do |c|
        c.trace.exporter = OpenCensus::Trace::Exporters::Stackdriver.new
        c.trace.default_sampler = OpenCensus::Trace::Samplers::AlwaysSample.new
    end
    request = json_params
    if !request.key?("job_id")
        puts request
        log.error "Couldn't find job_id in request parameters"
        error 400
        return
    end
    job_id = request["job_id"]
    begin
        tracefile = s3_trace(job_id)
    rescue Aws::S3::Errors::ServiceError
        log.error "Couldn't fetch trace file from S3 for job id #{job_id}"
        error 404
        return
    end

    begin
        span_map = coalesce_spans(tracefile)
        max_trace_id = OpenCensus::Trace::SpanContext::MAX_TRACE_ID
        trace_id = rand 1..max_trace_id
        trace_id = trace_id.to_s(16).rjust(32, "0")
        spans = []
        span_map.values.each do |span|
            spans << process_span(job_id, trace_id, span)
        end
        OpenCensus::Trace.config.exporter.export spans
    rescue
        log.error "Couldn't process spans for job id #{job_id}"
        error 500
    end
end
