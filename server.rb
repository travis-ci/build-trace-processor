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

def process_trace(trace_json)
    puts trace_json
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

OpenCensus.configure do |c|
    c.trace.exporter = OpenCensus::Trace::Exporters::Stackdriver.new
end


# Endpoints:

get '/' do
    'Welcome to the Travis Trace Processor'
end

post '/trace' do
    job_id = json_params["job_id"]
    tracefile = s3_trace(job_id)
    tracefile.each_line do |line|
        process_trace(JSON.parse(line))
    end  
end
