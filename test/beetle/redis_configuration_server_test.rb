require File.expand_path(File.dirname(__FILE__) + '/../test_helper')

module Beetle
  class RedisConfigurationServerTest < MiniTest::Unit::TestCase
    def setup
      Beetle.config.redis_configuration_client_ids = "rc-client-1,rc-client-2"
      @server = RedisConfigurationServer.new
      EventMachine.stubs(:add_timer).yields
    end

    test "should exit when started with less than two redis configured" do
      Beetle.config.redis_servers = ""
      assert_raises Beetle::ConfigurationError do
        @server.start
      end
    end

    test "should initialize the current token for messages to not reuse old tokens" do
      sleep 0.1
      later_server = RedisConfigurationServer.new
      assert later_server.current_token > @server.current_token
    end

    test "should ignore outdated client_invalidated messages" do
      @server.instance_variable_set(:@current_token, 2)
      @server.client_invalidated("id" => "rc-client-1", "token" => 2)
      @server.client_invalidated("id" => "rc-client-2", "token" => 1)

      assert_equal(["rc-client-1"].to_set, @server.instance_variable_get(:@client_invalidated_ids_received))
    end

    test "should ignore outdated pong messages" do
      @server.instance_variable_set(:@current_token, 2)
      @server.pong("id" => "rc-client-1", "token" => 2)
      @server.pong("id" => "rc-client-2", "token" => 1)

      assert_equal(["rc-client-1"].to_set, @server.instance_variable_get(:@client_pong_ids_received))
    end

    test "the dispatcher should just forward messages to the server" do
      dispatcher_class = RedisConfigurationServer.class_eval "MessageDispatcher"
      dispatcher_class.configuration_server = @server
      dispatcher = dispatcher_class.new
      payload = {"token" => 1}
      dispatcher.stubs(:message).returns(stub(:data => payload.to_json, :header => stub(:routing_key=> "pong")))
      @server.expects(:pong).with(payload)
      dispatcher.send(:process)
    end

    test "if a new master is available, it should be published and the available slaves should be configured" do
      redis = Redis.new
      other_master = Redis.new(:port => 6380)
      other_master.expects(:slave_of!).with(redis.host, redis.port)
      @server.stubs(:current_master).returns(redis)
      @server.redis.instance_variable_set(:@server_info, {"master" => [redis, other_master], "slave" => [], "unknown" => []})
      payload = @server.send(:payload_with_current_token, {"server" => redis.server})
      @server.beetle.expects(:publish).with(:reconfigure, payload)
      @server.master_available!
    end

    test "should be able to report current status" do
      @server.expects(:unknown_client_ids).returns(Set.new ["x", "y"])
      @server.expects(:unresponsive_clients).returns(["a", Time.now - 200])
      assert @server.status.is_a?(Hash)
    end

    test "should be able to calculate unseen clients array" do
      assert_equal @server.client_ids.sort, @server.unseen_client_ids
      @server.send(:client_seen, "rc-client-1")
      assert_equal ["rc-client-2"], @server.unseen_client_ids
      @server.send(:client_seen, "rc-client-2")
      assert_equal [], @server.unseen_client_ids
    end

    test "should not execute a conditional master switch if the current master is available" do
      @server.expects(:master_available?).returns(true)
      @server.expects(:paused?).returns(false)
      @server.expects(:master_unavailable!).never
      assert !@server.initiate_master_switch
    end

    test "should not execute a conditional master switch if a switch is already in progress" do
      @server.expects(:master_available?).returns(false)
      @server.expects(:paused?).returns(true)
      @server.expects(:master_unavailable!).never
      assert @server.initiate_master_switch
    end

    test "should execute a conditional master switch if the current master is unavailable and no switch is in progress yet" do
      @server.expects(:master_available?).returns(false)
      @server.expects(:master_unavailable!).once
      @server.expects(:paused?).returns(false)
      assert @server.initiate_master_switch
    end

    test "should put a limit on the number of stored unknown client ids" do
      1000.times do |i|
        id = i.to_s
        @server.send(:client_seen, id)
        @server.send(:add_unknown_client_id, id)
      end
      assert @server.unknown_client_ids.size < 100
      assert_equal @server.unknown_client_ids.size, @server.clients_last_seen.size
    end

    test "should assume clients to be unresponsive after specified interval time" do
      @server.send(:client_seen, "1")
      @server.send(:client_seen, "2")
      @server.client_dead_threshold = 0
      assert_equal %w(1 2), @server.unresponsive_clients.map(&:first)
      @server.client_dead_threshold = 10
      assert_equal [], @server.unresponsive_clients
    end
  end

  class RedisConfigurationServerInvalidationTest < MiniTest::Unit::TestCase
    def setup
      Beetle.config.redis_configuration_client_ids = "rc-client-1,rc-client-2"
      Beetle.config.redis_servers = "redis:0,redis:1"
      @server = RedisConfigurationServer.new
      @server.instance_variable_set(:@current_master, stub('redis stub', :server => 'stubbed_server', :available? => false))
      @server.stubs(:verify_redis_master_file_string)
      @server.beetle.stubs(:listen).yields
      @server.beetle.stubs(:publish)
      EM::Timer.stubs(:new).returns(true)
      EventMachine.stubs(:add_periodic_timer).yields
    end

    test "should pause watching of the redis master when it becomes unavailable" do
      @server.expects(:determine_initial_master)
      EM.stubs(:add_periodic_timer).returns(stub("timer", :cancel => true))
      @server.start
      assert !@server.paused?
      @server.master_unavailable!
      assert @server.paused?
    end

    test "should setup an invalidation timeout" do
      EM::Timer.expects(:new).yields
      @server.expects(:cancel_invalidation)
      @server.master_unavailable!
    end

    test "should continue watching after the invalidation timeout has expired" do
      EM::Timer.expects(:new).yields
      @server.master_unavailable!
      assert !@server.paused?
    end

    test "should invalidate the current master after receiving all pong messages" do
      EM::Timer.expects(:new).yields.returns(:timer)
      @server.beetle.expects(:publish).with(:invalidate, anything)
      @server.expects(:cancel_invalidation)
      @server.expects(:redeem_token).with(1).twice.returns(true)
      @server.pong("token" => 1, "id" => "rc-client-1")
      @server.pong("token" => 1, "id" => "rc-client-2")
    end

    test "should switch the current master after receiving all client_invalidated messages" do
      @server.expects(:redeem_token).with(1).twice.returns(true)
      @server.expects(:switch_master)
      @server.client_invalidated("token" => 1, "id" => "rc-client-1")
      @server.client_invalidated("token" => 1, "id" => "rc-client-2")
    end

    test "should switch the current master immediately if there are no clients" do
      @server.instance_variable_set :@client_ids, Set.new
      @server.expects(:switch_master)
      @server.master_unavailable!
    end

    test "switching the master should turn the new master candidate into a master" do
      new_master = stub(:master! => nil, :server => "jo:6379")
      @server.beetle.expects(:publish).with(:system_notification, anything)
      @server.expects(:determine_new_master).returns(new_master)
      @server.expects(:write_redis_master_file).with(new_master.server)
      @server.send :switch_master
      assert_equal new_master, @server.current_master
    end

    test "switching the master should resort to the old master if no candidate can be found" do
      old_master = @server.current_master
      @server.beetle.expects(:publish).with(:system_notification, anything)
      @server.expects(:determine_new_master).returns(nil)
      @server.send :switch_master
      assert_equal old_master, @server.current_master
    end

    test "checking the availability of redis servers should publish the available servers as long as the master is available" do
      @server.expects(:master_available?).returns(true)
      @server.expects(:master_available!)
      @server.send(:master_watcher).send(:check_availability)
    end

    test "checking the availability of redis servers should call master_unavailable after trying the specified number of times" do
      @server.stubs(:master_available?).returns(false)
      @server.expects(:master_unavailable!)
      watcher = @server.send(:master_watcher)
      watcher.instance_variable_set :@master_retries, 0
      watcher.send(:check_availability)
    end
  end

  class RedisConfigurationServerInitialRedisMasterDeterminationTest < MiniTest::Unit::TestCase
    def setup
      EM::Timer.stubs(:new).returns(true)
      EventMachine.stubs(:add_periodic_timer).yields
      @client = Client.new(Configuration.new)
      @client.stubs(:listen).yields
      @client.stubs(:publish)
      @client.config.redis_configuration_client_ids = "rc-client-1,rc-client-2"
      @server = RedisConfigurationServer.new
      @server.stubs(:beetle).returns(@client)
      @server.stubs(:write_redis_master_file)
      @redis_master  = build_master_redis_stub
      @redis_slave   = build_slave_redis_stub
      @server.instance_variable_set(:@redis, build_redis_server_info(@redis_master, @redis_slave))
    end

    test "should not try to auto-detect if the master file contains a server string" do
      @server.expects(:master_file_exists?).returns(true)
      @server.stubs(:read_redis_master_file).returns("foobar:0000")

      @server.redis.expects(:auto_detect_master).never
      @server.expects(:redis_master_from_master_file).returns(@redis_master)
      @server.send(:determine_initial_master)
    end

    test "should try to auto-detect if the master file is empty" do
      @server.expects(:master_file_exists?).returns(true)
      @server.stubs(:read_redis_master_file).returns("")

      @server.redis.expects(:auto_detect_master).returns(@redis_master)
      @server.send(:determine_initial_master)
    end

    test "should try to auto-detect if the master file is not present" do
      @server.expects(:master_file_exists?).returns(false)

      @server.redis.expects(:auto_detect_master).returns(@redis_master)
      @server.send(:determine_initial_master)
    end

    test "should use redis master from successful auto-detection" do
      @server.expects(:master_file_exists?).returns(false)

      @server.expects(:write_redis_master_file).with(@redis_master.server)
      @server.send(:determine_initial_master)
      assert_equal @redis_master, @server.current_master
    end

    test "should use redis master if master in file is the only master" do
      @server.expects(:master_file_exists?).returns(true)
      @server.stubs(:redis_master_from_master_file).returns(@redis_master)

      @server.send(:determine_initial_master)
      assert_equal @redis_master, @server.current_master
    end

    test "should start master switch if master in file is slave" do
      @server.instance_variable_set(:@redis, build_redis_server_info(@redis_slave))
      @server.expects(:master_file_exists?).returns(true)
      @server.stubs(:redis_master_from_master_file).returns(@redis_slave)

      @server.expects(:master_unavailable!)
      @server.send(:determine_initial_master)
    end

    test "should use master from master file if multiple masters are available" do
      redis_master2 = build_master_redis_stub
      @server.instance_variable_set(:@redis, build_redis_server_info(@redis_master, redis_master2))
      @server.expects(:master_file_exists?).returns(true)
      @server.stubs(:redis_master_from_master_file).returns(@redis_master)

      @server.send(:determine_initial_master)
      assert_equal @redis_master, @server.current_master
    end

    test "should start master switch if master in file is not available" do
      not_available_redis_master = build_unknown_redis_stub
      @server.instance_variable_set(:@redis, build_redis_server_info(not_available_redis_master, @redis_slave))
      @server.expects(:master_file_exists?).returns(true)
      @server.stubs(:redis_master_from_master_file).returns(not_available_redis_master)

      @server.expects(:master_unavailable!)
      @server.send(:determine_initial_master)
    end

    test "should raise an exception if both master file and auto-detection fails" do
      not_available_redis_master = build_unknown_redis_stub
      not_available_redis_slave  = build_unknown_redis_stub
      @server.instance_variable_set(:@redis, build_redis_server_info(not_available_redis_master, not_available_redis_slave))
      @server.expects(:master_file_exists?).returns(true)
      @server.expects(:read_redis_master_file).returns("")
      @server.redis.expects(:auto_detect_master).returns(nil)

      assert_raises Beetle::NoRedisMaster do
        @server.send(:determine_initial_master)
      end
    end

    test "should detect a new redis_master" do
      not_available_redis_master = build_unknown_redis_stub
      @redis_slave.expects(:slave_of?).returns(true)
      @server.instance_variable_set(:@current_master, not_available_redis_master)
      @server.instance_variable_set(:@redis, build_redis_server_info(@redis_slave, not_available_redis_master))
      assert_equal @redis_slave, @server.send(:determine_new_master)
    end

    private

    def build_master_redis_stub
      stub("redis master", :host => "stubbed_master", :port => 0, :server => "stubbed_master:0", :available? => true, :master? => true, :slave? => false, :role => "master")
    end

    def build_slave_redis_stub
      stub("redis slave", :host => "stubbed_slave", :port => 0, :server => "stubbed_slave:0",  :available? => true, :master? => false, :slave? => true, :role => "slave")
    end

    def build_unknown_redis_stub
      stub("redis unknown", :host => "stubbed_unknown", :port => 0, :server => "stubbed_unknown:0",  :available? => false, :master? => false, :slave? => false, :role => "unknown")
    end

    def build_redis_server_info(*redis_instances)
      info = RedisServerInfo.new(Beetle.config, :timeout => 1)
      info.instance_variable_set :@instances, redis_instances
      redis_instances.each{|redis| info.send("#{redis.role}s") << redis }
      info
    end
  end

  class RedisConfigurationServerSystemNotificationTest < MiniTest::Unit::TestCase
    def setup
      Beetle.config.redis_configuration_client_ids = "rc-client-1,rc-client-2"
      @server = RedisConfigurationServer.new
      @server.stubs(:beetle).returns(stub(:publish))
      EventMachine.stubs(:add_timer).yields
    end

    test "should send a system notification when receiving pong message from unknown client" do
      payload = {"id" => "unknown-client", "token" => @server.current_token}
      msg = "Received pong message from unknown id 'unknown-client'"
      @server.beetle.expects(:publish).with(:system_notification, ({:message => msg}).to_json)
      @server.pong(payload)
      assert @server.unknown_client_ids.include?("unknown-client")
    end

    test "should send a system notification when receiving client_started message from unknown client" do
      payload = {"id" => "unknown-client"}
      msg = "Received client_started message from unknown id 'unknown-client'"
      @server.beetle.expects(:publish).with(:system_notification, ({:message => msg}).to_json)
      @server.client_started(payload)
      assert @server.unknown_client_ids.include?("unknown-client")
    end

    test "should not send a system notification when receiving a client started message from a known client" do
      payload = {"id" => "rc-client-1"}
      @server.beetle.expects(:publish).never
      @server.expects(:add_unknown_client_id).never
      @server.client_started(payload)
      assert @server.clients_last_seen.include?("rc-client-1")
    end

    test "should send a system notification when receiving heartbeat message from unknown client" do
      payload = {"id" => "unknown-client"}
      msg = "Received heartbeat message from unknown id 'unknown-client'"
      @server.beetle.expects(:publish).with(:system_notification, ({:message => msg}).to_json)
      @server.heartbeat(payload)
      assert @server.unknown_client_ids.include?("unknown-client")
    end

    test "should not send a system notification when receiving a heartbeat message from a known client" do
      payload = {"id" => "rc-client-1"}
      @server.beetle.expects(:publish).never
      @server.expects(:add_unknown_client_id).never
      @server.heartbeat(payload)
      assert @server.clients_last_seen.include?("rc-client-1")
    end

  end
end
