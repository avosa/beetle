module Beetle
  # Provides the publishing logic implementation.
  class Publisher < Base

    attr_reader :dead_servers

    def initialize(client, options = {}) #:nodoc:
      super
      @exchanges_with_bound_queues = {}
      @dead_servers = {}
      @bunnies = {}
      @throttling_options = {}
      @next_throttle_refresh = Time.now
      @throttled = false
      at_exit { stop }
    end

    def throttled?
      @throttled
    end

    def throttling?
      !@throttling_options.empty?
    end

    def throttling_status
      @throttled ? 'throttled' : 'unthrottled'
    end

    # list of exceptions potentially raised by bunny
    # these need to be lazy, because qrack exceptions are only defined after a connection has been established
    def bunny_exceptions
      [
        Bunny::ConnectionError, Bunny::ForcedChannelCloseError, Bunny::ForcedConnectionCloseError,
        Bunny::MessageError, Bunny::ProtocolError, Bunny::ServerDownError, Bunny::UnsubscribeError,
        Bunny::AcknowledgementError, Qrack::BufferOverflowError, Qrack::InvalidTypeError,
        Errno::EHOSTUNREACH, Errno::ECONNRESET, Errno::ETIMEDOUT, Timeout::Error
      ]
    end

    def publish(message_name, data, opts={}) #:nodoc:
      ActiveSupport::Notifications.instrument('publish.beetle') do
        opts = @client.messages[message_name].merge(opts.symbolize_keys)
        exchange_name = opts.delete(:exchange)
        opts.delete(:queue)
        recycle_dead_servers unless @dead_servers.empty?
        throttle!
        if opts[:redundant]
          publish_with_redundancy(exchange_name, message_name, data, opts)
        else
          publish_with_failover(exchange_name, message_name, data, opts)
        end
      end
    end

    def publish_with_failover(exchange_name, message_name, data, opts) #:nodoc:
      tries = @servers.size * 2
      logger.debug "Beetle: sending #{message_name}"
      published = 0
      opts = Message.publishing_options(opts)
      begin
        select_next_server if tries.even?
        bind_queues_for_exchange(exchange_name)
        logger.debug "Beetle: trying to send message #{message_name}:#{opts[:message_id]} to #{@server}"
        exchange(exchange_name).publish(data, opts)
        logger.debug "Beetle: message sent!"
        published = 1
      rescue *bunny_exceptions => e
        logger.warn("Beetle: publishing exception #{e} #{e.backtrace[0..4].join("\n")}")
        stop!(e)
        tries -= 1
        # retry same server on receiving the first exception for it (might have been a normal restart)
        # in this case you'll see either a broken pipe or a forced connection shutdown error
        retry if tries.odd?
        mark_server_dead
        retry if tries > 0
        logger.error "Beetle: message could not be delivered: #{message_name}"
        raise NoMessageSent.new
      end
      published
    end

    def publish_with_redundancy(exchange_name, message_name, data, opts) #:nodoc:
      if @servers.size < 2
        logger.warn "Beetle: at least two active servers are required for redundant publishing" if @dead_servers.size > 0
        return publish_with_failover(exchange_name, message_name, data, opts)
      end
      published = []
      opts = Message.publishing_options(opts)
      loop do
        break if published.size == 2 || @servers.empty? || published == @servers
        tries = 0
        select_next_server
        begin
          next if published.include? @server
          bind_queues_for_exchange(exchange_name)
          logger.debug "Beetle: trying to send #{message_name}:#{opts[:message_id]} to #{@server}"
          exchange(exchange_name).publish(data, opts)
          published << @server
          logger.debug "Beetle: message sent (#{published})!"
        rescue *bunny_exceptions => e
          logger.warn("Beetle: publishing exception #{e} #{e.backtrace[0..4].join("\n")}")
          stop!(e)
          retry if (tries += 1) == 1
          mark_server_dead
        end
      end
      case published.size
      when 0
        logger.error "Beetle: message could not be delivered: #{message_name}"
        raise NoMessageSent.new
      when 1
        logger.warn "Beetle: failed to send message redundantly"
      end

      published.size
    end

    RPC_DEFAULT_TIMEOUT = 10 #:nodoc:

    def rpc(message_name, data, opts={}) #:nodoc:
      opts = @client.messages[message_name].merge(opts.symbolize_keys)
      exchange_name = opts.delete(:exchange)
      opts.delete(:queue)
      recycle_dead_servers unless @dead_servers.empty?
      tries = @servers.size
      logger.debug "Beetle: performing rpc with message #{message_name}"
      result = nil
      status = "TIMEOUT"
      begin
        select_next_server
        bind_queues_for_exchange(exchange_name)
        # create non durable, autodeleted temporary queue with a server assigned name
        queue = bunny.queue
        opts = Message.publishing_options(opts.merge :reply_to => queue.name)
        logger.debug "Beetle: trying to send #{message_name}:#{opts[:message_id]} to #{@server}"
        exchange(exchange_name).publish(data, opts)
        logger.debug "Beetle: message sent!"
        logger.debug "Beetle: listening on reply queue #{queue.name}"
        queue.subscribe(:message_max => 1, :timeout => opts[:timeout] || RPC_DEFAULT_TIMEOUT) do |msg|
          logger.debug "Beetle: received reply!"
          result = msg[:payload]
          status = msg[:header].properties[:headers][:status]
        end
        logger.debug "Beetle: rpc complete!"
      rescue *bunny_exceptions => e
        stop!(e)
        mark_server_dead
        tries -= 1
        retry if tries > 0
        logger.error "Beetle: message could not be delivered: #{message_name}"
      end
      [status, result]
    end

    def throttle(queue_options)
      @throttling_options = queue_options
    end

    def throttle!
      return unless throttling?
      refresh_throttling!
      sleep 1 if throttled?
    end

    def purge(queue_names) #:nodoc:
      each_server do
        queue_names.each do |name|
          queue(name).purge rescue nil
        end
      end
    end

    def setup_queues_and_policies
      each_server do
        begin
          @client.queues.keys.each do |name|
            queue(name)
          end
        rescue => e
          logger.warn "Beetle: failed setting up queues and policies on #{@server}: #{e}"
        end
      end
    end

    def stop #:nodoc:
      each_server { stop! }
    end

    private

    def bunny
      @bunnies[@server] ||= new_bunny
    end

    def bunny?
      @bunnies[@server]
    end

    def new_bunny
      b = Bunny.new(
        :host               => current_host,
        :port               => current_port,
        :logging            => !!@options[:logging],
        :user               => @client.config.user,
        :pass               => @client.config.password,
        :vhost              => @client.config.vhost,
        :frame_max          => @client.config.frame_max,
        :channel_max        => @client.config.channel_max,
        :socket_timeout     => @client.config.publishing_timeout,
        :connect_timeout    => @client.config.publisher_connect_timeout,
        :spec => '09')
      b.start
      b
    end

    # retry dead servers after ignoring them for 10.seconds
    # if all servers are dead, retry the one which has been dead for the longest time
    def recycle_dead_servers
      recycle = []
      @dead_servers.each do |s, dead_since|
        recycle << s if dead_since < 10.seconds.ago
      end
      if recycle.empty? && @servers.empty?
        recycle << @dead_servers.keys.sort_by{|k| @dead_servers[k]}.first
      end
      @servers.concat recycle
      recycle.each {|s| @dead_servers.delete(s)}
    end

    def mark_server_dead
      logger.info "Beetle: server #{@server} down: #{$!}"
      @dead_servers[@server] = Time.now
      @servers.delete @server
      @server = @servers[rand @servers.size]
    end

    def select_next_server
      if @servers.empty?
        logger.error("Beetle: no server available")
      else
        set_current_server(@servers[((@servers.index(@server) || 0)+1) % @servers.size])
      end
    end

    def create_exchange!(name, opts)
      bunny.exchange(name, opts)
    end

    def bind_queues_for_exchange(exchange_name)
      return if @exchanges_with_bound_queues.include?(exchange_name)
      @client.exchanges[exchange_name][:queues].each {|q| queue(q) }
      @exchanges_with_bound_queues[exchange_name] = true
    end

    def declare_queue!(queue_name, creation_options)
      logger.debug("Beetle: creating queue with opts: #{creation_options.inspect}")
      queue = bunny.queue(queue_name, creation_options)

      policy_options = bind_dead_letter_queue!(bunny, queue_name, creation_options)
      publish_policy_options(policy_options)
      queue
    end

    def bind_queue!(queue, exchange_name, binding_options)
      queue.bind(exchange(exchange_name), binding_options)
    end

    def stop!(exception=nil)
      return unless bunny?
      timeout = @client.config.publishing_timeout + @client.config.publisher_connect_timeout + 1
      Beetle::Timer.timeout(timeout) do
        logger.debug "Beetle: closing connection from publisher to #{server}"
        if exception
          bunny.__send__ :close_socket
        else
          bunny.stop
        end
      end
    rescue Exception => e
      logger.warn "Beetle: error closing down bunny: #{e}"
      Beetle::reraise_expectation_errors!
    ensure
      @bunnies[@server] = nil
      @exchanges[@server] = {}
      @queues[@server] = {}
    end

    def refresh_throttling!
      t = Time.now
      return if t < @next_throttle_refresh
      @next_throttle_refresh = t + @client.config.throttling_refresh_interval
      old_throttled = @throttled
      @throttled = false
      @throttling_options.each do |queue_name, max_length|
        begin
          len = 0
          each_server do
            len += queue(queue_name).status[:message_count]
          end
          # logger.debug "Beetle: queue '#{queue_name}' has size #{len}"
          if len > max_length
            @throttled = true
            break
          end
        rescue => e
          logger.warn "Beetle: could not fetch queue length for queue '#{queue_name}': #{e}"
        end
      end
      logger.info "Beetle: publisher #{throttling_status}" if @throttled != old_throttled
    end

  end
end
