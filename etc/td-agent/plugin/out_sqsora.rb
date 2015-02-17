module Fluent
  require 'fluent/mixin/config_placeholders'

  class S3OracleOutput < Fluent::TimeSlicedOutput
    Fluent::Plugin.register_output('s3ora', self)

    def initialize
      super
      require 'aws-sdk'
      require 'zlib'
      require 'time'
      require 'tempfile'
      require 'oci8'

      @compressor = nil
    end

    config_param :path, :string, :default => ""
    config_param :use_ssl, :bool, :default => true
    config_param :use_server_side_encryption, :string, :default => nil
    config_param :aws_key_id, :string, :default => nil
    config_param :aws_sec_key, :string, :default => nil
    config_param :s3_bucket, :string
    config_param :s3_region, :string, :default => nil
    config_param :s3_object_key_format, :string, :default => "%{path}%{time_slice}_%{index}.%{file_extension}"
    config_param :store_as, :string, :default => "gzip"
    config_param :auto_create_bucket, :bool, :default => true
    config_param :check_apikey_on_start, :bool, :default => true
    config_param :proxy_uri, :string, :default => nil
    config_param :reduced_redundancy, :bool, :default => false
    config_param :format, :string, :default => 'out_file'
    config_param :ora_host, :string, :default => "localhost"
    config_param :ora_port, :integer, :default => 1521
    config_param :ora_sid, :string, :default => nil
    config_param :ora_user, :string, :default => nil
    config_param :ora_passwd, :string, :default => nil
    config_param :table, :string, :default => nil
    config_param :columns, :string, :default => nil

    attr_reader :bucket

    include Fluent::Mixin::ConfigPlaceholders

    def placeholders
      [:percent]
    end

    def configure(conf)
      super

      begin
        @compressor = COMPRESSOR_REGISTRY.lookup(@store_as).new(:buffer_type => @buffer_type, :log => log)
      rescue => e
        $log.warn "#{@store_as} not found. Use 'text' instead"
        @compressor = TextCompressor.new
      end
      @compressor.configure(conf)

      # TODO: use Plugin.new_formatter instead of TextFormatter.create
      conf['format'] = @format
      @formatter = TextFormatter.create(conf)

      if @localtime
        @path_slicer = Proc.new {|path|
          Time.now.strftime(path)
        }
      else
        @path_slicer = Proc.new {|path|
          Time.now.utc.strftime(path)
        }
      end
    end

    def start
      super
      options = {}
      if @aws_key_id && @aws_sec_key
        options[:access_key_id] = @aws_key_id
        options[:secret_access_key] = @aws_sec_key
      end
      options[:region] = @s3_region if @s3_region
      options[:proxy_uri] = @proxy_uri if @proxy_uri
      options[:use_ssl] = @use_ssl
      options[:s3_server_side_encryption] = @use_server_side_encryption

      @s3 = AWS::S3.new(options)
      @bucket = @s3.buckets[@s3_bucket]

      check_apikeys if @check_apikey_on_start
      ensure_bucket
    end

    def format(tag, time, record)
      # @formatter.format(tag, time, record)
      [tag, time, record].to_msgpack
    end

    def write(chunk)
      begin
        ora_params = {
          :host => @ora_host,
          :port => @ora_port,
          :sid => @ora_sid,
          :user => @ora_user,
          :passwd => @ora_passwd
        }
        handler = OracleHandler.new(ora_params)

        records = []
        chunk.msgpack_each {|(tag,time,record)|
          records << record.to_json
        }

        records.each.with_index(1) do |v,id|
          vals = []
          vals.push(id)
          vals.push(v['body'])
          handler.insert(@table, @columns, vals)
        end
      end

      i = 0
      previous_path = nil

      begin
        path = @path_slicer.call(@path)
        values_for_s3_object_key = {
          "path" => path,
          "time_slice" => chunk.key,
          "file_extension" => @compressor.ext,
          "index" => i
        }
        s3path = @s3_object_key_format.gsub(%r(%{[^}]+})) { |expr|
          values_for_s3_object_key[expr[2...expr.size-1]]
        }
        if (i > 0) && (s3path == previous_path)
          raise "duplicated path is generated. use %{index} in s3_object_key_format: path = #{s3path}"
        end

        i += 1
        previous_path = s3path
      end while @bucket.objects[s3path].exists?

      tmp = Tempfile.new("s3-")
      begin
        @compressor.compress(chunk, tmp)
        @bucket.objects[s3path].write(Pathname.new(tmp.path), {:content_type => @compressor.content_type,
                                                               :reduced_redundancy => @reduced_redundancy})
      ensure
        tmp.close(true) rescue nil
      end
    end

    private

    def ensure_bucket
      if !@bucket.exists?
        if @auto_create_bucket
          log.info "Creating bucket #{@s3_bucket} on #{@s3_endpoint}"
          @s3.buckets.create(@s3_bucket)
        else
          raise "The specified bucket does not exist: bucket = #{@s3_bucket}"
        end
      end
    end

    def check_apikeys
      @bucket.empty?
    rescue AWS::S3::Errors::NoSuchBucket
      # ignore NoSuchBucket Error because ensure_bucket checks it.
    rescue => e
      raise "can't call S3 API. Please check your aws_key_id / aws_sec_key or s3_region configuration. error = #{e.inspect}"
    end

    class Compressor
      include Configurable

      def initialize(opts = {})
        super()
        @buffer_type = opts[:buffer_type]
        @log = opts[:log]
      end

      attr_reader :buffer_type, :log

      def configure(conf)
        super
      end

      def ext
      end

      def content_type
      end

      def compress(chunk, tmp)
      end

      private

      def check_command(command, algo = nil)
        require 'open3'

        algo = command if algo.nil?
        begin
          Open3.capture3("#{command} -V")
        rescue Errno::ENOENT
          raise ConfigError, "'#{command}' utility must be in PATH for #{algo} compression"
        end
      end
    end

    class GzipCompressor < Compressor
      def ext
        'gz'.freeze
      end

      def content_type
        'application/x-gzip'.freeze
      end

      def compress(chunk, tmp)
        w = Zlib::GzipWriter.new(tmp)
        chunk.write_to(w)
        w.close
      ensure
        w.close rescue nil
      end
    end

    class TextCompressor < Compressor
      def ext
        'txt'.freeze
      end

      def content_type
        'text/plain'.freeze
      end

      def compress(chunk, tmp)
        chunk.write_to(tmp)
        tmp.close
      end
    end

    class JsonCompressor < TextCompressor
      def ext
        'json'.freeze
      end

      def content_type
        'application/json'.freeze
      end
    end

    COMPRESSOR_REGISTRY = Registry.new(:s3_compressor_type, 'fluent/plugin/s3_compressor_')
    {
      'gzip' => GzipCompressor,
      'json' => JsonCompressor,
      'text' => TextCompressor
    }.each { |name, compressor|
      COMPRESSOR_REGISTRY.register(name, compressor)
    }

    def self.register_compressor(name, compressor)
      COMPRESSOR_REGISTRY.register(name, compressor)
    end

    class OracleHandler
      def initialize(params)
        @ora_host = params[:host]
        @ora_port = params[:port]
        @ora_sid = params[:sid]
        @ora_user = params[:user]
        @ora_passwd = params[:passwd]
      end

      def insert(table, cols, vals)
        conn = _get_conn()

        begin
          columns = cols.split(/\s*,\s*/)
          placeholders = columns.map.with_index(1){|k,i| ":#{i}"}.join(',')
          sql = "insert into #{table} (#{columns.join(",")}) values (#{placeholders})"

          cursor = conn.parse(sql)
          vals.map.with_index(1){|v,i| cursor.bind_param(":#{i}", v)}
          cursor.exec
          cursor.close()
          conn.commit
        ensure
          conn.logoff
        end
      end

      private

      def _get_conn()
        url = "%s:%d/%s" % [@ora_host, @ora_port, @ora_sid]
        OCI8.new(@ora_user, @ora_passwd, url)
      end
    end

  end
end