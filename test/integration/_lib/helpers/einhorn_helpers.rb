require 'subprocess'
require 'timeout'
require 'tmpdir'

module Helpers
  module EinhornHelpers
    def einhorn_code_dir
      File.expand_path('../../../../', File.dirname(__FILE__))
    end

    def default_einhorn_command
      ['bundle', 'exec', File.expand_path('bin/einhorn', einhorn_code_dir)]
    end

    def with_running_einhorn(cmdline, options = {})
      options = options.dup
      einhorn_command = options.delete(:einhorn_command) { default_einhorn_command }
      expected_exit_code = options.delete(:expected_exit_code) { nil }
      output_callback = options.delete(:output_callback) { nil }

      stdout, stderr = "", ""
      communicator = nil
      process = Bundler.with_clean_env do
        default_options = {
          :stdout => Subprocess::PIPE,
          :stderr => Subprocess::PIPE,
          :stdin => '/dev/null',
          :cwd => einhorn_code_dir
        }
        Subprocess::Process.new(Array(einhorn_command) + cmdline, default_options.merge(options))
      end

      status = nil
      begin
        communicator = Thread.new do
          begin
            stdout, stderr = process.communicate
          rescue Errno::ECHILD
            # It's dead, and we're not getting anything. This is
            # peaceful.
          end
        end
        yield(process) if block_given?
      rescue Exception => e
        unless (status = process.poll) && status.exited?
          process.terminate
        end
        raise
      ensure
        unless (status = process.poll) && status.exited?
          begin
            Timeout.timeout(10) do  # (Argh, I'm so sorry)
              status = process.wait
            end
          rescue Timeout::Error
            $stderr.puts "Could not get Einhorn to quit within 10 seconds, killing it forcefully..."
            process.send_signal("KILL")
            status = process.wait
          rescue Errno::ECHILD
            # Process is dead!
          end
        end
        communicator.join
        output_callback.call(stdout, stderr) if output_callback
      end
    end

    def einhornsh(commandline, options = {})
      Subprocess.check_call(%W{bundle exec #{File.expand_path('bin/einhornsh')}} + commandline,
                            {
                              :stdin => '/dev/null',
                              :stdout => '/dev/null',
                              :stderr => '/dev/null'
                            }.merge(options))
    end

    def fixture_path(name)
      File.expand_path(File.join('../fixtures', name), File.dirname(__FILE__))
    end

    # Creates a new temporary directory with the initial contents from
    # test/integration/_lib/fixtures/{name} and returns the path to
    # it.  The contents of this directory are temporary and can be
    # safely overwritten.
    def prepare_fixture_directory(name)
      @fixtured_dirs ||= Set.new
      new_dir = Dir.mktmpdir(name)
      @fixtured_dirs << new_dir
      FileUtils.cp_r(File.join(fixture_path(name), '.'), new_dir)

      new_dir
    end

    def cleanup_fixtured_directories
      (@fixtured_dirs || []).each { |dir| FileUtils.rm_rf(dir) }
    end

    def find_free_port(host='127.0.0.1')
      open_port = TCPServer.new(host, 0)
      open_port.addr[1]
    ensure
      open_port.close
    end

    def wait_for_open_port
      max_retries = 50
      begin
        read_from_port
      rescue Errno::ECONNREFUSED
        max_retries -= 1
        if max_retries <= 0
          raise
        else
          sleep 0.1
          retry
        end
      end
    end


    def read_from_port
      ewouldblock = RUBY_VERSION >= '1.9.0' ? IO::WaitWritable : Errno::EINPROGRESS
      socket = Socket.new(Socket::PF_INET, Socket::SOCK_STREAM, 0)
      sockaddr = Socket.pack_sockaddr_in(@port, '127.0.0.1')
      begin
        socket.connect_nonblock(sockaddr)
      rescue ewouldblock
        IO.select(nil, [socket], [], 5)
        begin
          socket.connect_nonblock(sockaddr)
        rescue Errno::EISCONN
        end
      end
      socket.read.chomp
    ensure
      socket.close if socket
    end
  end
end